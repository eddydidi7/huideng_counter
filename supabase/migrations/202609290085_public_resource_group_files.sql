begin;

-- References share the existing object; no Storage copy or upload is performed.
alter table public.community_files drop constraint if exists community_files_bucket_check;
alter table public.community_files add constraint community_files_bucket_check
  check(bucket in ('group-files','public-resources'));
alter table public.community_files drop constraint if exists community_files_file_size_check;
alter table public.community_files add constraint community_files_file_size_check
  check(file_size >= 1 and (bucket='public-resources' or file_size<=524288000));
alter table public.community_files add column if not exists resource_id uuid
  references public.public_resources(id);
create unique index if not exists community_files_resource_reference
  on public.community_files(resource_id) where resource_id is not null;

create or replace function public.group_resource_v1(p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid(); gid uuid; resource public.public_resources;
  fid uuid; link_id uuid;
begin
  if actor is null or not exists(select 1 from auth.users where id=actor
    and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now()))
    or exists(select 1 from public.forum_restrictions where user_id=actor and blocked)
    then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
  if p_action='groups' then
    return coalesce((select jsonb_agg(to_jsonb(x)) from (
      select id,title from public.chat_rooms where kind='group'
      and public.group_upload_allowed(id) order by title,id
    ) x),'[]'::jsonb);
  end if;
  if not exists(select 1 from public.public_resource_settings where id and enabled and download_enabled)
    then raise exception 'RESOURCE_DISABLED'; end if;
  if p_action='get' then
    fid:=(p_data->>'file_id')::uuid;
    if not public.group_file_readable(fid) then raise exception 'denied' using errcode='42501'; end if;
    select r.* into resource from public.public_resources r
      join public.community_files f on f.resource_id=r.id where f.id=fid;
    if not found or resource.status<>'published' or not resource.verified
      then raise exception 'FILE_UNAVAILABLE'; end if;
    -- Download still goes through the public-resource service and its quota checks.
    return jsonb_build_object('id',resource.id,'file_name',resource.file_name,
      'file_size',resource.file_size,'checksum',resource.checksum,'status',resource.status);
  end if;
  if p_action<>'save' then raise exception 'invalid_action'; end if;
  gid:=(p_data->>'group_id')::uuid;
  if not coalesce(public.group_upload_allowed(gid),false)
    then raise exception 'UPLOAD_DISABLED' using errcode='42501'; end if;
  -- Serialize saves of the same resource, including saves to different groups.
  select * into resource from public.public_resources where id=(p_data->>'resource_id')::uuid for update;
  if not found or resource.status<>'published' or not resource.verified
    then raise exception 'FILE_UNAVAILABLE'; end if;
  select id into fid from public.community_files where resource_id=resource.id;
  if fid is null then
    fid:=gen_random_uuid();
    insert into public.community_files(id,owner_user_id,bucket,object_key,file_name,file_size,checksum,resource_id)
      values(fid,resource.user_id,'public-resources',resource.object_key,
        resource.file_name,resource.file_size,resource.checksum,resource.id);
  end if;
  select id into link_id from public.chat_group_files
    where group_id=gid and file_id=fid and deleted_at is null limit 1;
  if link_id is not null then return jsonb_build_object('id',link_id,'already_saved',true); end if;
  link_id:=gen_random_uuid();
  insert into public.chat_group_files(id,group_id,uploader_id,file_id)
    values(link_id,gid,actor,fid);
  return jsonb_build_object('id',link_id,'already_saved',false);
end $$;
revoke all on function public.group_resource_v1(text,jsonb) from public,anon;
grant execute on function public.group_resource_v1(text,jsonb) to authenticated;

-- Shared public objects do not consume a second group upload quota.
do $patch$
declare definition text; old_rule text; new_rule text;
begin
  definition:=pg_get_functiondef('public.group_learning_v1(text,jsonb)'::regprocedure);
  old_rule:='where group_id=gid and f.deleted_at is null),0)';
  new_rule:='where group_id=gid and f.deleted_at is null and a.bucket=''group-files''),0)';
  if position(new_rule in definition)=0 then
    if position(old_rule in definition)=0 then raise exception 'Cannot locate group file quota validation'; end if;
    execute replace(definition,old_rule,new_rule);
  end if;
end $patch$;

notify pgrst,'reload schema';
commit;
