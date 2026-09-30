-- 202609290091_app_update_policy.sql (applied after 077_app_releases_platform.sql
-- in filename/deploy order) did `create or replace function
-- public.latest_app_version() returns jsonb` to add the updates_enabled gate,
-- but its replacement body queries app_releases with NO platform filter at
-- all, silently undoing 077's "delegate to latest_app_version('android')"
-- fix. Any client still calling the legacy zero-arg RPC (an Android build
-- from before the platform-aware client shipped) would since then receive
-- whichever platform's row has the highest version_code — e.g. a Windows
-- release's download_url handed to an Android device — instead of an
-- android-only answer.
--
-- This restores platform delegation on the zero-arg function while keeping
-- 091's updates_enabled gate, and adds the same gate to the platform-aware
-- one-arg function so both entry points use one consistent rule (all
-- clients already also check `enabled` themselves; this just makes the
-- server side agree, per the "one real data source" requirement).
begin;

create or replace function public.latest_app_version(p_platform text) returns jsonb
language sql stable security definer set search_path='' as $$
 select case when r.updates_enabled then to_jsonb(r)-'is_published'-'notified_at'-'updated_at'-'ever_published' else null end
 from public.app_releases r
 where r.platform=p_platform and r.is_published and r.published_at<=now()
 order by r.version_code desc limit 1
$$;
revoke all on function public.latest_app_version(text) from public;
grant execute on function public.latest_app_version(text) to anon,authenticated;

create or replace function public.latest_app_version() returns jsonb
language sql stable security definer set search_path='' as $$
 select public.latest_app_version('android')
$$;
revoke all on function public.latest_app_version() from public;
grant execute on function public.latest_app_version() to anon,authenticated;

notify pgrst, 'reload schema';
commit;
