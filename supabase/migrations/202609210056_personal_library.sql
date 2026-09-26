begin;
create table if not exists public.personal_library_assets (
 id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id),
 checksum text not null check(checksum ~ '^[a-f0-9]{64}$'),file_name text not null check(length(file_name) between 1 and 200),
 file_size bigint not null check(file_size between 1 and 524288000),mime_type text not null,
 object_key text not null unique,ready boolean not null default false,created_at timestamptz not null default now(),
 unique(owner_id,checksum),unique(id,owner_id)
);
create table if not exists public.personal_library_entries (
 id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id),parent_id uuid,
 title text not null check(length(title) between 1 and 200),kind text not null check(kind in ('folder','file','note','article')),
 asset_id uuid,source_id uuid,body text not null default '' check(length(body)<=5000000),
 is_public boolean not null default false,created_at timestamptz not null default now(),
 unique(id,owner_id),foreign key(parent_id,owner_id) references public.personal_library_entries(id,owner_id),
 foreign key(asset_id,owner_id) references public.personal_library_assets(id,owner_id)
);
alter table public.personal_library_assets enable row level security;
alter table public.personal_library_entries enable row level security;
revoke all on public.personal_library_assets,public.personal_library_entries from public,anon,authenticated;
grant select on public.personal_library_assets,public.personal_library_entries to authenticated;
grant insert,update on public.personal_library_entries to authenticated;
create policy library_owner_write on public.personal_library_entries for insert to authenticated with check(owner_id=auth.uid());
create policy library_owner_update on public.personal_library_entries for update to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy library_entry_read on public.personal_library_entries for select to authenticated using(
 owner_id=auth.uid() or (is_public and exists(select 1 from public.community_profiles where user_id=owner_id and public_resources))
);
-- community_profiles has no direct grants; use a fixed, narrow helper instead.
create or replace function public.library_profile_public(p_owner uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select public_resources from public.community_profiles where user_id=p_owner),false)
$$;
revoke all on function public.library_profile_public(uuid) from public;
grant execute on function public.library_profile_public(uuid) to authenticated;
drop policy library_entry_read on public.personal_library_entries;
create policy library_entry_read on public.personal_library_entries for select to authenticated using(owner_id=auth.uid() or (is_public and public.library_profile_public(owner_id)));
create policy library_asset_read on public.personal_library_assets for select to authenticated using(
 owner_id=auth.uid() or (ready and exists(select 1 from public.personal_library_entries e where e.asset_id=personal_library_assets.id and e.is_public and public.library_profile_public(e.owner_id)))
);
insert into storage.buckets(id,name,public,file_size_limit) values('personal-library','personal-library',false,524288000) on conflict(id) do nothing;
create or replace function public.library_storage_access(p_key text,p_write boolean) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.personal_library_assets a where a.object_key=p_key and
  (a.owner_id=auth.uid() and (not p_write or not a.ready) or (not p_write and a.ready and public.library_profile_public(a.owner_id)
    and exists(select 1 from public.personal_library_entries e where e.asset_id=a.id and e.is_public))))
$$;
revoke all on function public.library_storage_access(text,boolean) from public;
grant execute on function public.library_storage_access(text,boolean) to authenticated;
create policy library_upload on storage.objects for insert to authenticated with check(bucket_id='personal-library' and public.library_storage_access(name,true));
create policy library_read on storage.objects for select to authenticated using(bucket_id='personal-library' and public.library_storage_access(name,false));
create or replace function public.personal_library_upload(p_name text,p_size bigint,p_hash text,p_mime text,p_complete boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); asset public.personal_library_assets; actual bigint; typ text;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'LOGIN_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,49));
 if p_name ~ '[/\\\x00-\x1f]' or p_size not between 1 and 524288000 or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_REQUEST'; end if;
 typ:=admin_private.resource_kind(p_name,p_mime);
 if typ<>'apk' and p_size>104857600 then raise exception 'FILE_TOO_LARGE';end if;
 select * into asset from public.personal_library_assets where owner_id=actor and checksum=p_hash;
 if not found then
   insert into public.personal_library_assets(owner_id,checksum,file_name,file_size,mime_type,object_key)
   values(actor,p_hash,p_name,p_size,p_mime,actor::text||'/'||p_hash||'/'||p_name) returning * into asset;
   perform admin_private.resource_record('supabase/personal-library/'||asset.object_key,actor,'personal-library',p_name,typ,p_size,true,false,now(),true,false);
 end if;
 if asset.file_size<>p_size then raise exception 'FILE_SIZE_MISMATCH'; end if;
 if p_complete and not asset.ready then
   select (metadata->>'size')::bigint into actual from storage.objects where bucket_id='personal-library' and name=asset.object_key;
   if actual is distinct from asset.file_size then raise exception 'UPLOAD_NOT_COMPLETE';end if;
   perform admin_private.resource_record('supabase/personal-library/'||asset.object_key,actor,'personal-library',asset.file_name,typ,actual,false,false,asset.created_at,true,false);
   update public.personal_library_assets set ready=true where id=asset.id returning * into asset;
 end if;
 return to_jsonb(asset);
end $$;
revoke all on function public.personal_library_upload(text,bigint,text,text,boolean) from public,anon;
grant execute on function public.personal_library_upload(text,bigint,text,text,boolean) to authenticated;
create or replace function public.library_storage_size_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.bucket_id='personal-library' and new.metadata->>'size' is not null and (new.metadata->>'size')::bigint>0 and not exists(
  select 1 from public.personal_library_assets where object_key=new.name and file_size=(new.metadata->>'size')::bigint
 ) then raise exception 'FILE_SIZE_MISMATCH'; end if;
 return new;
end $$;
revoke all on function public.library_storage_size_guard() from public,anon,authenticated;
create or replace trigger library_storage_size_guard before insert or update of metadata on storage.objects for each row execute function public.library_storage_size_guard();
notify pgrst,'reload schema';
commit;
