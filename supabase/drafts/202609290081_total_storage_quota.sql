-- DRAFT: do not deploy until every storage writer has an accounting adapter.
-- This kernel deliberately grants no public charging or reservation endpoint.
begin;
create schema if not exists quota_private;
revoke all on schema quota_private from public,anon,authenticated;
create table if not exists quota_private.levels (
 level integer primary key check(level between 1 and 5),
 bytes bigint check(bytes between 0 and 9007199254740991),
 unlimited_storage boolean not null default false,
 constraint quota_level_capacity check(
  (level=1 and unlimited_storage and bytes is null) or
  (level<>1 and not unlimited_storage and bytes is not null)),
 revision bigint not null default 0
);
insert into quota_private.levels(level,bytes,unlimited_storage) values
 (1,null,true),(2,10737418240,false),(3,5368709120,false),(4,2147483648,false),(5,524288000,false)
 on conflict do nothing;
create table if not exists quota_private.accounts (
 user_id uuid primary key references auth.users(id) on delete cascade,
 override_bytes bigint check(override_bytes between 0 and 9007199254740991),
 revision bigint not null default 0
);
-- Each source is one authorized reference. The same charge key is counted
-- once per user, never once globally. Blob keys must come from server-verified
-- File Objects, not a caller-provided SHA-256 value.
create table if not exists quota_private.sources (
 user_id uuid not null references auth.users(id) on delete cascade,
 source_key text not null, charge_key text not null,
 bytes bigint not null check(bytes between 0 and 9007199254740991),
 storage_class text not null check(storage_class in ('permanent','temporary','reserved')),
 primary key(user_id,source_key)
);
create index if not exists quota_sources_charge on quota_private.sources(user_id,charge_key);
create table if not exists quota_private.audit (
 id bigint generated always as identity primary key,
 actor uuid not null, request_id uuid not null, action text not null,
 payload jsonb not null, before_data jsonb, after_data jsonb not null,
 created_at timestamptz not null default statement_timestamp(),
 unique(actor,request_id)
);

create or replace function quota_private.capacity(p_user uuid)
returns bigint language sql stable security definer set search_path='' as $$
 select case when l.unlimited_storage then null else
  coalesce((select override_bytes from quota_private.accounts where user_id=p_user),l.bytes) end
 from quota_private.levels l where l.level=coalesce(
  (select level from public.app_user_levels where user_id=p_user),2)
$$;
create or replace function quota_private.usage(p_user uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 with entities as (
  select charge_key,max(bytes) bytes,
   bool_or(storage_class='permanent') permanent,
   bool_or(storage_class='temporary') temporary
  from quota_private.sources where user_id=p_user group by charge_key
 ), totals as (
  select coalesce(sum(bytes) filter(where permanent),0)::bigint permanent,
   coalesce(sum(bytes) filter(where not permanent and temporary),0)::bigint temporary,
   coalesce(sum(bytes) filter(where not permanent and not temporary),0)::bigint reserved
  from entities
 ), effective as (select *,quota_private.capacity(p_user) capacity,
  permanent+temporary+reserved occupied from totals)
 select jsonb_build_object('user_id',p_user,'level',coalesce((select level from public.app_user_levels where user_id=p_user),2),
  'revision',coalesce((select revision from quota_private.accounts where user_id=p_user),0),
  'override_bytes',(select override_bytes from quota_private.accounts where user_id=p_user),
  'quota_bytes',capacity,'unlimited_storage',capacity is null,'permanent_bytes',permanent,'temporary_bytes',temporary,'reserved_bytes',reserved,
  'used_bytes',permanent+temporary,'occupied_bytes',occupied,
  'remaining_bytes',case when capacity is null then null else greatest(0,capacity-occupied) end,
  'over_bytes',case when capacity is null then 0 else greatest(0,occupied-capacity) end,
  'usage_percent',case when capacity is null then null when capacity=0 then case when occupied=0 then 0 else 100 end else round(100.0*occupied/capacity,2) end,
  'warning',case when capacity is null then 'normal' when occupied>=capacity then 'full' when occupied*100::numeric>=capacity*90::numeric then 'critical'
   when occupied*100::numeric>=capacity*80::numeric then 'warning' else 'normal' end,
  'server_time',statement_timestamp()) from effective
$$;

-- Called only from trusted accounting adapters in the same write transaction.
-- A reservation is a source and is converted using the same charge key.
create or replace function quota_private.put_source(p_user uuid,p_source text,p_charge text,p_bytes bigint,p_class text)
returns void language plpgsql security definer set search_path='' as $$
declare before_bytes bigint; after_bytes bigint; lim bigint; lvl integer;
begin
 if p_user is null or coalesce(length(p_source),0)=0 or coalesce(length(p_charge),0)=0 then raise exception 'INVALID_SOURCE'; end if;
 -- Always lock the account before its level, matching admin override changes.
 insert into quota_private.accounts(user_id) values(p_user) on conflict do nothing;
 perform 1 from quota_private.accounts where user_id=p_user for update;
 lvl:=coalesce((select level from public.app_user_levels where user_id=p_user),2);
 perform 1 from quota_private.levels where level=lvl for share;
 before_bytes:=(quota_private.usage(p_user)->>'occupied_bytes')::bigint;
 insert into quota_private.sources values(p_user,p_source,p_charge,p_bytes,p_class)
 on conflict(user_id,source_key) do update set charge_key=excluded.charge_key,bytes=excluded.bytes,storage_class=excluded.storage_class;
 after_bytes:=(quota_private.usage(p_user)->>'occupied_bytes')::bigint;
 lim:=quota_private.capacity(p_user);
 -- Over-quota users may reduce data, retry identical writes and remove a
 -- reference. Only positive growth is denied; no account bans or deletions.
 if lim is not null and after_bytes>lim and after_bytes>before_bytes then
  raise exception 'STORAGE_QUOTA_EXCEEDED' using errcode='P0001',
   detail=jsonb_build_object('quota_bytes',lim,'used_bytes',before_bytes,'requested_growth',after_bytes-before_bytes)::text;
 end if;
end $$;
create or replace function quota_private.remove_source(p_user uuid,p_source text)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from quota_private.accounts where user_id=p_user for update;
 delete from quota_private.sources where user_id=p_user and source_key=p_source;
end $$;

create or replace function public.my_storage_quota()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'LOGIN_REQUIRED'; end if;
 return quota_private.usage(auth.uid());
end $$;
revoke all on function public.my_storage_quota() from public,anon;
grant execute on function public.my_storage_quota() to authenticated;

create or replace function public.admin_storage_quota(p_actor uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid; req uuid; previous quota_private.audit; current_revision bigint;
 result jsonb; before_data jsonb; level_id integer; amount bigint;
begin
 if not exists(select 1 from admin_private.members where user_id=p_actor and enabled and role in ('admin','super_admin'))
 or not exists(select 1 from auth.users where id=p_actor and (banned_until is null or banned_until<statement_timestamp()))
 then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 if p_action='levels' then
  return jsonb_build_object('items',(select jsonb_agg(to_jsonb(l) order by level) from quota_private.levels l));
 end if;
 if p_action='get' then
  target:=(p_data->>'user_id')::uuid;
  if not exists(select 1 from auth.users where id=target) then raise exception 'USER_NOT_FOUND'; end if;
  return quota_private.usage(target);
 end if;
 if p_action not in ('level_save','override','reset') then raise exception 'INVALID_ACTION'; end if;
 req:=(p_data->>'request_id')::uuid;
 if req is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||req::text,81));
 select * into previous from quota_private.audit where actor=p_actor and request_id=req;
 if found then
  if previous.action<>p_action or previous.payload<>p_data then raise exception 'CONFIG_CONFLICT'; end if;
  return previous.after_data;
 end if;
 if p_action='level_save' then
  level_id:=(p_data->>'level')::integer;
  if level_id=1 then raise exception 'LEVEL_ONE_UNLIMITED'; end if;
  select revision,to_jsonb(l) into current_revision,before_data from quota_private.levels l where level=level_id for update;
  if not found then raise exception 'INVALID_LEVEL'; end if;
  if current_revision is distinct from (p_data->>'revision')::bigint then raise exception 'CONFIG_CONFLICT'; end if;
  amount:=(p_data->>'bytes')::bigint;
  if amount is null or amount<0 or amount>9007199254740991 then raise exception 'INVALID_CAPACITY'; end if;
  update quota_private.levels set bytes=amount,revision=revision+1 where level=level_id;
  select to_jsonb(l) into result from quota_private.levels l where level=level_id;
 else
  target:=(p_data->>'user_id')::uuid;
  if not exists(select 1 from auth.users where id=target) then raise exception 'USER_NOT_FOUND'; end if;
  insert into quota_private.accounts(user_id) values(target) on conflict do nothing;
  select revision into current_revision from quota_private.accounts where user_id=target for update;
  if current_revision is distinct from (p_data->>'revision')::bigint then raise exception 'CONFIG_CONFLICT'; end if;
  before_data:=quota_private.usage(target);
  amount:=case when p_action='reset' then null else (p_data->>'bytes')::bigint end;
  if p_action='override' and (amount is null or amount<0 or amount>9007199254740991) then raise exception 'INVALID_CAPACITY'; end if;
  update quota_private.accounts set override_bytes=amount,revision=revision+1 where user_id=target;
  result:=quota_private.usage(target);
 end if;
 insert into quota_private.audit(actor,request_id,action,payload,before_data,after_data)
 values(p_actor,req,p_action,p_data,before_data,result);
 return result;
end $$;
revoke all on function public.admin_storage_quota(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.admin_storage_quota(uuid,text,jsonb) to service_role;
revoke all on all tables in schema quota_private from public,anon,authenticated,service_role;
revoke all on all sequences in schema quota_private from public,anon,authenticated,service_role;
revoke all on all functions in schema quota_private from public,anon,authenticated,service_role;
commit;
