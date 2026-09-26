begin;
-- 500 MiB is an application ceiling, not a Supabase plan upgrade. The global
-- Storage limit still applies (Free: 50 MB). Operators may set buckets lower.
update storage.buckets set file_size_limit=524288000
where id in ('chat-files','group-files') and coalesce(file_size_limit,0)<524288000;
alter table public.group_file_reservations drop constraint if exists group_file_reservations_size_check;
alter table public.group_file_reservations add constraint group_file_reservations_size_check check(size between 1 and 524288000);
alter table public.community_files drop constraint if exists community_files_file_size_check;
alter table public.community_files add constraint community_files_file_size_check check(file_size between 1 and 524288000);
alter table public.chat_messages add column if not exists attachment_mime_type text;
create or replace function public.chat_attachment_size() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.attachment_path is not null then
  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype'
    into new.attachment_size,new.attachment_mime_type
    from storage.objects o where o.bucket_id='chat-files' and o.name=new.attachment_path limit 1;
  if lower(new.attachment_name) like '%.apk' then
   if lower(new.attachment_path) not like '%.apk' or new.attachment_size is null or new.attachment_size not between 1 and 524288000 then raise exception 'INVALID_APK_ATTACHMENT'; end if;
   new.attachment_mime_type:='application/vnd.android.package-archive';
  elsif new.attachment_size>10485760 then raise exception 'FILE_TOO_LARGE';
  end if;
 end if;
 return new;
end $$;
create or replace function public.group_reserved_upload(p_key text,p_size bigint) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.group_file_reservations r
 where (r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text=p_key
     or r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text||'.apk'=p_key)
 and r.size=p_size and r.owner_id=auth.uid() and not r.committed
 and r.created_at>now()-interval '1 day' and public.group_upload_allowed(r.group_id))
$$;
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
  if found then if item.group_id=gid and item.owner_id=actor and item.size=(p_data->>'file_size')::bigint then
   update public.group_file_reservations set created_at=now() where id=iid and not committed;
   return to_jsonb(item);else raise exception 'denied';end if;end if;
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
  if lower(p_data->>'file_name') like '%.apk' then object_path:=object_path||'.apk'; end if;
  select (metadata->>'size')::bigint into n from storage.objects where bucket_id='group-files' and name=object_path;
  if not exists(select 1 from public.group_file_reservations where id=iid and group_id=gid and owner_id=actor and size=n) then raise exception 'reservation_required';end if;
  if n is null or n<>(p_data->>'file_size')::bigint then raise exception 'file_missing';end if;
  if lower(p_data->>'file_name') not like '%.apk' and n>104857600 then raise exception 'FILE_TOO_LARGE'; end if;
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

notify pgrst,'reload schema';
commit;
