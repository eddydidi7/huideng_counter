begin;
-- File types are derived without rewriting users' existing content categories.
create or replace function public.resource_display_type(p_name text,p_mime text)
returns text language sql immutable set search_path='' as $$
 select case
 when lower(p_mime) like 'image/%' or lower(p_name) ~ '\.(jpg|jpeg|png|webp|gif|heic|bmp)$' then 'image'
 when lower(p_mime) like 'audio/%' or lower(p_name) ~ '\.(mp3|m4a|wav|ogg|flac|aac)$' then 'audio'
 when lower(p_mime) like 'video/%' or lower(p_name) ~ '\.(mp4|mov|mkv|webm|avi)$' then 'video'
 when lower(p_name) ~ '\.(pdf|doc|docx|txt|md|rtf|epub|ppt|pptx|xls|xlsx|csv)$' then 'document'
 else 'file' end
$$;
revoke all on function public.resource_display_type(text,text) from public,anon,authenticated;
-- Preserve the installed upload/download/governance implementation intact.
do $$ begin
 if to_regprocedure('public.public_resources_before_discovery(uuid,text,jsonb)') is null then
   alter function public.public_resources_service_v1(uuid,text,jsonb) rename to public_resources_before_discovery;
 end if;
end $$;
revoke all on function public.public_resources_before_discovery(uuid,text,jsonb) from public,anon,authenticated;
create or replace function public.public_resources_service_v1(p_actor uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare cfg public.public_resource_settings; used bigint; items jsonb; sort_name text; cur jsonb; last_row jsonb;
begin
 if p_action is distinct from 'list' then return public.public_resources_before_discovery(p_actor,p_action,p_data); end if;
 if p_actor is null or not exists(select 1 from auth.users where id=p_actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'LOGIN_REQUIRED';end if;
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'INVALID_REQUEST';end if;
 select * into cfg from public.public_resource_settings where id;
 if not found then raise exception 'RESOURCE_NOT_CONFIGURED';end if;
 if exists(select 1 from public.forum_restrictions where user_id=p_actor and blocked) then raise exception 'LOGIN_REQUIRED';end if;
 select coalesce(sum(file_size),0) into used from public.public_resources where status<>'deleted';
 if p_action='list' then
 cur:=nullif(p_data->>'cursor','')::jsonb;sort_name:=coalesce(p_data->>'sort','time');
 if sort_name not in ('time','name','size','popular') or (cur is not null and (cur->>'sort' is distinct from sort_name or cur->>'id' is null or cur->>'at' is null)) then raise exception 'INVALID_REQUEST';end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select id,file_name,file_size,checksum,category,description,author_name,status,created_at, (select count(*) from public.public_resource_downloads d where d.resource_id=public_resources.id) download_count from public.public_resources where cfg.enabled and not moderated and (status='published' or (p_data->>'scope'='mine' and user_id=p_actor and status='uploading')) and (coalesce(p_data->>'scope','public')<>'mine' or user_id=p_actor) and (coalesce(p_data->>'category','')='' or category=p_data->>'category' or ('type:'||public.resource_display_type(file_name,mime_type))=p_data->>'category') and (coalesce(p_data->>'search','')='' or strpos(lower(file_name||' '||description),lower(left(p_data->>'search',150)))>0)
 and (cur is null or (sort_name='popular' and ((select count(*) from public.public_resource_downloads d where d.resource_id=public_resources.id),created_at,id)<((cur->>'downloads')::bigint,(cur->>'at')::timestamptz,(cur->>'id')::uuid)) or (sort_name='time' and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)) or (sort_name='name' and (file_name>cur->>'name' or (file_name=cur->>'name' and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)))) or (sort_name='size' and (file_size<(cur->>'size')::bigint or (file_size=(cur->>'size')::bigint and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)))))
 order by case when sort_name='popular' then (select count(*) from public.public_resource_downloads d where d.resource_id=public_resources.id) end desc,case when sort_name='name' then file_name end asc,case when sort_name='size' then file_size end desc,created_at desc,id desc limit 51) x;
 last_row:=items->49;
 return jsonb_build_object('config',to_jsonb(cfg)||jsonb_build_object('used_bytes',used,'review_required',false),'files',case when jsonb_array_length(items)>50 then items-50 else items end,'next_cursor',case when jsonb_array_length(items)>50 then jsonb_build_object('sort',sort_name,'id',last_row->>'id','at',last_row->>'created_at','name',last_row->>'file_name','size',last_row->'file_size','downloads',last_row->'download_count')::text else null end);
 end if;
 raise exception 'INVALID_REQUEST';
end $$;
revoke all on function public.public_resources_service_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.public_resources_service_v1(uuid,text,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
