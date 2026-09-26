begin;
-- Optional backend-managed route from a practice notice to its existing group.
alter table public.app_notices add column if not exists group_id uuid references public.chat_rooms(id);
create table if not exists public.chat_group_settings (
 group_id uuid primary key references public.chat_rooms(id), all_muted boolean not null default false,
 allow_upload boolean not null default true, history_files boolean not null default true,
 storage_limit bigint not null default 1073741824 check(storage_limit>=0)
);
create table if not exists public.chat_group_roles (
 group_id uuid references public.chat_rooms(id), user_id uuid references auth.users(id),
 role text not null default 'member' check(role in ('admin','member')), muted_until timestamptz,
 primary key(group_id,user_id)
);
create table if not exists public.chat_group_folders (
 id uuid primary key default gen_random_uuid(),group_id uuid not null references public.chat_rooms(id),name text not null check(length(name) between 1 and 100),position integer not null default 0,deleted_at timestamptz
);
create table if not exists public.group_file_reservations (
 id uuid primary key,group_id uuid not null references public.chat_rooms(id),owner_id uuid not null references auth.users(id),
 size bigint not null check(size between 1 and 104857600),created_at timestamptz not null default now(),committed boolean not null default false
);
create table if not exists public.community_files (
 id uuid primary key,owner_user_id uuid not null references auth.users(id),storage_provider text not null default 'supabase' check(storage_provider='supabase'),
 bucket text not null default 'group-files' check(bucket='group-files'), object_key text not null unique,
 file_name text not null check(length(file_name) between 1 and 200),file_size bigint not null check(file_size between 1 and 104857600),
 checksum text not null check(checksum ~ '^[a-f0-9]{64}$'),created_at timestamptz not null default now()
);
create table if not exists public.chat_group_files (
 id uuid primary key,group_id uuid not null references public.chat_rooms(id),uploader_id uuid not null references auth.users(id),
 file_id uuid not null references public.community_files(id),folder_id uuid references public.chat_group_folders(id),
 album boolean not null default false,created_at timestamptz not null default now(),deleted_at timestamptz
);
create table if not exists public.chat_group_content (
 id uuid primary key,group_id uuid not null references public.chat_rooms(id),author_id uuid not null references auth.users(id),
 kind text not null check(kind in ('announcement','highlight','event')),title text not null check(length(title) between 1 and 160),
 body text not null default '' check(length(body)<=20000),payload jsonb not null default '{}',
 is_pinned boolean not null default false,start_at timestamptz,created_at timestamptz not null default now(),deleted_at timestamptz
);
create table if not exists public.chat_group_reads (
 item_id uuid references public.chat_group_content(id),user_id uuid references auth.users(id),read_at timestamptz not null default now(),primary key(item_id,user_id)
);
create table if not exists public.group_practices (
 id uuid primary key,group_id uuid not null references public.chat_rooms(id),creator_id uuid not null references auth.users(id),
 title text not null check(length(title) between 1 and 160),target bigint not null check(target between 1 and 9000000000000000),
 created_at timestamptz not null default now(),closed_at timestamptz
);
create table if not exists public.group_practice_members (
 practice_id uuid references public.group_practices(id),user_id uuid references auth.users(id),joined_at timestamptz not null default now(),primary key(practice_id,user_id)
);
create table if not exists public.group_practice_counts (
 event_id uuid not null,user_id uuid not null references auth.users(id),practice_id uuid not null references public.group_practices(id),
 amount integer not null default 1 check(amount=1),created_at timestamptz not null default now(),primary key(user_id,event_id)
);
create table if not exists public.saved_content (
 user_id uuid references auth.users(id),kind text not null check(kind in ('resource','group_file')),source_id text not null,
 title text not null,metadata jsonb not null default '{}',created_at timestamptz not null default now(),primary key(user_id,kind,source_id)
);
do $policies$
declare t text;
begin
 foreach t in array array['group_file_reservations','chat_group_settings','chat_group_roles','chat_group_folders','community_files','chat_group_files','chat_group_content','chat_group_reads','group_practices','group_practice_members','group_practice_counts','saved_content'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
 end loop;
end $policies$;
create or replace function public.group_manager(p_group uuid) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select public.chat_member(p_group) and (exists(select 1 from public.chat_rooms where id=p_group and kind='group' and owner_id=auth.uid()) or exists(select 1 from public.chat_group_roles where group_id=p_group and user_id=auth.uid() and role='admin'))
$$;
create or replace function public.group_speak_allowed(p_group uuid) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select not exists(select 1 from public.chat_rooms where id=p_group and kind='group') or public.group_manager(p_group) or (
 not exists(select 1 from public.chat_group_settings where group_id=p_group and all_muted)
 and not exists(select 1 from public.chat_group_roles where group_id=p_group and user_id=auth.uid() and muted_until>now()))
$$;
revoke all on function public.group_manager(uuid),public.group_speak_allowed(uuid) from public;
grant execute on function public.group_manager(uuid),public.group_speak_allowed(uuid) to authenticated;
-- Enforce mute for every current/old message endpoint, including voice attachments.
create or replace function public.guard_group_message() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if auth.uid() is not null and not public.group_speak_allowed(new.room_id) then raise exception 'GROUP_MUTED' using errcode='42501'; end if;
 return new;
end $$;
drop trigger if exists chat_group_mute_guard on public.chat_messages;
create trigger chat_group_mute_guard before insert on public.chat_messages for each row execute function public.guard_group_message();
create or replace function public.group_file_readable(p_file uuid) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from auth.users where id=auth.uid() and not coalesce(is_anonymous,false)) and exists(select 1 from public.chat_group_files f where f.file_id=p_file and f.deleted_at is null and public.chat_member(f.group_id)
 and (coalesce((select history_files from public.chat_group_settings where group_id=f.group_id),true) or public.group_manager(f.group_id)
 or f.created_at >= (select joined_at from public.chat_members where room_id=f.group_id and user_id=auth.uid())))
$$;
revoke all on function public.group_file_readable(uuid) from public;
grant execute on function public.group_file_readable(uuid) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit) values('group-files','group-files',false,104857600) on conflict(id) do nothing;
drop policy if exists group_file_upload on storage.objects;
create policy group_file_upload on storage.objects for insert to authenticated with check(bucket_id='group-files'
 and split_part(name,'/',2)=auth.uid()::text and public.chat_member(split_part(name,'/',1)::uuid)
 and (public.group_manager(split_part(name,'/',1)::uuid) or coalesce((select allow_upload from public.chat_group_settings where group_id=split_part(name,'/',1)::uuid),true)));
-- No direct update/delete: publishing uses immutable UUID paths, retirement is metadata-only.
drop policy if exists group_file_download on storage.objects;
create policy group_file_download on storage.objects for select to authenticated using(bucket_id='group-files' and exists(select 1 from public.community_files f where f.object_key=name and public.group_file_readable(f.id)));
-- Policy joins need a restricted safe projection through helpers, never raw file metadata access.
create or replace function public.group_object_readable(p_key text) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.community_files where object_key=p_key and public.group_file_readable(id))
$$;
create or replace function public.group_upload_allowed(p_group uuid) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from auth.users where id=auth.uid() and not coalesce(is_anonymous,false)) and public.chat_member(p_group) and exists(select 1 from public.chat_rooms where id=p_group and kind='group') and (public.group_manager(p_group) or coalesce((select allow_upload from public.chat_group_settings where group_id=p_group),true))
$$;
revoke all on function public.group_object_readable(text),public.group_upload_allowed(uuid) from public;
grant execute on function public.group_object_readable(text),public.group_upload_allowed(uuid) to authenticated;
drop policy group_file_upload on storage.objects;
create or replace function public.group_reserved_upload(p_key text,p_size bigint) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.group_file_reservations r where r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text=p_key and r.size=p_size and r.owner_id=auth.uid() and not r.committed and r.created_at>now()-interval '1 day' and public.group_upload_allowed(r.group_id))
$$;
revoke all on function public.group_reserved_upload(text,bigint) from public;
grant execute on function public.group_reserved_upload(text,bigint) to authenticated;
create policy group_file_upload on storage.objects for insert to authenticated with check(bucket_id='group-files' and public.group_reserved_upload(name,(metadata->>'size')::bigint));
drop policy group_file_download on storage.objects;
create policy group_file_download on storage.objects for select to authenticated using(bucket_id='group-files' and public.group_object_readable(name));

create or replace function public.group_learning_v1(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid(); gid uuid:=(p_data->>'group_id')::uuid; iid uuid:=(p_data->>'id')::uuid; manager boolean; owner boolean; target uuid; result jsonb; item record; n bigint; object_path text; current_practice public.group_practices;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED'; end if;
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then raise exception 'invalid_input'; end if;
 if p_action='saved_list' then return coalesce((select jsonb_agg(to_jsonb(t)) from (select * from public.saved_content where user_id=actor order by created_at desc limit 500)t),'[]'); end if;
 if p_action='save_reference' then
  if length(p_data->>'source_id')>100 or length(p_data->>'title')>200 then raise exception 'invalid_input'; end if;
  if p_data->>'kind'='group_file' and not public.group_file_readable((p_data->>'source_id')::uuid) then raise exception 'denied'; end if;
  insert into public.saved_content(user_id,kind,source_id,title,metadata) values(actor,p_data->>'kind',p_data->>'source_id',p_data->>'title',coalesce(p_data->'metadata','{}')) on conflict(user_id,kind,source_id) do nothing;
  return '{}'::jsonb;
 end if;
 if p_action='my_groups' then return coalesce((select jsonb_agg(to_jsonb(t)) from (select r.id,r.title from public.chat_rooms r where r.kind='group' and public.chat_member(r.id) order by r.created_at desc)t),'[]'); end if;
 if not public.chat_member(gid) or not exists(select 1 from public.chat_rooms where id=gid and kind='group') then raise exception 'denied' using errcode='42501'; end if;
 manager:=public.group_manager(gid);owner:=exists(select 1 from public.chat_rooms where id=gid and owner_id=actor);
 if p_action='more_files' then
  if (p_data->>'offset')::integer not between 0 and 1000000 then raise exception 'invalid_offset';end if;
  return coalesce((select jsonb_agg(to_jsonb(t)) from(select f.*,a.storage_provider,a.object_key,a.bucket,a.file_name,a.file_size,a.checksum from public.chat_group_files f join public.community_files a on a.id=f.file_id where f.group_id=gid and public.group_file_readable(f.file_id) order by f.created_at desc,f.id limit 500 offset (p_data->>'offset')::integer)t),'[]');
 end if;
 if p_action='file_get' then
  if not public.group_file_readable(iid) then raise exception 'denied';end if;
  return (select to_jsonb(f)||to_jsonb(a) from public.chat_group_files f join public.community_files a on a.id=f.file_id where f.file_id=iid and f.group_id=gid and f.deleted_at is null);
 end if;
 if p_action='overview' then
  return jsonb_build_object('manager',manager,'owner',owner,'settings',coalesce((select to_jsonb(s) from public.chat_group_settings s where group_id=gid),'{}'),
  'folders',coalesce((select jsonb_agg(to_jsonb(f) order by position,name) from public.chat_group_folders f where group_id=gid and deleted_at is null),'[]'),
  'files',coalesce((select jsonb_agg(to_jsonb(t)) from (select f.*,a.storage_provider,a.object_key,a.bucket,a.file_name,a.file_size,a.checksum from public.chat_group_files f join public.community_files a on a.id=f.file_id where group_id=gid and public.group_file_readable(f.file_id) order by f.created_at desc,f.id limit 500)t),'[]'),
  'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select c.*,(select count(*) from public.chat_group_reads where item_id=c.id) read_count,exists(select 1 from public.chat_group_reads where item_id=c.id and user_id=actor) is_read from public.chat_group_content c where group_id=gid and deleted_at is null order by is_pinned desc,created_at desc limit 500)t),'[]'),
  'practices',coalesce((select jsonb_agg(to_jsonb(t)) from (select x.*,(select count(*) from public.group_practice_members where practice_id=x.id) participants,(select coalesce(sum(amount),0) from public.group_practice_counts where practice_id=x.id) total,(select coalesce(sum(amount),0) from public.group_practice_counts where practice_id=x.id and user_id=actor) mine,exists(select 1 from public.group_practice_members where practice_id=x.id and user_id=actor) joined from public.group_practices x where group_id=gid order by created_at desc)t),'[]'),
  'roles',case when manager then coalesce((select jsonb_agg(to_jsonb(x)) from public.chat_group_roles x where group_id=gid),'[]') else '[]'::jsonb end);
 end if;
 if p_action='search' then
  if length(coalesce(p_data->>'query','')) not between 1 and 100 then raise exception 'invalid_query';end if;
  return jsonb_build_object('messages',coalesce((select jsonb_agg(to_jsonb(t)) from (select id,sender_id,body,created_at from public.chat_messages where room_id=gid and recalled_at is null and strpos(lower(body),lower(p_data->>'query'))>0 order by created_at desc limit 100)t),'[]'),
  'files',coalesce((select jsonb_agg(to_jsonb(t)) from (select f.id,a.file_name from public.chat_group_files f join public.community_files a on a.id=f.file_id where group_id=gid and public.group_file_readable(f.file_id) and strpos(lower(a.file_name),lower(p_data->>'query'))>0 limit 100)t),'[]'),
  'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select id,kind,title,body from public.chat_group_content where group_id=gid and deleted_at is null and strpos(lower(title||' '||body),lower(p_data->>'query'))>0 limit 100)t),'[]'),
  'members',coalesce((select jsonb_agg(to_jsonb(t)) from (select m.user_id,p.nickname from public.chat_members m join public.chat_profiles p on p.user_id=m.user_id where room_id=gid and left_at is null and strpos(lower(p.nickname),lower(p_data->>'query'))>0 limit 100)t),'[]'));
 end if;
 if p_action='file_reserve' then
  if not public.group_upload_allowed(gid) then raise exception 'UPLOAD_DISABLED';end if;
  perform pg_advisory_xact_lock(hashtextextended(gid::text,31));
  select * into item from public.group_file_reservations where id=iid;
  if found then if item.group_id=gid and item.owner_id=actor and item.size=(p_data->>'file_size')::bigint then return to_jsonb(item);else raise exception 'denied';end if;end if;
  n:=(p_data->>'file_size')::bigint;
  -- Reservations count even if abandoned, so orphaned storage cannot evade quota.
  if n+coalesce((select sum(size) from public.group_file_reservations where group_id=gid),0)>coalesce((select storage_limit from public.chat_group_settings where group_id=gid),1073741824) then raise exception 'GROUP_QUOTA_EXCEEDED';end if;
  insert into public.group_file_reservations(id,group_id,owner_id,size) values(iid,gid,actor,n);
  return jsonb_build_object('id',iid);
 end if;
 if p_action='file_add' then
  if not public.group_upload_allowed(gid) then raise exception 'UPLOAD_DISABLED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(gid::text,31));
  select * into item from public.chat_group_files where id=iid;
  if found then if item.group_id=gid and item.uploader_id=actor then return to_jsonb(item);else raise exception 'denied';end if;end if;
  object_path:=gid::text||'/'||actor::text||'/'||iid::text;
  select (metadata->>'size')::bigint into n from storage.objects where bucket_id='group-files' and name=object_path;
  if not exists(select 1 from public.group_file_reservations where id=iid and group_id=gid and owner_id=actor and size=n) then raise exception 'reservation_required';end if;
  if n is null or n<>(p_data->>'file_size')::bigint then raise exception 'file_missing';end if;
  if n+coalesce((select sum(a.file_size) from public.chat_group_files f join public.community_files a on a.id=f.file_id where group_id=gid and f.deleted_at is null),0)>coalesce((select storage_limit from public.chat_group_settings where group_id=gid),1073741824) then raise exception 'GROUP_QUOTA_EXCEEDED';end if;
  if nullif(p_data->>'folder_id','') is not null and not exists(select 1 from public.chat_group_folders where id=(p_data->>'folder_id')::uuid and group_id=gid and deleted_at is null) then raise exception 'invalid_folder';end if;
  insert into public.community_files(id,owner_user_id,object_key,file_name,file_size,checksum) values(iid,actor,object_path,p_data->>'file_name',n,p_data->>'checksum');
  insert into public.chat_group_files(id,group_id,uploader_id,file_id,folder_id,album) values(iid,gid,actor,iid,nullif(p_data->>'folder_id','')::uuid,coalesce((p_data->>'album')::boolean,false));
  update public.group_file_reservations set committed=true where id=iid;
  return jsonb_build_object('id',iid);
 end if;
 if p_action='read' then
  if not exists(select 1 from public.chat_group_content where id=iid and group_id=gid and deleted_at is null) then raise exception 'missing';end if;
  insert into public.chat_group_reads(item_id,user_id) values(iid,actor) on conflict do nothing;return '{}'::jsonb;
 end if;
 if p_action in ('join_practice','count','count_many') then
  select * into current_practice from public.group_practices where id=iid and group_id=gid and closed_at is null;
  if not found then raise exception 'practice_unavailable';end if;
  if p_action='join_practice' then insert into public.group_practice_members(practice_id,user_id) values(iid,actor) on conflict do nothing;
  else
   if not exists(select 1 from public.group_practice_members where practice_id=iid and user_id=actor) then raise exception 'join_required';end if;
   if p_action='count_many' then
    if jsonb_typeof(p_data->'event_ids') is distinct from 'array' or jsonb_array_length(p_data->'event_ids') not between 1 and 500 then raise exception 'invalid_input';end if;
    insert into public.group_practice_counts(event_id,user_id,practice_id) select value::uuid,actor,iid from jsonb_array_elements_text(p_data->'event_ids') on conflict(user_id,event_id) do nothing;
   else insert into public.group_practice_counts(event_id,user_id,practice_id) values((p_data->>'event_id')::uuid,actor,iid) on conflict(user_id,event_id) do nothing;end if;
  end if;
  return '{}'::jsonb;
 end if;
 if not manager then raise exception 'manager_required';end if;
 if p_action='settings' then
  insert into public.chat_group_settings(group_id,all_muted,allow_upload,history_files) values(gid,coalesce((p_data->>'all_muted')::boolean,false),coalesce((p_data->>'allow_upload')::boolean,true),coalesce((p_data->>'history_files')::boolean,true))
  on conflict(group_id) do update set all_muted=excluded.all_muted,allow_upload=excluded.allow_upload,history_files=excluded.history_files;
 elsif p_action in ('role','mute','remove_member') then
  target:=(p_data->>'user_id')::uuid;
  if not exists(select 1 from public.chat_members where room_id=gid and user_id=target and left_at is null) or exists(select 1 from public.chat_rooms where id=gid and owner_id=target) then raise exception 'denied';end if;
  if p_action='role' then
   if not owner then raise exception 'owner_required';end if;
   insert into public.chat_group_roles(group_id,user_id,role) values(gid,target,p_data->>'role') on conflict(group_id,user_id) do update set role=excluded.role;
  else
   if not owner and exists(select 1 from public.chat_group_roles where group_id=gid and user_id=target and role='admin') then raise exception 'denied';end if;
   if p_action='mute' then insert into public.chat_group_roles(group_id,user_id,muted_until) values(gid,target,nullif(p_data->>'until','')::timestamptz) on conflict(group_id,user_id) do update set muted_until=excluded.muted_until;
   else update public.chat_members set left_at=now() where room_id=gid and user_id=target; update public.chat_group_roles set role='member',muted_until=null where group_id=gid and user_id=target;end if;
  end if;
 elsif p_action='folder' then
  insert into public.chat_group_folders(id,group_id,name,position) values(iid,gid,p_data->>'name',coalesce((p_data->>'position')::integer,0))
  on conflict(id) do update set name=excluded.name,position=excluded.position where chat_group_folders.group_id=gid;
 elsif p_action in ('file_move','file_remove') then
  if p_action='file_remove' then update public.chat_group_files set deleted_at=now() where id=iid and group_id=gid;
  else
   if nullif(p_data->>'folder_id','') is not null and not exists(select 1 from public.chat_group_folders where id=(p_data->>'folder_id')::uuid and group_id=gid and deleted_at is null) then raise exception 'invalid_folder';end if;
   update public.chat_group_files set folder_id=nullif(p_data->>'folder_id','')::uuid where id=iid and group_id=gid;
  end if;
 elsif p_action='content' then
  delete from public.chat_group_reads where item_id=iid and exists(select 1 from public.chat_group_content where id=iid and group_id=gid and (title is distinct from p_data->>'title' or body is distinct from coalesce(p_data->>'body','')));
  insert into public.chat_group_content(id,group_id,author_id,kind,title,body,payload,is_pinned,start_at) values(iid,gid,actor,p_data->>'kind',p_data->>'title',coalesce(p_data->>'body',''),coalesce(p_data->'payload','{}'),coalesce((p_data->>'is_pinned')::boolean,false),nullif(p_data->>'start_at','')::timestamptz)
  on conflict(id) do update set title=excluded.title,body=excluded.body,payload=excluded.payload,is_pinned=excluded.is_pinned,start_at=excluded.start_at where chat_group_content.group_id=gid;
 elsif p_action='content_remove' then update public.chat_group_content set deleted_at=now() where id=iid and group_id=gid;
 elsif p_action='practice_create' then insert into public.group_practices(id,group_id,creator_id,title,target) values(iid,gid,actor,p_data->>'title',(p_data->>'target')::bigint) on conflict(id) do nothing;
 else raise exception 'invalid_action';end if;
 return '{}'::jsonb;
end $$;
revoke all on function public.group_learning_v1(text,jsonb) from public;
grant execute on function public.group_learning_v1(text,jsonb) to authenticated;
create or replace function public.reset_departed_group_role() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin if new.left_at is not null then update public.chat_group_roles set role='member' where group_id=new.room_id and user_id=new.user_id;end if;return new;end $$;
revoke all on function public.reset_departed_group_role() from public;
drop trigger if exists group_role_on_departure on public.chat_members;
create trigger group_role_on_departure after update of left_at on public.chat_members for each row execute function public.reset_departed_group_role();
notify pgrst,'reload schema';
commit;
