begin;
alter table public.app_releases
 add column if not exists updates_enabled boolean not null default true,
 add column if not exists prompt_enabled boolean not null default true,
 add column if not exists startup_check boolean not null default true,
 add column if not exists auto_download boolean not null default false,
 add column if not exists wifi_only boolean not null default true,
 add column if not exists minimum_version_code integer not null default 0
  check(minimum_version_code>=0 and minimum_version_code<=version_code),
 add column if not exists ever_published boolean not null default false;
update public.app_releases r set ever_published=true
 where is_published or notified_at is not null or exists(
  select 1 from admin_private.audit_logs a where a.action='releases.save'
   and a.target=r.version_code::text and a.after_data->>'is_published'='true');

create or replace function public.latest_app_version() returns jsonb
language sql stable security definer set search_path='' as $$
 select case when r.updates_enabled then to_jsonb(r)-'is_published'-'notified_at'-'updated_at'-'ever_published' else null end
 from public.app_releases r where is_published and published_at<=now()
 order by version_code desc limit 1
$$;

do $$ begin
 if to_regprocedure('public.huideng_admin_releases_before_policy(uuid,text,jsonb,uuid)') is null then
  alter function public.huideng_admin_releases(uuid,text,jsonb,uuid) rename to huideng_admin_releases_before_policy;
 end if;
end $$;
revoke all on function public.huideng_admin_releases_before_policy(uuid,text,jsonb,uuid) from public,anon,authenticated;
create or replace function public.huideng_admin_releases(actor uuid,action text,payload jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; prior public.app_releases; code integer; k text; minimum integer;
begin
 -- The original service performs administrator authorization and audit logging.
 if action<>'releases.save' then
  return public.huideng_admin_releases_before_policy(actor,action,payload,request_id);
 end if;
 perform pg_advisory_xact_lock(58001,0);
 code:=(payload->>'version_code')::integer;
 select * into prior from public.app_releases where version_code=code for update;
 if prior.ever_published and (prior.sha256 is distinct from lower(payload->>'sha256')
  or prior.apk_size is distinct from (payload->>'apk_size')::bigint
  or prior.version_name is distinct from payload->>'version_name') then
  raise exception 'published binary is immutable';
 end if;
 if coalesce((payload->>'is_published')::boolean,false) and not coalesce(prior.ever_published,false)
  and exists(select 1 from public.app_releases where ever_published and version_code>=code) then
  raise exception 'versionCode must increase';
 end if;
 minimum:=coalesce((payload->>'minimum_version_code')::integer,prior.minimum_version_code,0);
 if minimum<0 or minimum>code then raise exception 'invalid minimum versionCode'; end if;
 foreach k in array array['updates_enabled','prompt_enabled','startup_check','auto_download','wifi_only'] loop
  if payload ? k and jsonb_typeof(payload->k)<>'boolean' then raise exception 'invalid update policy'; end if;
 end loop;
 result:=public.huideng_admin_releases_before_policy(actor,action,payload,request_id);
 update public.app_releases set
  updates_enabled=coalesce((payload->>'updates_enabled')::boolean,updates_enabled),
  prompt_enabled=coalesce((payload->>'prompt_enabled')::boolean,prompt_enabled),
  startup_check=coalesce((payload->>'startup_check')::boolean,startup_check),
  auto_download=coalesce((payload->>'auto_download')::boolean,auto_download),
  wifi_only=coalesce((payload->>'wifi_only')::boolean,wifi_only),
  minimum_version_code=minimum,ever_published=ever_published or is_published
 where version_code=code;
 select to_jsonb(r) into result from public.app_releases r where version_code=code;
 insert into admin_private.audit_logs(actor,action,target,before_data,after_data)
 values(actor,'releases.policy',code::text,to_jsonb(prior),result);
 return result;
end $$;
revoke all on function public.huideng_admin_releases(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.huideng_admin_releases(uuid,text,jsonb,uuid) to service_role;
commit;
