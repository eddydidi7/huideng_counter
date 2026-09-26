begin;
create table if not exists public.public_resource_settings(
 id boolean primary key default true check(id), version integer not null default 1,
 enabled boolean not null default true,upload_enabled boolean not null default true,download_enabled boolean not null default true,
 total_bytes bigint not null default 1073741824 check(total_bytes between 1048576 and 1099511627776),
 max_file_bytes bigint not null default 20971520 check(max_file_bytes between 1 and 52428800),
 daily_upload_bytes bigint not null default 104857600 check(daily_upload_bytes>=0),daily_download_bytes bigint not null default 524288000 check(daily_download_bytes>=0),
 categories jsonb not null default '["经论","讲义","音频","视频","图片","其他"]' check(jsonb_typeof(categories)='array'),notice text not null default '公共资料库：上传完成后直接公开，请勿上传私人资料。');
insert into public.public_resource_settings(id) values(true) on conflict do nothing;
create table if not exists public.public_resources(
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),upload_id uuid not null,
 file_name text not null check(length(file_name) between 1 and 200),file_size bigint not null check(file_size between 1 and 52428800),checksum text not null check(checksum ~ '^[a-f0-9]{64}$'),
 category text not null default '',description text not null default '' check(length(description)<=2000),author_name text not null default '学友',mime_type text not null default 'application/octet-stream',
 object_key text not null unique, status text not null default 'uploading' check(status in ('uploading','published','deleting','deleted')),
 verified boolean not null default false,lease_id uuid,lease_until timestamptz,
 created_at timestamptz not null default now(),published_at timestamptz,deleted_at timestamptz,unique(user_id,upload_id));
create index if not exists public_resources_feed on public.public_resources(created_at desc,id desc) where status='published';
create table if not exists public.public_resource_downloads(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),resource_id uuid not null references public.public_resources(id),bytes bigint not null,created_at timestamptz not null default now());
create index if not exists public_resource_downloads_usage on public.public_resource_downloads(user_id,created_at);
alter table public.public_resource_settings enable row level security;
alter table public.public_resources enable row level security;
alter table public.public_resource_downloads enable row level security;
revoke all on public.public_resource_settings,public.public_resources,public.public_resource_downloads from public,anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit) values('public-resources','public-resources',false,52428800) on conflict(id) do nothing;
do $$ begin if exists(select 1 from storage.buckets where id='public-resources' and public) then raise exception 'PUBLIC_RESOURCE_BUCKET_MUST_BE_PRIVATE';end if;end $$;
-- No client INSERT/UPDATE/DELETE or SELECT storage policies: only the verified Edge service accesses this private bucket.
create or replace function public.public_resources_service_v1(p_actor uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare cfg public.public_resource_settings; f public.public_resources; used bigint; amount bigint; n integer; result jsonb; items jsonb; role_name text; target uuid; next_id uuid; off integer; sort_name text; cur jsonb; last_row jsonb;
begin
 if p_actor is null or not exists(select 1 from auth.users where id=p_actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'LOGIN_REQUIRED';end if;
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'INVALID_REQUEST';end if;
 -- One settings lock serializes reservations with toggles and quota changes.
 select * into cfg from public.public_resource_settings where id for update;
 if not found then raise exception 'RESOURCE_NOT_CONFIGURED';end if;
 select coalesce(sum(file_size),0) into used from public.public_resources where status<>'deleted';
 if p_action like 'admin.%' then
 select role into role_name from admin_private.members where user_id=p_actor and enabled;
 if role_name is null or role_name not in ('super_admin','admin') then raise exception 'FORBIDDEN';end if;
 if p_action='admin.settings' then
 if role_name<>'super_admin' then raise exception 'FORBIDDEN';end if;
 if (p_data->>'version')::integer is distinct from cfg.version then raise exception 'CONFIG_CONFLICT';end if;
 if jsonb_typeof(p_data->'enabled') is distinct from 'boolean' or jsonb_typeof(p_data->'upload_enabled') is distinct from 'boolean' or jsonb_typeof(p_data->'download_enabled') is distinct from 'boolean' then raise exception 'INVALID_REQUEST';end if;
 update public.public_resource_settings set enabled=(p_data->>'enabled')::boolean,upload_enabled=(p_data->>'upload_enabled')::boolean,download_enabled=(p_data->>'download_enabled')::boolean,total_bytes=(p_data->>'total_bytes')::bigint,max_file_bytes=(p_data->>'max_file_bytes')::bigint,daily_upload_bytes=(p_data->>'daily_upload_bytes')::bigint,daily_download_bytes=(p_data->>'daily_download_bytes')::bigint,categories=p_data->'categories',notice=left(coalesce(p_data->>'notice',''),2000),version=version+1 where id;
 insert into admin_private.audit_logs(actor,action,target,before_data,after_data) values(p_actor,'resources.settings','global',to_jsonb(cfg),p_data);
 return '{"saved":true}';
 elsif p_action='admin.delete' then
 update public.public_resources set status='deleting',deleted_at=coalesce(deleted_at,now()) where id=(p_data->>'id')::uuid and status not in ('deleting','deleted');
 insert into admin_private.audit_logs(actor,action,target,after_data) values(p_actor,'resources.delete',p_data->>'id',p_data);
 return '{"saved":true}';
 elsif p_action='admin.cleanup' then
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from(select id,object_key from public.public_resources where status='deleting' and (lease_until is null or lease_until<now()) limit 10) x;
 return jsonb_build_object('files',items);
 elsif p_action='admin.purged' then
 update public.public_resources set status='deleted' where id=(p_data->>'id')::uuid and status='deleting' and (lease_until is null or lease_until<now());return '{"saved":true}';
 elsif p_action='admin.list' then
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select id,file_name,file_size,category,description,author_name,status,created_at from public.public_resources where status<>'deleted' and (coalesce(p_data->>'search','')='' or strpos(lower(file_name),lower(left(p_data->>'search',150)))>0) order by created_at desc,id desc limit 51 offset greatest(0,least(coalesce((p_data->>'offset')::integer,0),100000))) x;
 return jsonb_build_object('config',to_jsonb(cfg)||jsonb_build_object('used_bytes',used,'review_required',false),'files',items);
 else raise exception 'INVALID_REQUEST';end if;
 end if;
 if exists(select 1 from public.forum_restrictions where user_id=p_actor and blocked) then raise exception 'LOGIN_REQUIRED';end if;
 if p_action='list' then
 cur:=nullif(p_data->>'cursor','')::jsonb;sort_name:=coalesce(p_data->>'sort','time');
 if sort_name not in ('time','name','size') or (cur is not null and (cur->>'sort' is distinct from sort_name or cur->>'id' is null or cur->>'at' is null)) then raise exception 'INVALID_REQUEST';end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select id,file_name,file_size,checksum,category,description,author_name,status,created_at from public.public_resources where cfg.enabled and (status='published' or (p_data->>'scope'='mine' and user_id=p_actor and status='uploading')) and (coalesce(p_data->>'scope','public')<>'mine' or user_id=p_actor) and (coalesce(p_data->>'category','')='' or category=p_data->>'category') and (coalesce(p_data->>'search','')='' or strpos(lower(file_name||' '||description),lower(left(p_data->>'search',150)))>0)
 and (cur is null or (sort_name='time' and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)) or (sort_name='name' and (file_name>cur->>'name' or (file_name=cur->>'name' and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)))) or (sort_name='size' and (file_size<(cur->>'size')::bigint or (file_size=(cur->>'size')::bigint and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)))))
 order by case when sort_name='name' then file_name end asc,case when sort_name='size' then file_size end desc,created_at desc,id desc limit 51) x;
 last_row:=items->49;
 return jsonb_build_object('config',to_jsonb(cfg)||jsonb_build_object('used_bytes',used,'review_required',false),'files',case when jsonb_array_length(items)>50 then items-50 else items end,'next_cursor',case when jsonb_array_length(items)>50 then jsonb_build_object('sort',sort_name,'id',last_row->>'id','at',last_row->>'created_at','name',last_row->>'file_name','size',last_row->'file_size')::text else null end);
 end if;
 if not cfg.enabled then raise exception 'RESOURCE_DISABLED';end if;
 if p_action='begin' then
 if not cfg.upload_enabled then raise exception 'UPLOAD_DISABLED';end if;
 select * into f from public.public_resources where user_id=p_actor and upload_id=(p_data->>'upload_id')::uuid;
 if found then
 if f.file_name is distinct from p_data->>'file_name' or f.file_size is distinct from (p_data->>'file_size')::bigint or f.checksum is distinct from p_data->>'checksum' or f.category is distinct from coalesce(p_data->>'category','') or f.description is distinct from coalesce(p_data->>'description','') then raise exception 'UPLOAD_CONFLICT';end if;
 if f.status in ('deleting','deleted') then raise exception 'FILE_UNAVAILABLE';end if;
 return jsonb_build_object('file',to_jsonb(f));end if;
 amount:=(p_data->>'file_size')::bigint;
 if amount is null or amount<1 or amount>cfg.max_file_bytes then raise exception 'FILE_TOO_LARGE';end if;
 if coalesce(p_data->>'file_name','')='' or length(p_data->>'file_name')>200 or (p_data->>'file_name') ~ '[/\\\x00-\x1f]' or coalesce(p_data->>'checksum','') !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_REQUEST';end if;
 if used+amount>cfg.total_bytes then raise exception 'RESOURCE_QUOTA_EXCEEDED';end if;
 select coalesce(sum(file_size),0),count(*) into used,n from public.public_resources where user_id=p_actor and created_at>=date_trunc('day',now());
 if used+amount>cfg.daily_upload_bytes then raise exception 'RESOURCE_QUOTA_EXCEEDED';end if;
 if n>=100 or (select count(*) from public.public_resources where user_id=p_actor and status='uploading')>=10 then raise exception 'RESOURCE_RATE_LIMIT';end if;
 target:=gen_random_uuid();
 insert into public.public_resources(id,user_id,upload_id,file_name,file_size,checksum,category,description,author_name,mime_type,object_key)
 values(target,p_actor,(p_data->>'upload_id')::uuid,p_data->>'file_name',amount,p_data->>'checksum',left(coalesce(p_data->>'category',''),80),coalesce(p_data->>'description',''),coalesce((select nickname from public.chat_profiles where user_id=p_actor),'学友'),case when lower(p_data->>'file_name') like '%.apk' then 'application/vnd.android.package-archive' else 'application/octet-stream' end,'resources/'||p_actor::text||'/'||target::text||'/'||(p_data->>'file_name')) returning * into f;
 return jsonb_build_object('file',to_jsonb(f));
 end if;
 if p_action='download' then
 if not cfg.download_enabled then raise exception 'DOWNLOAD_DISABLED';end if;
 select * into f from public.public_resources where id=(p_data->>'id')::uuid and status='published';
 if not found then raise exception 'FILE_UNAVAILABLE';end if;
 select coalesce(sum(bytes),0) into used from public.public_resource_downloads where user_id=p_actor and created_at>=date_trunc('day',now());
 if used+f.file_size>cfg.daily_download_bytes then raise exception 'DOWNLOAD_LIMIT';end if;
 insert into public.public_resource_downloads(user_id,resource_id,bytes) values(p_actor,f.id,f.file_size);
 return jsonb_build_object('file',to_jsonb(f));
 end if;
 if not cfg.upload_enabled then raise exception 'UPLOAD_DISABLED';end if;
 select * into f from public.public_resources where user_id=p_actor and upload_id=(p_data->>'upload_id')::uuid for update;
 if not found or f.status in ('deleting','deleted') then raise exception 'FILE_UNAVAILABLE';end if;
 if p_action='upload.start' then
 if f.status='published' or f.verified then return jsonb_build_object('file',to_jsonb(f));end if;
 if f.lease_until>now() then raise exception 'UPLOAD_BUSY';end if;
 update public.public_resources set lease_id=(p_data->>'lease_id')::uuid,lease_until=now()+interval '5 minutes' where id=f.id returning * into f;
 elsif p_action='upload.verified' then
 if f.lease_id is distinct from (p_data->>'lease_id')::uuid or f.lease_until<now() or f.checksum is distinct from p_data->>'checksum' or f.file_size is distinct from (p_data->>'size')::bigint then raise exception 'VERIFY_FAILED';end if;
 update public.public_resources set verified=true,lease_id=null,lease_until=null where id=f.id returning * into f;
 elsif p_action='upload.release' then
 update public.public_resources set lease_id=null,lease_until=null where id=f.id and lease_id=(p_data->>'lease_id')::uuid returning * into f;
 elsif p_action='complete' then
 if not f.verified then raise exception 'UPLOAD_NOT_COMPLETE';end if;
 update public.public_resources set status='published',published_at=coalesce(published_at,now()) where id=f.id returning * into f;
 else raise exception 'INVALID_REQUEST';end if;
 return jsonb_build_object('file',to_jsonb(f));
end $$;
revoke all on function public.public_resources_service_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.public_resources_service_v1(uuid,text,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
