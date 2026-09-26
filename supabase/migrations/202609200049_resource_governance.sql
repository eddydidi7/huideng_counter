begin;
alter table public.public_resources add column if not exists moderated boolean not null default false;
-- No deletion of user files. Aggregate only file metadata; private text is never selected.
create table if not exists public.resource_user_limits(
 user_id uuid primary key references auth.users(id),version integer not null default 1,
 quota_bytes bigint not null default 1073741824 check(quota_bytes>=0),
 daily_bytes bigint not null default 1073741824 check(daily_bytes>=0),monthly_bytes bigint not null default 10737418240 check(monthly_bytes>=0),
 daily_files integer not null default 100 check(daily_files>=0),monthly_files integer not null default 2000 check(monthly_files>=0),
 paused boolean not null default false,paused_until timestamptz,
 blocked_types text[] not null default '{}',types_until timestamptz,
 updated_at timestamptz not null default now());
create table if not exists public.resource_user_warnings(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),actor uuid not null,message text not null check(length(message) between 1 and 1000),created_at timestamptz not null default now());
create table if not exists admin_private.resource_files(
 key text primary key,user_id uuid not null,source text not null,name text not null,kind text not null,bytes bigint not null check(bytes>=0),pending boolean not null default false,removed boolean not null default false,created_at timestamptz not null default now(),uploaded_at timestamptz);
create index if not exists resource_files_user on admin_private.resource_files(user_id) where not removed;
create table if not exists admin_private.resource_upload_events(id bigint generated always as identity primary key,user_id uuid not null,key text not null,bytes bigint not null,created_at timestamptz not null default now(),historical boolean not null default false);
create index if not exists resource_events_user_time on admin_private.resource_upload_events(user_id,created_at);
alter table admin_private.resource_files enable row level security;
alter table admin_private.resource_upload_events enable row level security;
alter table public.resource_user_limits enable row level security;
alter table public.resource_user_warnings enable row level security;
revoke all on public.resource_user_limits,public.resource_user_warnings from public,anon,authenticated;
revoke all on admin_private.resource_files,admin_private.resource_upload_events from public,anon,authenticated;
create or replace function admin_private.resource_kind(n text,m text default '') returns text language sql immutable set search_path='' as $$
 select case when lower(n) like '%.apk' or m='application/vnd.android.package-archive' then 'apk'
 when m like 'image/%' or lower(n) ~ '\.(jpg|jpeg|png|gif|webp|heic|bmp)$' then 'image'
 when m like 'video/%' or lower(n) ~ '\.(mp4|mkv|mov|webm|avi)$' then 'video'
 when m like 'audio/%' or lower(n) ~ '\.(mp3|m4a|ogg|aac|wav|flac)$' then 'audio'
 when m in ('application/pdf','text/plain','text/markdown','application/epub+zip') or m like 'application/vnd.openxmlformats-officedocument.%' or m='application/msword' or lower(n) ~ '\.(pdf|docx?|xlsx?|pptx?|txt|md|epub)$' then 'document' else 'file' end
$$;
create or replace function admin_private.resource_owner(b text,n text) returns uuid language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v text;u uuid;
begin
 if b='public-resources' then select user_id into u from public.public_resources where object_key=n;return u;
 elsif b in ('chat-files','chat-voice','group-files') then v:=split_part(n,'/',2);
 elsif b in ('counter-images','chat-avatars','forum-files') then v:=split_part(n,'/',1);
 else return null;end if;
 if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and exists(select 1 from auth.users where id=v::uuid) then return v::uuid;end if;
 return null;
end $$;
create or replace function admin_private.resource_assert(u uuid,k text,n text,typ text,amount bigint,old_bytes bigint default 0,old_pending boolean default false) returns void language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare lim public.resource_user_limits;used bigint;d bigint;m bigint;dc bigint;mc bigint;day_start timestamptz:=date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai';month_start timestamptz:=date_trunc('month',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai';
begin
 perform pg_advisory_xact_lock(hashtextextended(u::text,49));
 if not exists(select 1 from auth.users where id=u and (banned_until is null or banned_until<now())) then raise exception 'RESOURCE_ACCOUNT_BANNED';end if;
 insert into public.resource_user_limits(user_id) values(u) on conflict do nothing;
 select * into lim from public.resource_user_limits where user_id=u;
 if lim.paused and (lim.paused_until is null or lim.paused_until>now()) then raise exception 'RESOURCE_UPLOAD_PAUSED';end if;
 if (typ=any(lim.blocked_types) or ('file'=any(lim.blocked_types) and typ<>'image')) and (lim.types_until is null or lim.types_until>now()) then raise exception 'RESOURCE_TYPE_BLOCKED';end if;
 select coalesce(sum(bytes),0) into used from admin_private.resource_files where user_id=u and not removed and key<>k;
 if used+amount>lim.quota_bytes then raise exception 'RESOURCE_USER_QUOTA';end if;
 select coalesce(sum(bytes) filter(where created_at>=day_start),0),coalesce(sum(bytes),0),count(*) filter(where created_at>=day_start),count(*) into d,m,dc,mc from admin_private.resource_upload_events where user_id=u and created_at>=month_start;
 select d+coalesce(sum(bytes) filter(where created_at>=day_start),0),m+coalesce(sum(bytes),0),dc+count(*) filter(where created_at>=day_start),mc+count(*) into d,m,dc,mc from admin_private.resource_files where user_id=u and pending and not removed and key<>k and created_at>=month_start;
 if d+amount>lim.daily_bytes or dc+1>lim.daily_files then raise exception 'RESOURCE_DAILY_LIMIT';end if;
 if m+amount>lim.monthly_bytes or mc+1>lim.monthly_files then raise exception 'RESOURCE_MONTHLY_LIMIT';end if;
end $$;
create or replace function admin_private.resource_record(k text,u uuid,src text,n text,typ text,amount bigint,is_pending boolean,is_removed boolean,stamp timestamptz,checking boolean default true,force_upload boolean default false) returns void language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare prev admin_private.resource_files;changed boolean;
begin
 if u is null then return;end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,49));
 select * into prev from admin_private.resource_files where key=k;
 if found and prev.user_id<>u then raise exception 'RESOURCE_OWNER_IMMUTABLE';end if;
 changed:=force_upload or prev.key is null or prev.removed or prev.bytes<>amount or (prev.pending and not is_pending);
 if checking and not is_removed and changed then perform admin_private.resource_assert(u,k,n,typ,amount,coalesce(prev.bytes,0),coalesce(prev.pending,false));end if;
 insert into admin_private.resource_files(key,user_id,source,name,kind,bytes,pending,removed,created_at,uploaded_at) values(k,u,src,n,typ,amount,is_pending,is_removed,stamp,case when is_pending then null when checking then now() else stamp end)
 on conflict(key) do update set name=excluded.name,kind=excluded.kind,bytes=excluded.bytes,pending=excluded.pending,removed=excluded.removed,uploaded_at=coalesce(admin_private.resource_files.uploaded_at,excluded.uploaded_at);
 if changed and not is_pending and not is_removed then insert into admin_private.resource_upload_events(user_id,key,bytes,created_at,historical) values(u,k,amount,case when checking then now() else stamp end,not checking);end if;
end $$;
-- Storage writes still go through its official API. This trigger only reads NEW metadata and writes our own accounting tables.
create or replace function admin_private.resource_storage_event() returns trigger language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare r jsonb;u uuid;b text;n text;s bigint;typ text;reserved public.public_resources;
begin
 r:=case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end;b:=r->>'bucket_id';n:=r->>'name';u:=admin_private.resource_owner(b,n);
 if u is null then return null;end if;
 if TG_OP='UPDATE' and (old.name<>new.name or old.bucket_id<>new.bucket_id) then raise exception 'RESOURCE_PATH_IMMUTABLE';end if;
 s:=coalesce((r->'metadata'->>'size')::bigint,0);
 if TG_OP='DELETE' then update admin_private.resource_files set removed=true where key='supabase/'||b||'/'||n;return null;end if;
 -- Storage may create an empty placeholder before setting final metadata. Do not charge it as a file.
 if r->'metadata'->>'size' is null or s=0 then return null;end if;
 typ:=admin_private.resource_kind(n,coalesce(r->'metadata'->>'mimetype',''));
 if b in ('counter-images','chat-avatars') then typ:='image';elsif b='chat-voice' then typ:='audio';end if;
 if b='public-resources' then
 select * into reserved from public.public_resources where object_key=n;
 if reserved.status in ('deleting','deleted') or reserved.file_size<>s then raise exception 'RESOURCE_UPLOAD_PAUSED';end if;
 if not exists(select 1 from public.public_resource_settings where id and enabled and upload_enabled) then raise exception 'RESOURCE_UPLOAD_PAUSED';end if;
 n:=reserved.file_name;typ:=admin_private.resource_kind(n,reserved.mime_type);
 else n:=regexp_replace(n,'^.*/','');end if;
 perform admin_private.resource_record('supabase/'||b||'/'||(r->>'name'),u,b,n,typ,s,false,false,coalesce((r->>'created_at')::timestamptz,now()),true,case when TG_OP='UPDATE' then (old.metadata->'size' is distinct from new.metadata->'size' or old.metadata->'eTag' is distinct from new.metadata->'eTag' or to_jsonb(old)->'version' is distinct from to_jsonb(new)->'version') and old.metadata->>'size' is not null else false end);
 return null;
end $$;
create or replace function admin_private.resource_reservation_event() returns trigger language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare j jsonb:=to_jsonb(new);k text;src text;pend boolean;removed boolean;
begin
 if TG_TABLE_NAME='public_resources' then k:='supabase/public-resources/'||new.object_key;src:='public-resources';pend:=not new.verified;removed:=new.status='deleted';
 -- Once storage has committed, status changes must not turn the same object back into a reservation.
 if exists(select 1 from admin_private.resource_files where key=k and not pending) then pend:=false;end if;
 else k:='oss/'||new.bucket_name||'/'||new.object_key;src:='personal-drive';pend:=new.upload_state<>'ready';removed:=false;end if;
 perform admin_private.resource_record(k,(j->>'user_id')::uuid,src,j->>'file_name',admin_private.resource_kind(j->>'file_name',j->>'mime_type'),(j->>'file_size')::bigint,pend,removed,(j->>'created_at')::timestamptz);
 return null;
end $$;
-- Bootstrap present files only. Deleted-before-migration upload history cannot be reconstructed.
do $$ declare r record;u uuid; begin
 for r in select * from storage.objects loop
 u:=admin_private.resource_owner(r.bucket_id,r.name);
 if u is not null and r.metadata->>'size' is not null then perform admin_private.resource_record('supabase/'||r.bucket_id||'/'||r.name,u,r.bucket_id,regexp_replace(r.name,'^.*/',''),case when r.bucket_id in ('counter-images','chat-avatars') then 'image' when r.bucket_id='chat-voice' then 'audio' else admin_private.resource_kind(r.name,coalesce(r.metadata->>'mimetype','')) end,(r.metadata->>'size')::bigint,false,false,r.created_at,false);end if;
 end loop;
 for r in select * from public.public_resources where status<>'deleted' loop
 if not exists(select 1 from admin_private.resource_files where key='supabase/public-resources/'||r.object_key) then perform admin_private.resource_record('supabase/public-resources/'||r.object_key,r.user_id,'public-resources',r.file_name,admin_private.resource_kind(r.file_name,r.mime_type),r.file_size,not r.verified,false,r.created_at,false);end if;
 end loop;
 for r in select * from public.user_files loop perform admin_private.resource_record('oss/'||r.bucket_name||'/'||r.object_key,r.user_id,'personal-drive',r.file_name,admin_private.resource_kind(r.file_name,r.mime_type),r.file_size,r.upload_state<>'ready',false,r.created_at,false);end loop;
end $$;
create or replace trigger resource_usage_storage after insert or update or delete on storage.objects for each row execute function admin_private.resource_storage_event();
create or replace trigger resource_usage_public after insert or update on public.public_resources for each row execute function admin_private.resource_reservation_event();
create or replace trigger resource_usage_personal after insert or update on public.user_files for each row execute function admin_private.resource_reservation_event();
create or replace function public.resource_upload_check(p_name text,p_size bigint,p_mime text default '') returns jsonb language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare u uuid:=auth.uid();
begin
 if u is null then raise exception 'RESOURCE_ACCOUNT_BANNED';end if;
 if p_size<0 or length(p_name)>500 then raise exception 'INVALID_REQUEST';end if;
 perform admin_private.resource_assert(u,'preflight',p_name,admin_private.resource_kind(p_name,p_mime),p_size);
 return jsonb_build_object('allowed',true,'warnings',(select coalesce(jsonb_agg(message),'[]') from (select message from public.resource_user_warnings where user_id=u order by created_at desc limit 5)t));
end $$;
revoke all on function public.resource_upload_check(text,bigint,text) from public,anon;
grant execute on function public.resource_upload_check(text,bigint,text) to authenticated;

create or replace view admin_private.resource_user_usage as
 select u.id user_id,coalesce(u.raw_user_meta_data->>'username',split_part(coalesce(u.email,''),'@',1),'') username,coalesce(p.nickname,'未设置昵称') nickname,
 coalesce(l.level,1) level,u.created_at registered_at,greatest(u.last_sign_in_at,(select max(seen_at) from public.chat_presence where user_id=u.id)) last_active_at,
 coalesce(q.quota_bytes,1073741824) quota_bytes,coalesce(f.used_bytes,0) used_bytes,coalesce(f.pending_bytes,0) pending_bytes,
 greatest(0,coalesce(q.quota_bytes,1073741824)-coalesce(f.used_bytes,0)-coalesce(f.pending_bytes,0)) remaining_bytes,
 case when coalesce(q.quota_bytes,1073741824)=0 then case when coalesce(f.used_bytes,0)+coalesce(f.pending_bytes,0)>0 then 100.0 else 0.0 end else round(100.0*(coalesce(f.used_bytes,0)+coalesce(f.pending_bytes,0))/coalesce(q.quota_bytes,1073741824),2) end usage_percent,
 coalesce(f.image_bytes,0) image_bytes,coalesce(f.document_bytes,0) document_bytes,coalesce(f.audio_bytes,0) audio_bytes,coalesce(f.apk_bytes,0) apk_bytes,coalesce(f.video_bytes,0) video_bytes,coalesce(f.other_bytes,0) other_bytes,coalesce(f.large_bytes,0) large_bytes,coalesce(f.drive_bytes,0) drive_bytes,
 coalesce(e.day_bytes,0) day_upload_bytes,coalesce(e.month_bytes,0) month_upload_bytes,coalesce(e.day_files,0) day_upload_files,coalesce(e.month_files,0) month_upload_files,
 null::bigint day_download_bytes,null::bigint month_download_bytes,'暂无法精确统计'::text download_status,
 coalesce(d.day_bytes,0) day_download_signed_bytes,coalesce(d.month_bytes,0) month_download_signed_bytes,
 (select count(*) from public.forum_posts where author_user_id=u.id and category_id<>'jieyuan' and deleted_at is null) redbook_posts,
 (select count(*) from public.forum_posts where author_user_id=u.id and category_id='jieyuan' and deleted_at is null) jieyuan_posts,
 (select count(*) from admin_private.resource_files where user_id=u.id and source in ('chat-files','chat-voice') and not removed and not pending) chat_attachment_files,
 (select count(*) from public.public_resources where user_id=u.id and status='published' and not moderated) public_resource_files,
 exists(select 1 from public.resource_user_warnings where user_id=u.id) warned,
 coalesce(q.paused and (q.paused_until is null or q.paused_until>now()),false) or coalesce(cardinality(q.blocked_types)>0 and (q.types_until is null or q.types_until>now()),false) restricted,
 coalesce(u.banned_until>now(),false) banned,u.banned_until
 from auth.users u left join public.chat_profiles p on p.user_id=u.id left join public.app_user_levels l on l.user_id=u.id left join public.resource_user_limits q on q.user_id=u.id
 left join lateral(select sum(bytes) filter(where not pending) used_bytes,sum(bytes) filter(where pending) pending_bytes,
 sum(bytes) filter(where kind='image' and not pending) image_bytes,sum(bytes) filter(where kind='document' and not pending) document_bytes,sum(bytes) filter(where kind='audio' and not pending) audio_bytes,sum(bytes) filter(where kind='apk' and not pending) apk_bytes,sum(bytes) filter(where kind='video' and not pending) video_bytes,sum(bytes) filter(where kind='file' and not pending) other_bytes,
 sum(bytes) filter(where bytes>=52428800 and not pending) large_bytes,sum(bytes) filter(where source in ('personal-drive','public-resources') and not pending) drive_bytes from admin_private.resource_files where user_id=u.id and not removed)f on true
 left join lateral(select sum(bytes) filter(where created_at>=(date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) day_bytes,sum(bytes) month_bytes,count(*) filter(where created_at>=(date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) day_files,count(*) month_files from admin_private.resource_upload_events where user_id=u.id and created_at>=(date_trunc('month',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai'))e on true
 left join lateral(select sum(bytes) filter(where created_at>=(date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) day_bytes,sum(bytes) month_bytes from public.public_resource_downloads where user_id=u.id and created_at>=(date_trunc('month',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai'))d on true;
revoke all on admin_private.resource_user_usage from public,anon,authenticated;
create or replace function public.huideng_admin_usage(actor uuid,action text,payload jsonb,request_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare role_name text;target uuid;result jsonb;items jsonb;lim public.resource_user_limits;prev admin_private.requests;sorting text;kind text;until_time timestamptz;
begin
 select role into role_name from admin_private.members where user_id=actor and enabled;
 if role_name is null or role_name not in ('admin','super_admin') or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until<now())) then raise exception 'FORBIDDEN';end if;
 if payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>16384 then raise exception 'INVALID_REQUEST';end if;
 if action='usage.list' then
 sorting:=coalesce(payload->>'sort','storage');kind:=coalesce(payload->>'kind','');
 if sorting='download' then raise exception 'DOWNLOAD_USAGE_UNAVAILABLE';end if;
 if sorting not in ('storage','upload','apk','video','large') or kind not in ('','apk','video','large') then raise exception 'INVALID_REQUEST';end if;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') into items from(select * from admin_private.resource_user_usage
 where (coalesce(payload->>'search','')='' or strpos(lower(username||' '||nickname||' '||user_id::text),lower(payload->>'search'))>0)
 and (coalesce(payload->>'level','')='' or level=(payload->>'level')::integer)
 and usage_percent>=coalesce((payload->>'threshold')::numeric,0)
 and (kind='' or (kind='apk' and apk_bytes>0) or (kind='video' and video_bytes>0) or (kind='large' and large_bytes>0))
 and (coalesce(payload->>'status','')='' or (payload->>'status'='warned' and warned) or (payload->>'status'='restricted' and restricted) or (payload->>'status'='banned' and banned))
 order by case sorting when 'storage' then used_bytes+pending_bytes when 'upload' then month_upload_bytes when 'apk' then apk_bytes when 'video' then video_bytes else large_bytes end desc,user_id
 limit 51 offset greatest(0,least(coalesce((payload->>'offset')::integer,0),100000)))t;
 return jsonb_build_object('items',items,'download_status','暂无法精确统计','unattributed_storage_files',(select count(*) from storage.objects where bucket_id in ('counter-images','chat-avatars','forum-files','chat-files','chat-voice','group-files','public-resources') and admin_private.resource_owner(bucket_id,name) is null),'history_note','上传历史：升级前仅能回溯仍存在的文件，升级后记录完整上传事件；红书和论坛共用帖子表，勿重复相加。');
 end if;
 target:=(payload->>'user_id')::uuid;
 if not exists(select 1 from auth.users where id=target) then raise exception 'USER_NOT_FOUND';end if;
 if action='usage.detail' then
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') into items from(select key,name,case when source='forum-files' and exists(select 1 from public.forum_attachments a join public.forum_posts p on p.id=a.post_id where 'supabase/forum-files/'||a.path=rf.key and p.category_id='jieyuan') then 'jieyuan' else source end source,rf.kind,bytes,pending,coalesce(uploaded_at,created_at) created_at from admin_private.resource_files rf where user_id=target and not removed order by bytes desc,key limit 101 offset greatest(0,least(coalesce((payload->>'offset')::integer,0),100000)))t;
 select * into lim from public.resource_user_limits where user_id=target;
 if not found then insert into public.resource_user_limits(user_id) values(target) returning * into lim;end if;
 return jsonb_build_object('user',(select to_jsonb(v) from admin_private.resource_user_usage v where user_id=target),'limits',to_jsonb(lim),'files',items,'warnings',(select coalesce(jsonb_agg(to_jsonb(w)),'[]') from(select id,message,created_at from public.resource_user_warnings where user_id=target order by created_at desc limit 30)w),
 'posts',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from(select id,title,category_id,visibility from public.forum_posts where author_user_id=target and access_level='public' and deleted_at is null order by created_at desc limit 101 offset greatest(0,coalesce((payload->>'offset')::integer,0)))t),
 'resources',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from(select id,file_name from public.public_resources where user_id=target and status='published' and not moderated order by created_at desc limit 101 offset greatest(0,coalesce((payload->>'offset')::integer,0)))t));
 end if;
 if exists(select 1 from admin_private.members where user_id=target and enabled) and role_name<>'super_admin' then raise exception 'FORBIDDEN';end if;
 if target=actor and action='usage.ban' then raise exception 'CANNOT_BAN_SELF';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,490));
 select * into prev from admin_private.requests r where r.actor=huideng_admin_usage.actor and r.request_id=huideng_admin_usage.request_id;
 if found then if prev.action<>action or prev.payload<>payload then raise exception 'CONFIG_CONFLICT';end if;return prev.result;end if;
 perform pg_advisory_xact_lock(hashtextextended(target::text,49));
 if action='usage.save' then
 select * into lim from public.resource_user_limits where user_id=target for update;
 if lim.version is distinct from (payload->>'version')::integer then raise exception 'CONFIG_CONFLICT';end if;
 if coalesce((payload->>'level')::integer,0) not between 1 and 5 or jsonb_typeof(payload->'paused') is distinct from 'boolean' or jsonb_typeof(payload->'blocked_types') is distinct from 'array' then raise exception 'INVALID_REQUEST';end if;
 if exists(select 1 from jsonb_array_elements_text(payload->'blocked_types') t where t not in ('image','file','apk','video','audio','document')) then raise exception 'INVALID_REQUEST';end if;
 update public.resource_user_limits set quota_bytes=(payload->>'quota_bytes')::bigint,daily_bytes=(payload->>'daily_bytes')::bigint,monthly_bytes=(payload->>'monthly_bytes')::bigint,daily_files=(payload->>'daily_files')::integer,monthly_files=(payload->>'monthly_files')::integer,paused=(payload->>'paused')::boolean,paused_until=nullif(payload->>'paused_until','')::timestamptz,blocked_types=array(select jsonb_array_elements_text(payload->'blocked_types')),types_until=nullif(payload->>'types_until','')::timestamptz,version=version+1,updated_at=now() where user_id=target;
 insert into public.app_user_levels(user_id,level) values(target,(payload->>'level')::integer) on conflict(user_id) do update set level=excluded.level;
 elsif action='usage.warn' then insert into public.resource_user_warnings(user_id,actor,message) values(target,actor,payload->>'message');
 elsif action='usage.ban' then
 until_time:=coalesce(nullif(payload->>'until','')::timestamptz,now()+interval '100 years');
 if until_time<=now() then raise exception 'INVALID_REQUEST';end if;
 update auth.users set banned_until=until_time where id=target;
 insert into public.forum_restrictions(user_id,muted,blocked) values(target,true,true) on conflict(user_id) do update set muted=true,blocked=true,updated_at=now();
 elsif action='usage.hide' then
 if payload->>'module'='forum' then
 update public.forum_posts set visibility='hidden',is_locked=true,updated_at=now() where id=(payload->>'id')::uuid and author_user_id=target and access_level='public';
 elsif payload->>'module'='public-resources' then
 update public.public_resources set moderated=true where id=(payload->>'id')::uuid and user_id=target;
 else raise exception 'INVALID_REQUEST';end if;
 else raise exception 'INVALID_REQUEST';end if;
 result:='{"saved":true}';
 insert into admin_private.audit_logs(actor,action,target,before_data,after_data) values(actor,action,target::text,to_jsonb(lim),payload);
 insert into admin_private.requests(actor,request_id,action,payload,result) values(actor,request_id,action,payload,result);
 return result;
end $$;
revoke all on function public.huideng_admin_usage(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.huideng_admin_usage(uuid,text,jsonb,uuid) to service_role;
-- Do not allow a hidden resource to be made visible by retrying an upload.
alter table public.public_resources add column if not exists moderated boolean not null default false;
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
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from(select id,object_key from public.public_resources where status='deleting' and (lease_until is null or lease_until<now()) and (upload_token_until is null or upload_token_until<now()) limit 10) x;
 return jsonb_build_object('files',items);
 elsif p_action='admin.purged' then
 update public.public_resources set status='deleted' where id=(p_data->>'id')::uuid and status='deleting' and (lease_until is null or lease_until<now()) and (upload_token_until is null or upload_token_until<now());return '{"saved":true}';
 elsif p_action='admin.list' then
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select id,file_name,file_size,category,description,author_name,status,created_at from public.public_resources where status<>'deleted' and (coalesce(p_data->>'search','')='' or strpos(lower(file_name),lower(left(p_data->>'search',150)))>0) order by created_at desc,id desc limit 51 offset greatest(0,least(coalesce((p_data->>'offset')::integer,0),100000))) x;
 return jsonb_build_object('config',to_jsonb(cfg)||jsonb_build_object('used_bytes',used,'review_required',false),'files',items);
 else raise exception 'INVALID_REQUEST';end if;
 end if;
 if exists(select 1 from public.forum_restrictions where user_id=p_actor and blocked) then raise exception 'LOGIN_REQUIRED';end if;
 if p_action='list' then
 cur:=nullif(p_data->>'cursor','')::jsonb;sort_name:=coalesce(p_data->>'sort','time');
 if sort_name not in ('time','name','size') or (cur is not null and (cur->>'sort' is distinct from sort_name or cur->>'id' is null or cur->>'at' is null)) then raise exception 'INVALID_REQUEST';end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select id,file_name,file_size,checksum,category,description,author_name,status,created_at from public.public_resources where cfg.enabled and not moderated and (status='published' or (p_data->>'scope'='mine' and user_id=p_actor and status='uploading')) and (coalesce(p_data->>'scope','public')<>'mine' or user_id=p_actor) and (coalesce(p_data->>'category','')='' or category=p_data->>'category') and (coalesce(p_data->>'search','')='' or strpos(lower(file_name||' '||description),lower(left(p_data->>'search',150)))>0)
 and (cur is null or (sort_name='time' and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)) or (sort_name='name' and (file_name>cur->>'name' or (file_name=cur->>'name' and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)))) or (sort_name='size' and (file_size<(cur->>'size')::bigint or (file_size=(cur->>'size')::bigint and (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)))))
 order by case when sort_name='name' then file_name end asc,case when sort_name='size' then file_size end desc,created_at desc,id desc limit 51) x;
 last_row:=items->49;
 return jsonb_build_object('config',to_jsonb(cfg)||jsonb_build_object('used_bytes',used,'review_required',false),'files',case when jsonb_array_length(items)>50 then items-50 else items end,'next_cursor',case when jsonb_array_length(items)>50 then jsonb_build_object('sort',sort_name,'id',last_row->>'id','at',last_row->>'created_at','name',last_row->>'file_name','size',last_row->'file_size')::text else null end);
 end if;
 if p_action not in ('list','download') then
 if exists(select 1 from public.resource_user_limits where user_id=p_actor and ((paused and (paused_until is null or paused_until>now())) or (cardinality(blocked_types)>0 and (types_until is null or types_until>now()) and (admin_private.resource_kind(coalesce(p_data->>'file_name',(select file_name from public.public_resources where user_id=p_actor and upload_id=(p_data->>'upload_id')::uuid)), '')=any(blocked_types) or ('file'=any(blocked_types) and admin_private.resource_kind(coalesce(p_data->>'file_name',(select file_name from public.public_resources where user_id=p_actor and upload_id=(p_data->>'upload_id')::uuid)), '')<>'image'))))) then raise exception 'RESOURCE_UPLOAD_PAUSED';end if;
 if exists(select 1 from public.public_resources where user_id=p_actor and upload_id=(p_data->>'upload_id')::uuid and moderated) then raise exception 'FILE_UNAVAILABLE';end if;
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
 select * into f from public.public_resources where id=(p_data->>'id')::uuid and status='published' and not moderated;
 if not found then raise exception 'FILE_UNAVAILABLE';end if;
 select coalesce(sum(bytes),0) into used from public.public_resource_downloads where user_id=p_actor and created_at>=date_trunc('day',now());
 if used+f.file_size>cfg.daily_download_bytes then raise exception 'DOWNLOAD_LIMIT';end if;
 insert into public.public_resource_downloads(user_id,resource_id,bytes) values(p_actor,f.id,f.file_size);
 return jsonb_build_object('file',to_jsonb(f));
 end if;
 if not cfg.upload_enabled then raise exception 'UPLOAD_DISABLED';end if;
 select * into f from public.public_resources where user_id=p_actor and upload_id=(p_data->>'upload_id')::uuid for update;
 if not found or f.status in ('deleting','deleted') then raise exception 'FILE_UNAVAILABLE';end if;
 if p_action='upload.authorize' then
 if f.status='published' or f.verified then return jsonb_build_object('file',to_jsonb(f));end if;
 -- Signed tokens last two hours; a TUS session created near expiry may last another 24 hours.
 update public.public_resources set upload_token_until=now()+interval '26 hours' where id=f.id returning * into f;
 elsif p_action='upload.start' then
 if f.status='published' or f.verified then return jsonb_build_object('file',to_jsonb(f));end if;
 if f.lease_until>now() then raise exception 'UPLOAD_BUSY';end if;
 update public.public_resources set lease_id=(p_data->>'lease_id')::uuid,lease_until=now()+interval '5 minutes' where id=f.id returning * into f;
 elsif p_action='upload.verify_step' then
 if f.lease_id is distinct from (p_data->>'lease_id')::uuid or f.lease_until<now() or f.verify_offset is distinct from (p_data->>'expected_offset')::bigint or (p_data->>'offset')::bigint is distinct from least(f.verify_offset+8388608,f.file_size) then raise exception 'VERIFY_FAILED';end if;
 if (p_data->>'offset')::bigint=f.file_size then
 if p_data->>'checksum' is distinct from f.checksum then raise exception 'VERIFY_FAILED';end if;
 update public.public_resources set verified=true,verify_offset=file_size,verify_state=null,lease_id=null,lease_until=null where id=f.id returning * into f;
 else
 if jsonb_typeof(p_data->'state') is distinct from 'array' or jsonb_array_length(p_data->'state')<>8 then raise exception 'VERIFY_FAILED';end if;
 update public.public_resources set verify_offset=(p_data->>'offset')::bigint,verify_state=p_data->'state',lease_id=null,lease_until=null where id=f.id returning * into f;
 end if;
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

revoke all on function admin_private.resource_kind(text,text),admin_private.resource_owner(text,text),admin_private.resource_assert(uuid,text,text,text,bigint,bigint,boolean),admin_private.resource_record(text,uuid,text,text,text,bigint,boolean,boolean,timestamptz,boolean,boolean),admin_private.resource_storage_event(),admin_private.resource_reservation_event() from public,anon,authenticated;

create or replace function admin_private.resource_attachment_label() returns trigger language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare k text;n text;u uuid;
begin
 if TG_TABLE_NAME='forum_attachments' then k:='supabase/forum-files/'||new.path;n:=new.name;u:=new.owner_id;
 else k:='supabase/'||new.bucket||'/'||new.object_key;n:=new.file_name;u:=new.owner_user_id;end if;
 update admin_private.resource_files set name=n,kind=case when admin_private.resource_kind(n,'')='file' then kind else admin_private.resource_kind(n,'') end where key=k and user_id=u;
 return null;
end $$;
create or replace trigger resource_usage_forum_label after insert or update on public.forum_attachments for each row execute function admin_private.resource_attachment_label();
create or replace trigger resource_usage_group_label after insert or update on public.community_files for each row execute function admin_private.resource_attachment_label();
update admin_private.resource_files r set name=a.name from public.forum_attachments a where r.key='supabase/forum-files/'||a.path and r.user_id=a.owner_id;
update admin_private.resource_files r set name=a.file_name from public.community_files a where r.key='supabase/'||a.bucket||'/'||a.object_key and r.user_id=a.owner_user_id;
revoke all on function admin_private.resource_attachment_label() from public,anon,authenticated;
create or replace function public.resource_my_warnings() returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') from(select id,message,created_at from public.resource_user_warnings where user_id=auth.uid() order by created_at desc limit 30)t
$$;
revoke all on function public.resource_my_warnings() from public,anon;
grant execute on function public.resource_my_warnings() to authenticated;
notify pgrst,'reload schema';
commit;
