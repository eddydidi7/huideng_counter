begin;

alter table public.public_resource_settings
  add column if not exists uploader_delete_enabled boolean not null default true,
  add column if not exists group_transfer_enabled boolean not null default true;

create table if not exists public.file_objects (
  id uuid primary key default gen_random_uuid(),
  bucket text not null check(bucket in ('public-resources','group-files')),
  object_key text not null, owner_id uuid not null references auth.users(id),
  checksum text not null, file_size bigint not null check(file_size>0),
  verified boolean not null default false,
  created_at timestamptz not null default now(),
  ref_count bigint not null default 0 check(ref_count>=0),
  state text not null default 'ready' check(state in ('ready','deleting','deleted')),
  not_before timestamptz not null default now(),
  claim_id uuid, claim_until timestamptz,
  verify_offset bigint not null default 0, verify_state jsonb,
  unique(bucket,object_key)
);
create index if not exists file_objects_hash on public.file_objects(checksum,file_size) where verified and state='ready';
create table if not exists public.file_references (
  kind text not null check(kind in ('public','group')),
  source_id uuid not null, object_id uuid not null references public.file_objects(id),
  primary key(kind,source_id)
);
alter table public.file_objects enable row level security;
alter table public.file_references enable row level security;
revoke all on public.file_objects,public.file_references from public,anon,authenticated;
alter table public.public_resources add column if not exists storage_bucket text not null default 'public-resources';
alter table public.public_resources drop constraint if exists public_resources_object_key_key;
alter table public.public_resources add column if not exists object_id uuid references public.file_objects(id);
alter table public.public_resources drop constraint if exists public_resources_file_size_check;
alter table public.public_resources add constraint public_resources_file_size_check check(file_size between 1 and 5368709120);
alter table public.public_resource_settings drop constraint if exists public_resource_settings_max_file_bytes_check;
alter table public.public_resource_settings add constraint public_resource_settings_max_file_bytes_check check(max_file_bytes between 1 and 5368709120);
update storage.buckets set file_size_limit=5368709120 where id='public-resources';
alter table public.community_files add column if not exists object_id uuid references public.file_objects(id);
-- Community rows can have independent ownership/reference histories for one object.
alter table public.community_files drop constraint if exists community_files_object_key_key;

create or replace function public.file_ref_count() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and new.object_id=old.object_id then return new; end if;
  if tg_op<>'DELETE' then
    update public.file_objects set ref_count=ref_count+1 where id=new.object_id and state='ready';
    if not found then raise exception 'FILE_UNAVAILABLE'; end if;
  end if;
  if tg_op<>'INSERT' then
    update public.file_objects set ref_count=ref_count-1 where id=old.object_id;
  end if;
  return coalesce(new,old);
end $$;
create or replace trigger file_ref_count after insert or update or delete on public.file_references
  for each row execute function public.file_ref_count();

create or replace function public.file_register(p_bucket text,p_key text,p_owner uuid,p_hash text,p_size bigint,p_verified boolean,p_until timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare oid uuid;
begin
  insert into public.file_objects(bucket,object_key,owner_id,checksum,file_size,verified,not_before)
    values(p_bucket,p_key,p_owner,p_hash,p_size,p_verified,coalesce(p_until,now()))
    on conflict(bucket,object_key) do update set
      verified=file_objects.verified or excluded.verified,
      not_before=greatest(file_objects.not_before,excluded.not_before)
    where file_objects.state='ready' and file_objects.checksum=excluded.checksum and file_objects.file_size=excluded.file_size
    returning id into oid;
  if oid is null then raise exception 'FILE_UNAVAILABLE'; end if;
  return oid;
end $$;

create or replace function public.file_public_reference() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' then
    delete from public.file_references where kind='public' and source_id=old.id;
    return old;
  end if;
  if new.status in ('deleting','deleted') then
    delete from public.file_references where kind='public' and source_id=new.id;
    return new;
  end if;
  new.object_id:=public.file_register(new.storage_bucket,new.object_key,new.user_id,new.checksum,new.file_size,new.verified,
    greatest(new.lease_until,new.upload_token_until));
  insert into public.file_references(kind,source_id,object_id) values('public',new.id,new.object_id)
    on conflict(kind,source_id) do update set object_id=excluded.object_id;
  return new;
end $$;
create or replace trigger file_public_reference before insert or update or delete on public.public_resources
  for each row execute function public.file_public_reference();

create or replace function public.file_community_object() returns trigger
language plpgsql security definer set search_path='' as $$
declare known boolean;
begin
  -- Only public uploads have already passed server-side SHA-256 verification.
  known:=exists(select 1 from public.public_resources r where r.id=new.resource_id and r.verified
    and r.storage_bucket=new.bucket and r.object_key=new.object_key and r.checksum=new.checksum and r.file_size=new.file_size);
  new.object_id:=public.file_register(new.bucket,new.object_key,new.owner_user_id,new.checksum,new.file_size,known,now());
  return new;
end $$;
create or replace trigger file_community_object before insert or update of bucket,object_key,checksum,file_size on public.community_files
  for each row execute function public.file_community_object();

create or replace function public.file_group_reference() returns trigger
language plpgsql security definer set search_path='' as $$
declare oid uuid;
begin
  if tg_op='DELETE' then
    delete from public.file_references where kind='group' and source_id=old.id; return old;
  end if;
  if new.deleted_at is not null then
    delete from public.file_references where kind='group' and source_id=new.id;
  else
    select object_id into oid from public.community_files where id=new.file_id;
    insert into public.file_references(kind,source_id,object_id) values('group',new.id,oid)
      on conflict(kind,source_id) do update set object_id=excluded.object_id;
  end if;
  return new;
end $$;
create or replace trigger file_group_reference before insert or update or delete on public.chat_group_files
  for each row execute function public.file_group_reference();

-- Backfill metadata only. No Storage objects are moved or removed by migration.
update public.public_resources set object_key=object_key where object_id is null and status not in ('deleting','deleted');
update public.community_files set object_key=object_key where object_id is null;
insert into public.file_references(kind,source_id,object_id)
  select 'group',g.id,c.object_id from public.chat_group_files g join public.community_files c on c.id=g.file_id
  where g.deleted_at is null on conflict do nothing;
-- Adopt pending legacy deletions so the retry worker can finish them safely.
update public.public_resources set object_id=public.file_register(storage_bucket,object_key,user_id,checksum,file_size,verified,
  greatest(lease_until,upload_token_until)) where status='deleting' and object_id is null;

create or replace function public.file_object_readable(p_object uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.public_resources r where r.object_id=p_object and r.status='published' and r.verified and not r.moderated
      and exists(select 1 from public.public_resource_settings where id and enabled and download_enabled))
    or exists(select 1 from public.community_files c where c.object_id=p_object and public.group_file_readable(c.id))
$$;

-- Serialize canonicalization by verified hash; never trust client-only hashes.
create or replace function public.file_canonicalize(p_object uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare obj public.file_objects; target public.file_objects; duplicate record;
begin
  select * into obj from public.file_objects where id=p_object;
  if not obj.verified or obj.state<>'ready' then return p_object; end if;
  perform pg_advisory_xact_lock(hashtextextended(obj.checksum||':'||obj.file_size::text,77));
  select * into target from public.file_objects where verified and state='ready'
    and checksum=obj.checksum and file_size=obj.file_size order by created_at,id limit 1 for update;
  for duplicate in select id from public.file_objects where verified and state='ready'
    and checksum=obj.checksum and file_size=obj.file_size and id<>target.id order by id for update loop
  update public.public_resources set storage_bucket=target.bucket,object_key=target.object_key
    where object_id=duplicate.id and status not in ('deleting','deleted');
  update public.community_files set bucket=target.bucket,object_key=target.object_key where object_id=duplicate.id;
  update public.file_references set object_id=target.id where object_id=duplicate.id;
  end loop;
  return target.id;
end $$;

do $$ begin
  if to_regprocedure('public.public_resources_before_shared_files(uuid,text,jsonb)') is null then
    alter function public.public_resources_service_v1(uuid,text,jsonb) rename to public_resources_before_shared_files;
  end if;
end $$;
revoke all on function public.public_resources_before_shared_files(uuid,text,jsonb) from public,anon,authenticated;

create or replace function public.public_resources_service_v1(p_actor uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; cfg public.public_resource_settings; f public.public_resources; obj public.file_objects; is_admin boolean;
begin
  if p_actor is null or not exists(select 1 from auth.users where id=p_actor and not coalesce(is_anonymous,false)
    and (banned_until is null or banned_until<now())) then raise exception 'LOGIN_REQUIRED'; end if;
  perform set_config('request.jwt.claim.sub',p_actor::text,true);
  select * into cfg from public.public_resource_settings where id for update;
  is_admin:=exists(select 1 from admin_private.members where user_id=p_actor and enabled and role in ('admin','super_admin'));
  if p_action in ('delete','admin.delete') then
    select * into f from public.public_resources where id=(p_data->>'id')::uuid for update;
    if not found then raise exception 'FILE_UNAVAILABLE'; end if;
    if p_action='admin.delete' and not is_admin then raise exception 'FORBIDDEN'; end if;
    if not is_admin and (f.user_id<>p_actor or not cfg.uploader_delete_enabled) then raise exception 'FORBIDDEN'; end if;
    update public.public_resources set status='deleted',deleted_at=coalesce(deleted_at,now()) where id=f.id;
    if is_admin then insert into admin_private.audit_logs(actor,action,target,after_data)
      values(p_actor,'resources.delete',f.id::text,jsonb_build_object('reference_only',true)); end if;
    return jsonb_build_object('deleted',true,'cleanup_pending',true);
  end if;
  -- Old admin clients must never purge shared physical objects independently.
  if p_action in ('admin.cleanup','admin.purged') then
    if not is_admin then raise exception 'FORBIDDEN'; end if;
    return jsonb_build_object('files','[]'::jsonb,'saved',true);
  end if;
  result:=public.public_resources_before_shared_files(p_actor,p_action,p_data);
  if p_action='admin.settings' then
    if p_data ? 'uploader_delete_enabled' and jsonb_typeof(p_data->'uploader_delete_enabled')<>'boolean'
      or p_data ? 'group_transfer_enabled' and jsonb_typeof(p_data->'group_transfer_enabled')<>'boolean' then raise exception 'INVALID_REQUEST'; end if;
    update public.public_resource_settings set
      uploader_delete_enabled=coalesce((p_data->>'uploader_delete_enabled')::boolean,uploader_delete_enabled),
      group_transfer_enabled=coalesce((p_data->>'group_transfer_enabled')::boolean,group_transfer_enabled) where id;
  elsif p_action='list' then
    select jsonb_set(result,'{files}',coalesce(jsonb_agg(x||jsonb_build_object('can_delete',
      cfg.uploader_delete_enabled and exists(select 1 from public.public_resources r where r.id=(x->>'id')::uuid and r.user_id=p_actor))),'[]'))
      into result from jsonb_array_elements(result->'files') x;
  elsif p_action='begin' then
    select * into f from public.public_resources where id=(result->'file'->>'id')::uuid;
    if not f.verified and f.status='uploading' then
      select * into obj from public.file_objects where verified and state='ready' and checksum=f.checksum and file_size=f.file_size
        and public.file_object_readable(id) order by id limit 1 for update;
      if found then
        update public.public_resources set storage_bucket=obj.bucket,object_key=obj.object_key,verified=true where id=f.id;
        result:=public.public_resources_before_shared_files(p_actor,'complete',jsonb_build_object('upload_id',f.upload_id));
      end if;
    end if;
  elsif p_action='complete' then
    select * into f from public.public_resources where id=(result->'file'->>'id')::uuid;
    perform public.file_canonicalize(f.object_id);
    select jsonb_build_object('file',to_jsonb(r)) into result from public.public_resources r where r.id=f.id;
  end if;
  return result;
end $$;
revoke all on function public.public_resources_service_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.public_resources_service_v1(uuid,text,jsonb) to service_role;

-- Physical deletion is a leased, retryable job. Adding a reference and claiming
-- deletion both lock the same object row; a claimed object cannot be reattached.
create or replace function public.file_gc_v1(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare obj public.file_objects; result jsonb:='[]'; token uuid;
begin
  if p_action='claim' then
    for obj in select * from public.file_objects where ref_count=0 and state<>'deleted' and not_before<now()
      and (claim_until is null or claim_until<now()) order by id limit 20 for update skip locked loop
      if exists(select 1 from public.file_references where object_id=obj.id) then raise exception 'REFERENCE_COUNT_MISMATCH'; end if;
      token:=gen_random_uuid();
      update public.file_objects set state='deleting',claim_id=token,claim_until=now()+interval '5 minutes' where id=obj.id;
      result:=result||jsonb_build_array(jsonb_build_object('id',obj.id,'bucket',obj.bucket,'object_key',obj.object_key,'claim_id',token));
    end loop;
    return result;
  elsif p_action='ack' then
    update public.file_objects set state='deleted',claim_until=null where id=(p_data->>'id')::uuid
      and claim_id=(p_data->>'claim_id')::uuid and state='deleting' and ref_count=0;
    if not found then raise exception 'INVALID_CLAIM'; end if;
    return '{}';
  end if;
  raise exception 'INVALID_REQUEST';
end $$;
revoke all on function public.file_gc_v1(text,jsonb) from public,anon,authenticated;
grant execute on function public.file_gc_v1(text,jsonb) to service_role;

create or replace function public.file_storage_delete_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare obj public.file_objects;
begin
  select * into obj from public.file_objects where bucket=old.bucket_id and object_key=old.name for update;
  if found and (obj.ref_count>0 or obj.state<>'deleting') then raise exception 'FILE_STILL_REFERENCED'; end if;
  return old;
end $$;
create or replace trigger file_storage_delete_guard before delete on storage.objects
  for each row execute function public.file_storage_delete_guard();

revoke all on function public.file_ref_count(),public.file_register(text,text,uuid,text,bigint,boolean,timestamptz),
 public.file_public_reference(),public.file_community_object(),public.file_group_reference(),public.file_object_readable(uuid),
 public.file_canonicalize(uuid),public.file_storage_delete_guard() from public,anon,authenticated;
-- Browser shares must resolve the canonical bucket as well as its object key.
do $patch$
declare definition text; fn record;
begin
  if to_regprocedure('public.public_resource_web_resolve(text,boolean)') is not null then
    definition:=pg_get_functiondef('public.public_resource_web_resolve(text,boolean)'::regprocedure);
    definition:=replace(definition,'jsonb_build_object(''object_key'',f.object_key)',
      'jsonb_build_object(''object_key'',f.object_key,''storage_bucket'',f.storage_bucket)');
    execute definition;
  end if;
  -- Count physical public objects, not every public/group reference to them.
  for fn in select oid from pg_proc where pronamespace='public'::regnamespace
    and proname in ('public_resources_before_discovery','public_resources_before_shared_files') loop
    definition:=pg_get_functiondef(fn.oid);
    definition:=replace(definition,
      'select coalesce(sum(file_size),0) into used from public.public_resources where status<>''deleted'';',
      'select coalesce(sum(file_size),0) into used from public.file_objects where bucket=''public-resources'' and state<>''deleted'';');
    definition:=replace(definition,'if used+amount>cfg.total_bytes then',
      'if used+(case when exists(select 1 from public.file_objects o where o.verified and o.state=''ready'' and o.checksum=p_data->>''checksum'' and o.file_size=amount and public.file_object_readable(o.id)) then 0 else amount end)>cfg.total_bytes then');
    execute definition;
  end loop;
end $patch$;
notify pgrst,'reload schema';
commit;
