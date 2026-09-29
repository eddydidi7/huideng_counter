-- app_releases gains a platform column so Android and Windows can each have
-- their own "latest version" without colliding. version_code stays a single
-- global primary key (not touched): pick disjoint ranges per platform when
-- publishing (documented separately), rather than relaxing the constraint.
--
-- Backward compatible: existing rows backfill platform='android', and the
-- old zero-arg latest_app_version() keeps working for any Android client
-- that hasn't updated yet (it now delegates to latest_app_version('android')).
begin;

do $$
begin
  if to_regprocedure('public.huideng_admin_releases(uuid,text,jsonb,uuid)') is null then
    raise exception 'Missing prerequisite: huideng_admin_releases (202609210058)';
  end if;
end $$;

alter table public.app_releases add column if not exists platform text not null default 'android'
  check (platform in ('android','windows','ios'));
create index if not exists app_releases_platform_idx on public.app_releases(platform, version_code desc);

create or replace function public.latest_app_version(p_platform text) returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(r)-'is_published'-'notified_at'-'updated_at' from public.app_releases r
 where r.platform=p_platform and r.is_published and r.published_at<=now() order by r.version_code desc limit 1
$$;
revoke all on function public.latest_app_version(text) from public;
grant execute on function public.latest_app_version(text) to anon,authenticated;

-- Kept for any Android client still on the pre-platform API.
create or replace function public.latest_app_version() returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
 select public.latest_app_version('android')
$$;
revoke all on function public.latest_app_version() from public;
grant execute on function public.latest_app_version() to anon,authenticated;

do $$
declare definition text; old_rule text; new_rule text;
begin
  definition := pg_get_functiondef('public.huideng_admin_releases(uuid,text,jsonb,uuid)'::regprocedure);

  old_rule := 'insert into public.app_releases(version_code,version_name,download_url,release_notes,apk_size,sha256,published_at,force_update,is_published)';
  new_rule := 'insert into public.app_releases(version_code,platform,version_name,download_url,release_notes,apk_size,sha256,published_at,force_update,is_published)';
  if position(new_rule in definition) = 0 then
    if position(old_rule in definition) = 0 then raise exception 'Cannot locate app_releases insert column list; migration not applied'; end if;
    definition := replace(definition, old_rule, new_rule);

    old_rule := 'values(code,payload->>''version_name'',payload->>''download_url'',payload->>''release_notes'',(payload->>''apk_size'')::bigint,';
    new_rule := 'values(code,coalesce(nullif(payload->>''platform'',''''),''android''),payload->>''version_name'',payload->>''download_url'',payload->>''release_notes'',(payload->>''apk_size'')::bigint,';
    if position(old_rule in definition) = 0 then raise exception 'Cannot locate app_releases insert values list; migration not applied'; end if;
    definition := replace(definition, old_rule, new_rule);

    old_rule := 'on conflict(version_code) do update set version_name=excluded.version_name,download_url=excluded.download_url,';
    new_rule := 'on conflict(version_code) do update set platform=excluded.platform,version_name=excluded.version_name,download_url=excluded.download_url,';
    if position(old_rule in definition) = 0 then raise exception 'Cannot locate app_releases on-conflict clause; migration not applied'; end if;
    definition := replace(definition, old_rule, new_rule);

    execute definition;
  end if;
end $$;

notify pgrst, 'reload schema';
commit;
