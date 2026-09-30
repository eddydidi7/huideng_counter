begin;
alter table public.file_objects add column if not exists verify_lease_id uuid,
  add column if not exists verify_until timestamptz;
create table if not exists public.file_download_usage (
  user_id uuid not null references auth.users(id),bytes bigint not null,created_at timestamptz not null default now()
);
create index if not exists file_download_usage_user on public.file_download_usage(user_id,created_at);
alter table public.file_download_usage enable row level security;
revoke all on public.file_download_usage from public,anon,authenticated;

create or replace function public.group_resource_v1(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); cfg public.public_resource_settings; r public.public_resources;
  c public.community_files; obj public.file_objects; gid uuid; fid uuid; rid uuid; result jsonb:='[]';
begin
  if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)
    and (banned_until is null or banned_until<now())) or exists(select 1 from public.forum_restrictions where user_id=actor and blocked)
    then raise exception 'LOGIN_REQUIRED'; end if;
  select * into cfg from public.public_resource_settings where id for update;
  if p_action='get' then
    select * into c from public.community_files where id=(p_data->>'file_id')::uuid;
    if not found or not public.group_file_readable(c.id) then raise exception 'FORBIDDEN'; end if;
    select * into obj from public.file_objects where id=c.object_id and state='ready';
    if not found then raise exception 'FILE_UNAVAILABLE'; end if;
    return jsonb_build_object('id',c.id,'file_name',c.file_name,'file_size',c.file_size,'checksum',c.checksum,
      'status','published','object_id',obj.id,'object_key',obj.object_key,'storage_bucket',obj.bucket,
      'mime_type','application/octet-stream','verified',obj.verified);
  end if;
  if p_action='reuse' then
    gid:=(p_data->>'group_id')::uuid;
    if not coalesce(public.group_upload_allowed(gid),false) then raise exception 'UPLOAD_DISABLED'; end if;
    if coalesce(length(p_data->>'file_name'),0) not between 1 and 200 then raise exception 'INVALID_REQUEST'; end if;
    if nullif(p_data->>'folder_id','') is not null and not exists(select 1 from public.chat_group_folders
      where id=(p_data->>'folder_id')::uuid and group_id=gid and deleted_at is null) then raise exception 'INVALID_REQUEST'; end if;
    select * into obj from public.file_objects where checksum=p_data->>'checksum' and file_size=(p_data->>'file_size')::bigint
      and verified and state='ready' and public.file_object_readable(id) order by id limit 1 for update;
    if not found then return jsonb_build_object('reused',false); end if;
    -- This is an upload optimization, not an ACL grant based only on a hash.
    select * into c from public.community_files where object_id=obj.id and file_name=p_data->>'file_name' order by id limit 1;
    if not found then
      insert into public.community_files(id,owner_user_id,bucket,object_key,file_name,file_size,checksum)
        values(gen_random_uuid(),obj.owner_id,obj.bucket,obj.object_key,p_data->>'file_name',obj.file_size,obj.checksum) returning * into c;
    end if;
    select id into rid from public.chat_group_files where group_id=gid and file_id=c.id and deleted_at is null
      and album=coalesce((p_data->>'album')::boolean,false) and folder_id is not distinct from nullif(p_data->>'folder_id','')::uuid limit 1;
    if rid is null then
      rid:=gen_random_uuid(); insert into public.chat_group_files(id,group_id,uploader_id,file_id,album,folder_id)
        values(rid,gid,actor,c.id,coalesce((p_data->>'album')::boolean,false),nullif(p_data->>'folder_id','')::uuid);
    end if;
    return jsonb_build_object('reused',true,'id',rid);
  end if;
  if not cfg.group_transfer_enabled then raise exception 'TRANSFER_DISABLED'; end if;
  if p_action='groups' then
    return coalesce((select jsonb_agg(to_jsonb(x)) from (
      select id,title from public.chat_rooms where kind='group' and public.group_upload_allowed(id) order by title,id
    ) x),'[]');
  elsif p_action='categories' then return cfg.categories;
  elsif p_action='publish' then
    if not cfg.enabled or not cfg.upload_enabled then raise exception 'UPLOAD_DISABLED'; end if;
    if not cfg.categories ? (p_data->>'category') then raise exception 'INVALID_CATEGORY'; end if;
    select * into c from public.community_files where id=(p_data->>'file_id')::uuid;
    if not found or not public.group_file_readable(c.id) then raise exception 'FORBIDDEN'; end if;
    select * into obj from public.file_objects where id=c.object_id and state='ready' for update;
    if not found or not obj.verified then raise exception 'VERIFY_REQUIRED'; end if;
    if to_regprocedure('public.resource_upload_check(text,bigint,text)') is not null then
      perform public.resource_upload_check(c.file_name,0,'application/octet-stream');
    end if;
    select id into rid from public.public_resources where object_id=obj.id and user_id=actor and status='published' and not moderated limit 1;
    if rid is not null then return jsonb_build_object('id',rid,'already_saved',true); end if;
    rid:=gen_random_uuid();
    insert into public.public_resources(id,user_id,upload_id,file_name,file_size,checksum,category,object_key,storage_bucket,
      status,verified,published_at,author_name)
      values(rid,actor,gen_random_uuid(),c.file_name,c.file_size,c.checksum,p_data->>'category',obj.object_key,obj.bucket,
        'published',true,now(),coalesce((select nickname from public.chat_profiles where user_id=actor),'学友'));
    return jsonb_build_object('id',rid,'already_saved',false);
  elsif p_action not in ('save','save_many') then raise exception 'INVALID_REQUEST'; end if;
  if not cfg.enabled or not cfg.download_enabled then raise exception 'DOWNLOAD_DISABLED'; end if;
  if p_action='save' then p_data:=p_data||jsonb_build_object('group_ids',jsonb_build_array(p_data->>'group_id')); end if;
  if jsonb_typeof(p_data->'group_ids') is distinct from 'array' or jsonb_array_length(p_data->'group_ids') not between 1 and 100
    then raise exception 'INVALID_REQUEST'; end if;
  select * into r from public.public_resources where id=(p_data->>'resource_id')::uuid for update;
  if not found or r.status<>'published' or not r.verified or r.moderated then raise exception 'FILE_UNAVAILABLE'; end if;
  select * into obj from public.file_objects where id=r.object_id and state='ready' for update;
  if not found then raise exception 'FILE_UNAVAILABLE'; end if;
  select id into fid from public.community_files where resource_id=r.id;
  if fid is null then
    fid:=gen_random_uuid(); insert into public.community_files(id,owner_user_id,bucket,object_key,file_name,file_size,checksum,resource_id)
      values(fid,obj.owner_id,obj.bucket,obj.object_key,r.file_name,r.file_size,r.checksum,r.id);
  end if;
  for gid in select distinct value::uuid from jsonb_array_elements_text(p_data->'group_ids') order by 1 loop
    if not coalesce(public.group_upload_allowed(gid),false) then raise exception 'UPLOAD_DISABLED'; end if;
    select id into rid from public.chat_group_files where group_id=gid and file_id=fid and deleted_at is null limit 1;
    if rid is null then
      rid:=gen_random_uuid(); insert into public.chat_group_files(id,group_id,uploader_id,file_id) values(rid,gid,actor,fid);
    end if;
    result:=result||jsonb_build_array(jsonb_build_object('id',rid,'group_id',gid));
  end loop;
  return jsonb_build_object('saved',result);
end $$;
revoke all on function public.group_resource_v1(text,jsonb) from public,anon;
grant execute on function public.group_resource_v1(text,jsonb) to authenticated;

create or replace function public.shared_file_service_v1(p_actor uuid,p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare f jsonb; obj public.file_objects; cfg public.public_resource_settings; oid uuid; usage bigint;
begin
  perform set_config('request.jwt.claim.sub',p_actor::text,true);
  f:=public.group_resource_v1('get',p_data);
  select * into obj from public.file_objects where id=(f->>'object_id')::uuid for update;
  if p_action='group.download' then
    select * into cfg from public.public_resource_settings where id for update;
    select coalesce(sum(bytes),0) into usage from public.file_download_usage where user_id=p_actor and created_at>=date_trunc('day',now());
    if usage+obj.file_size>cfg.daily_download_bytes then raise exception 'DOWNLOAD_LIMIT'; end if;
    insert into public.file_download_usage(user_id,bytes) values(p_actor,obj.file_size);
    return jsonb_build_object('file',f);
  elsif p_action='group.verify_start' then
    if obj.verified then return jsonb_build_object('file',f||jsonb_build_object('verified',true)); end if;
    if obj.verify_until>now() then raise exception 'UPLOAD_BUSY'; end if;
    update public.file_objects set verify_lease_id=(p_data->>'lease_id')::uuid,verify_until=now()+interval '2 minutes' where id=obj.id;
    return jsonb_build_object('file',f||jsonb_build_object('verified',false,'verify_offset',obj.verify_offset,'verify_state',obj.verify_state));
  elsif p_action='group.verify_step' then
    if obj.verify_lease_id is distinct from (p_data->>'lease_id')::uuid or obj.verify_until<now()
      or obj.verify_offset is distinct from (p_data->>'expected_offset')::bigint
      or (p_data->>'offset')::bigint is distinct from least(obj.verify_offset+8388608,obj.file_size) then raise exception 'VERIFY_FAILED'; end if;
    if (p_data->>'offset')::bigint=obj.file_size then
      if p_data->>'checksum' is distinct from obj.checksum then raise exception 'VERIFY_FAILED'; end if;
      update public.file_objects set verified=true,verify_offset=file_size,verify_state=null,verify_until=null where id=obj.id;
      oid:=public.file_canonicalize(obj.id);
      return jsonb_build_object('verified',true,'object_id',oid);
    end if;
    if jsonb_typeof(p_data->'state') is distinct from 'array' or jsonb_array_length(p_data->'state')<>8 then raise exception 'VERIFY_FAILED'; end if;
    update public.file_objects set verify_offset=(p_data->>'offset')::bigint,verify_state=p_data->'state',verify_until=null where id=obj.id;
    return jsonb_build_object('verified',false);
  end if;
  raise exception 'INVALID_REQUEST';
end $$;
revoke all on function public.shared_file_service_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.shared_file_service_v1(uuid,text,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
