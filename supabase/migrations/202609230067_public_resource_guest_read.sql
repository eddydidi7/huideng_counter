-- Anonymous users can read only published, verified, non-moderated resources.
-- No upload/delete policy is granted to anon.
create or replace function public.public_resource_guest_v1(p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare f public.public_resources; cfg public.public_resource_settings; items jsonb;
begin
 select * into cfg from public.public_resource_settings where id;
 if not found or not cfg.enabled then raise exception 'RESOURCE_DISABLED'; end if;
 if p_action='list' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into items from (
   select id,file_name,file_size,checksum,category,description,author_name,status,created_at
   from public.public_resources
   where status='published' and verified and not moderated
     and (coalesce(p_data->>'category','')='' or category=p_data->>'category')
     and (coalesce(p_data->>'search','')='' or strpos(lower(file_name||' '||description),lower(left(p_data->>'search',150)))>0)
   order by created_at desc,id desc limit 51
  ) x;
  return jsonb_build_object('config',jsonb_build_object('enabled',cfg.enabled,'download_enabled',cfg.download_enabled),'files',items,'next_cursor',null);
 end if;
 if p_action in ('download','preview','share') then
  select * into f from public.public_resources where id=(p_data->>'id')::uuid and status='published' and verified and not moderated;
  if not found then raise exception 'FILE_UNAVAILABLE'; end if;
  if p_action='download' and not cfg.download_enabled then raise exception 'DOWNLOAD_DISABLED'; end if;
  return jsonb_build_object('file',to_jsonb(f));
 end if;
 raise exception 'ACTION_NOT_ALLOWED';
end $$;
revoke all on function public.public_resource_guest_v1(text,jsonb) from public;
grant execute on function public.public_resource_guest_v1(text,jsonb) to service_role;
