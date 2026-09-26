begin;
create table if not exists public.app_releases (
 version_code integer primary key check(version_code>0),
 version_name text not null check(length(version_name) between 1 and 60),
 download_url text not null check(download_url ~ '^https://[^/[:space:]]+/'),
 release_notes text not null check(length(release_notes) between 1 and 15000),
 apk_size bigint not null check(apk_size between 1 and 524288000),
 sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
 published_at timestamptz not null default now(),
 force_update boolean not null default false,
 is_published boolean not null default false,
 notified_at timestamptz,
 updated_at timestamptz not null default now()
);
alter table public.app_releases enable row level security;
revoke all on public.app_releases from public,anon,authenticated;
alter table public.app_notices add column if not exists release_version_code integer;
create or replace function public.latest_app_version() returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(r)-'is_published'-'notified_at'-'updated_at' from public.app_releases r
 where is_published and published_at<=now() order by version_code desc limit 1
$$;
revoke all on function public.latest_app_version() from public;
grant execute on function public.latest_app_version() to anon,authenticated;

create or replace function public.huideng_admin_releases(actor uuid,action text,payload jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare code integer; old public.app_releases; result jsonb;
begin
 perform pg_advisory_xact_lock_shared(4815162342);
 if not exists(select 1 from admin_private.members m join auth.users u on u.id=m.user_id
  where m.user_id=actor and m.enabled and m.role in ('super_admin','admin')
  and (u.banned_until is null or u.banned_until<now())) then raise exception 'forbidden' using errcode='42501'; end if;
 if action='releases.list' then return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(r) order by version_code desc) from public.app_releases r),'[]')); end if;
 code:=(payload->>'version_code')::integer;
 perform pg_advisory_xact_lock(58000,code);
 select * into old from public.app_releases where version_code=code for update;
 if action='releases.save' then
  if old.version_code is not null and (payload->>'expected_updated_at')::timestamptz is distinct from old.updated_at
   then raise exception 'release changed; reload' using errcode='40001'; end if;
  -- Published binaries are immutable. Publish a higher version code instead.
  if old.is_published and (old.sha256 is distinct from payload->>'sha256' or old.apk_size is distinct from (payload->>'apk_size')::bigint)
   then raise exception 'published binary is immutable' using errcode='22023'; end if;
  insert into public.app_releases(version_code,version_name,download_url,release_notes,apk_size,sha256,published_at,force_update,is_published)
  values(code,payload->>'version_name',payload->>'download_url',payload->>'release_notes',(payload->>'apk_size')::bigint,
   lower(payload->>'sha256'),(payload->>'published_at')::timestamptz,coalesce((payload->>'force_update')::boolean,false),coalesce((payload->>'is_published')::boolean,false))
  on conflict(version_code) do update set version_name=excluded.version_name,download_url=excluded.download_url,
   release_notes=excluded.release_notes,apk_size=excluded.apk_size,sha256=excluded.sha256,published_at=excluded.published_at,
   force_update=excluded.force_update,is_published=excluded.is_published,updated_at=clock_timestamp();
 elsif action='releases.notify' then
  if old.version_code is null or not old.is_published or old.published_at>now() then raise exception 'publish first' using errcode='22023'; end if;
  if old.notified_at is null then
   insert into public.app_notices(title_zh,title_en,body_zh,body_en,is_published,notice_type,published_at,created_by,updated_by,release_version_code)
   values('慧灯计数器有新版本 '||old.version_name,'New version '||old.version_name,
    old.release_notes,old.release_notes,true,'system',now(),actor,actor,code);
   update public.app_releases set notified_at=clock_timestamp(),updated_at=clock_timestamp() where version_code=code;
  end if;
 else raise exception 'invalid action' using errcode='22023'; end if;
 select to_jsonb(r) into result from public.app_releases r where version_code=code;
 insert into admin_private.audit_logs(actor,action,target,before_data,after_data) values(actor,action,code::text,to_jsonb(old),result);
 return result;
end $$;
revoke all on function public.huideng_admin_releases(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.huideng_admin_releases(uuid,text,jsonb,uuid) to service_role;
commit;
