begin;
-- Public capability links; bucket remains private. No user data is deleted.
create table if not exists public.public_resource_web_links(
 resource_id uuid primary key references public.public_resources(id),
 slug text not null unique default replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),
 created_at timestamptz not null default now(),check(slug ~ '^[a-f0-9]{64}$'));
alter table public.public_resource_web_links enable row level security;
revoke all on public.public_resource_web_links from public,anon,authenticated;
create table if not exists admin_private.resource_web_daily(day date primary key,signed_bytes bigint not null default 0,requests bigint not null default 0);
alter table admin_private.resource_web_daily enable row level security;
revoke all on admin_private.resource_web_daily from public,anon,authenticated;
alter table public.public_resource_settings add column if not exists web_daily_signed_bytes bigint not null default 21474836480 check(web_daily_signed_bytes>=0);
create or replace function public.public_resource_share_create(p_actor uuid,p_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare s text;b text;
begin
 if not exists(select 1 from auth.users where id=p_actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) or exists(select 1 from public.forum_restrictions where user_id=p_actor and blocked) then raise exception 'LOGIN_REQUIRED';end if;
 if not exists(select 1 from public.public_resource_settings where id and enabled and download_enabled) then raise exception 'DOWNLOAD_DISABLED';end if;
 if not exists(select 1 from public.public_resources where id=p_id and status='published' and verified and not moderated) then raise exception 'FILE_UNAVAILABLE';end if;
 select rtrim(public_base_url,'/') into b from public.community_config where id;
 if b is null or b !~ '^https://[^[:space:]]+$' then raise exception 'RESOURCE_NOT_CONFIGURED';end if;
 insert into public.public_resource_web_links(resource_id) values(p_id) on conflict do nothing;
 select slug into s from public.public_resource_web_links where resource_id=p_id;
 return jsonb_build_object('url',b||'/f/'||s);
end $$;
create or replace function public.public_resource_web_resolve(p_slug text,p_download boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare f public.public_resources;cfg public.public_resource_settings;today date:=(now() at time zone 'Asia/Shanghai')::date;used bigint;result jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-f0-9]{64}$' then raise exception 'FILE_UNAVAILABLE';end if;
 select * into cfg from public.public_resource_settings where id for update;
 if not found or not cfg.enabled or not cfg.download_enabled then raise exception 'DOWNLOAD_DISABLED';end if;
 select r.* into f from public.public_resources r join public.public_resource_web_links l on l.resource_id=r.id where l.slug=p_slug and r.status='published' and r.verified and not r.moderated;
 if not found then raise exception 'FILE_UNAVAILABLE';end if;
 result:=jsonb_build_object('file_name',f.file_name,'file_size',f.file_size,'checksum',f.checksum,'created_at',f.created_at,'author_name',f.author_name,'mime_type',f.mime_type);
 if p_download then
 insert into admin_private.resource_web_daily(day) values(today) on conflict do nothing;
 select signed_bytes into used from admin_private.resource_web_daily where day=today for update;
 if used+f.file_size>cfg.web_daily_signed_bytes then raise exception 'DOWNLOAD_LIMIT';end if;
 update admin_private.resource_web_daily set signed_bytes=signed_bytes+f.file_size,requests=requests+1 where day=today;
 result:=result||jsonb_build_object('object_key',f.object_key);
 end if;
 return result;
end $$;
revoke all on function public.public_resource_share_create(uuid,uuid),public.public_resource_web_resolve(text,boolean) from public,anon,authenticated;
grant execute on function public.public_resource_share_create(uuid,uuid),public.public_resource_web_resolve(text,boolean) to service_role;
commit;
