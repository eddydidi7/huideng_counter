-- Deploys the quota_private kernel from supabase/drafts/202609290081_total_storage_quota.sql
-- (the draft's own header said "do not deploy until every storage writer has
-- an accounting adapter" — this migration IS that wiring) and connects it as
-- the one real source of truth for personal storage capacity, replacing
-- resource_user_limits.quota_bytes in that specific role. resource_user_limits
-- keeps its unrelated, already-working jobs unchanged: pause, blocked file
-- types, and daily/monthly upload limits.
--
-- Two charging paths, chosen to avoid double-charging the same bytes twice:
--
-- 1. public-resources and group-files buckets already have a dedup-aware
--    reference table (public.file_references, from 202609290086) with its own
--    ref-count-maintaining trigger (file_ref_count). That trigger is extended
--    here to also charge/uncharge quota_private, keyed by the underlying
--    file_objects.id — so the same physical object referenced twice by the
--    same user (e.g. saved to two groups) is charged once, and referenced by
--    two different users is charged to each, per the project's existing
--    "Confirmed Charging Rule" (docs/total_storage_quota_status.md).
-- 2. Every other bucket/table that was already generically tracked by
--    admin_private.resource_storage_event (storage.objects trigger) and
--    admin_private.resource_reservation_event (personal-drive's user_files
--    table) has no reference-sharing mechanism today, so it is charged 1:1
--    (source_key = charge_key = the existing resource key) — extending
--    those same two existing trigger functions rather than adding new ones
--    per bucket. public-resources/group-files are explicitly excluded from
--    this path since path 1 already covers them.
begin;

-- ============================================================
-- 1. The kernel itself, verbatim from the draft.
-- ============================================================
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

create or replace function quota_private.put_source(p_user uuid,p_source text,p_charge text,p_bytes bigint,p_class text)
returns void language plpgsql security definer set search_path='' as $$
declare before_bytes bigint; after_bytes bigint; lim bigint; lvl integer;
begin
 if p_user is null or coalesce(length(p_source),0)=0 or coalesce(length(p_charge),0)=0 then raise exception 'INVALID_SOURCE'; end if;
 insert into quota_private.accounts(user_id) values(p_user) on conflict do nothing;
 perform 1 from quota_private.accounts where user_id=p_user for update;
 lvl:=coalesce((select level from public.app_user_levels where user_id=p_user),2);
 perform 1 from quota_private.levels where level=lvl for share;
 before_bytes:=(quota_private.usage(p_user)->>'occupied_bytes')::bigint;
 insert into quota_private.sources values(p_user,p_source,p_charge,p_bytes,p_class)
 on conflict(user_id,source_key) do update set charge_key=excluded.charge_key,bytes=excluded.bytes,storage_class=excluded.storage_class;
 after_bytes:=(quota_private.usage(p_user)->>'occupied_bytes')::bigint;
 lim:=quota_private.capacity(p_user);
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

-- ============================================================
-- 2. Dedup-aware charging for public-resources + group-files, via the
--    existing file_references ref-count trigger.
-- ============================================================
create or replace function public.file_ref_count() returns trigger
language plpgsql security definer set search_path='' as $$
declare owner uuid; obj public.file_objects; cls text;
begin
  if tg_op='UPDATE' and new.object_id=old.object_id then return new; end if;
  if tg_op<>'DELETE' then
    update public.file_objects set ref_count=ref_count+1 where id=new.object_id and state='ready'
      returning * into obj;
    if not found then raise exception 'FILE_UNAVAILABLE'; end if;
  end if;
  if tg_op<>'INSERT' then
    update public.file_objects set ref_count=ref_count-1 where id=old.object_id;
  end if;
  -- Quota charging is keyed by (kind,source_id), which is stable across an
  -- UPDATE that only changes object_id (e.g. file_canonicalize consolidating
  -- duplicates) — that case must upsert the one source row via put_source,
  -- never remove_source it right after (same key: it would erase what was
  -- just written). Only a true INSERT or DELETE adds/removes the row itself.
  if tg_op<>'DELETE' then
    owner:=case new.kind
      when 'public' then (select user_id from public.public_resources where id=new.source_id)
      when 'group' then (select uploader_id from public.chat_group_files where id=new.source_id)
    end;
    if owner is not null then
      cls:=case when obj.verified then 'permanent' else 'reserved' end;
      perform quota_private.put_source(owner,new.kind||':'||new.source_id::text,new.object_id::text,obj.file_size,cls);
    end if;
  elsif tg_op='DELETE' then
    owner:=case old.kind
      when 'public' then (select user_id from public.public_resources where id=old.source_id)
      when 'group' then (select uploader_id from public.chat_group_files where id=old.source_id)
    end;
    if owner is not null then
      perform quota_private.remove_source(owner,old.kind||':'||old.source_id::text);
    end if;
  end if;
  return coalesce(new,old);
end $$;

-- Once a public-resource upload finishes verifying, its reference should be
-- reclassified from 'reserved' to 'permanent' even though object_id itself
-- did not change (file_ref_count's UPDATE short-circuit above skips that
-- case). Re-run put_source for both kinds whenever verified flips.
create or replace function public.file_ref_reclassify() returns trigger
language plpgsql security definer set search_path='' as $$
declare fr public.file_references; owner uuid;
begin
  if new.verified=old.verified then return new; end if;
  for fr in select * from public.file_references where object_id=new.id loop
    owner:=case fr.kind
      when 'public' then (select user_id from public.public_resources where id=fr.source_id)
      when 'group' then (select uploader_id from public.chat_group_files where id=fr.source_id)
    end;
    if owner is not null then
      perform quota_private.put_source(owner,fr.kind||':'||fr.source_id::text,fr.object_id::text,new.file_size,
        case when new.verified then 'permanent' else 'reserved' end);
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists file_ref_reclassify on public.file_objects;
create trigger file_ref_reclassify after update of verified on public.file_objects
  for each row execute function public.file_ref_reclassify();

-- ============================================================
-- 3. 1:1 charging for every other bucket/table, via the existing generic
--    accounting triggers. public-resources/group-files stay excluded here
--    since section 2 already charges them (dedup-aware).
-- ============================================================
create or replace function admin_private.resource_storage_event() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare r jsonb;u uuid;b text;n text;s bigint;typ text;reserved public.public_resources;key text;
begin
 r:=case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end;b:=r->>'bucket_id';n:=r->>'name';u:=admin_private.resource_owner(b,n);
 if u is null then return null;end if;
 if TG_OP='UPDATE' and (old.name<>new.name or old.bucket_id<>new.bucket_id) then raise exception 'RESOURCE_PATH_IMMUTABLE';end if;
 key:='supabase/'||b||'/'||n;
 if TG_OP='DELETE' then
   update admin_private.resource_files set removed=true where key=key;
   if b not in ('public-resources','group-files') then perform quota_private.remove_source(u,key); end if;
   return null;
 end if;
 s:=coalesce((r->'metadata'->>'size')::bigint,0);
 if r->'metadata'->>'size' is null or s=0 then return null;end if;
 typ:=admin_private.resource_kind(n,coalesce(r->'metadata'->>'mimetype',''));
 if b in ('counter-images','chat-avatars') then typ:='image';elsif b='chat-voice' then typ:='audio';end if;
 if b='public-resources' then
 select * into reserved from public.public_resources where object_key=n;
 if reserved.status in ('deleting','deleted') or reserved.file_size<>s then raise exception 'RESOURCE_UPLOAD_PAUSED';end if;
 if not exists(select 1 from public.public_resource_settings where id and enabled and upload_enabled) then raise exception 'RESOURCE_UPLOAD_PAUSED';end if;
 n:=reserved.file_name;typ:=admin_private.resource_kind(n,reserved.mime_type);
 else n:=regexp_replace(n,'^.*/','');end if;
 perform admin_private.resource_record(key,u,b,n,typ,s,false,false,coalesce((r->>'created_at')::timestamptz,now()),true,case when TG_OP='UPDATE' then (old.metadata->'size' is distinct from new.metadata->'size' or old.metadata->'eTag' is distinct from new.metadata->'eTag' or to_jsonb(old)->'version' is distinct from to_jsonb(new)->'version') and old.metadata->>'size' is not null else false end);
 if b not in ('public-resources','group-files') then perform quota_private.put_source(u,key,key,s,'permanent'); end if;
 return null;
end $$;

create or replace function admin_private.resource_reservation_event() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare j jsonb:=to_jsonb(new);k text;src text;pend boolean;removed boolean;owner uuid;bytes bigint;
begin
 if TG_TABLE_NAME='public_resources' then k:='supabase/public-resources/'||new.object_key;src:='public-resources';pend:=not new.verified;removed:=new.status='deleted';
 if exists(select 1 from admin_private.resource_files where key=k and not pending) then pend:=false;end if;
 else k:='oss/'||new.bucket_name||'/'||new.object_key;src:='personal-drive';pend:=new.upload_state<>'ready';removed:=false;end if;
 owner:=(j->>'user_id')::uuid;bytes:=(j->>'file_size')::bigint;
 perform admin_private.resource_record(k,owner,src,j->>'file_name',admin_private.resource_kind(j->>'file_name',j->>'mime_type'),bytes,pend,removed,(j->>'created_at')::timestamptz);
 -- public_resources is charged via file_ref_count (section 2) instead.
 if TG_TABLE_NAME<>'public_resources' and owner is not null and bytes is not null then
   if removed then perform quota_private.remove_source(owner,k);
   else perform quota_private.put_source(owner,k,k,bytes,case when pend then 'reserved' else 'permanent' end); end if;
 end if;
 return null;
end $$;

-- ============================================================
-- 4. Route the actual enforcement (resource_upload_check's preflight, and
--    every real write via the triggers above) through quota_private instead
--    of resource_user_limits.quota_bytes. Daily/monthly/pause/type-block
--    checks in resource_user_limits are untouched.
-- ============================================================
do $patch$
declare definition text; old_rule text; new_rule text;
begin
  definition:=pg_get_functiondef('admin_private.resource_assert(uuid,text,text,text,bigint,bigint,boolean)'::regprocedure);
  old_rule:='select coalesce(sum(bytes),0) into used from admin_private.resource_files where user_id=u and not removed and key<>k;
 if used+amount>lim.quota_bytes then raise exception ''RESOURCE_USER_QUOTA'';end if;';
  new_rule:='select coalesce((quota_private.usage(u)->>''occupied_bytes'')::bigint,0) into used;
 if quota_private.capacity(u) is not null and used+amount>quota_private.capacity(u) then raise exception ''RESOURCE_USER_QUOTA'';end if;';
  if position(new_rule in definition)=0 then
    if position(old_rule in definition)=0 then raise exception 'Cannot locate resource_assert quota check; migration not applied'; end if;
    definition:=replace(definition,old_rule,new_rule);
    definition:=replace(definition,
      'language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$',
      'language plpgsql security definer set search_path=pg_catalog,public,admin_private,quota_private as $$');
    execute definition;
  end if;
end $patch$;

-- ============================================================
-- 4b. The existing admin "用户资源用量" list/detail already reads this view;
--     point its quota/used/remaining/percent columns at the same dedup-aware
--     kernel instead of the old flat quota_bytes + naive per-row sum, so the
--     existing admin UI shows correct numbers with no app changes required
--     for this part. Per-category byte breakdowns (image/video/etc) are left
--     on the old per-row source — those are informational, not the quota
--     total, and cross-user dedup for them was never part of the request.
-- ============================================================
-- DROP + CREATE, not CREATE OR REPLACE: several columns change type (e.g.
-- quota_bytes/used_bytes can now be NULL for an unlimited level-1 account,
-- and their numeric-vs-bigint typing changes now that they come from a
-- jsonb field instead of a bigint sum()), and CREATE OR REPLACE VIEW
-- requires every existing column to keep an identical type. Nothing else
-- in this schema is built on top of this view (only queried directly by
-- huideng_admin_usage), so dropping it first is safe.
drop view if exists admin_private.resource_user_usage;
create view admin_private.resource_user_usage as
 select u.id user_id,coalesce(u.raw_user_meta_data->>'username',split_part(coalesce(u.email,''),'@',1),'') username,coalesce(p.nickname,'未设置昵称') nickname,
 coalesce(l.level,1) level,u.created_at registered_at,greatest(u.last_sign_in_at,(select max(seen_at) from public.chat_presence where user_id=u.id)) last_active_at,
 (qu->>'quota_bytes')::bigint quota_bytes,(qu->>'used_bytes')::bigint used_bytes,(qu->>'reserved_bytes')::bigint pending_bytes,
 (qu->>'remaining_bytes')::bigint remaining_bytes,coalesce((qu->>'usage_percent')::numeric,0) usage_percent,
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
 coalesce(u.banned_until>now(),false) banned,u.banned_until,
 (qu->>'unlimited_storage')::boolean unlimited_storage,(qu->>'override_bytes')::bigint override_bytes,
 (qu->>'revision')::bigint quota_revision,qu->>'warning' quota_warning
 from auth.users u left join public.chat_profiles p on p.user_id=u.id left join public.app_user_levels l on l.user_id=u.id left join public.resource_user_limits q on q.user_id=u.id
 cross join lateral(select quota_private.usage(u.id) as qu) x
 left join lateral(select sum(bytes) filter(where not pending) used_bytes,sum(bytes) filter(where pending) pending_bytes,
 sum(bytes) filter(where kind='image' and not pending) image_bytes,sum(bytes) filter(where kind='document' and not pending) document_bytes,sum(bytes) filter(where kind='audio' and not pending) audio_bytes,sum(bytes) filter(where kind='apk' and not pending) apk_bytes,sum(bytes) filter(where kind='video' and not pending) video_bytes,sum(bytes) filter(where kind='file' and not pending) other_bytes,
 sum(bytes) filter(where bytes>=52428800 and not pending) large_bytes,sum(bytes) filter(where source in ('personal-drive','public-resources') and not pending) drive_bytes from admin_private.resource_files where user_id=u.id and not removed)f on true
 left join lateral(select sum(bytes) filter(where created_at>=(date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) day_bytes,sum(bytes) month_bytes,count(*) filter(where created_at>=(date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) day_files,count(*) month_files from admin_private.resource_upload_events where user_id=u.id and created_at>=(date_trunc('month',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai'))e on true
 left join lateral(select sum(bytes) filter(where created_at>=(date_trunc('day',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) day_bytes,sum(bytes) month_bytes from public.public_resource_downloads where user_id=u.id and created_at>=(date_trunc('month',now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai'))d on true;
revoke all on admin_private.resource_user_usage from public,anon,authenticated;

-- ============================================================
-- 5. Backfill existing files into quota_private so day-one usage reflects
--    what is already on disk, not zero.
-- ============================================================
insert into quota_private.accounts(user_id)
select id from auth.users where not coalesce(is_anonymous,false)
on conflict do nothing;

-- public-resources + group-files: dedup-aware, from file_references.
insert into quota_private.sources(user_id,source_key,charge_key,bytes,storage_class)
select owner.user_id, fr.kind||':'||fr.source_id::text, fr.object_id::text, fo.file_size,
  case when fo.verified then 'permanent' else 'reserved' end
from public.file_references fr
join public.file_objects fo on fo.id=fr.object_id
join lateral (
  select case fr.kind
    when 'public' then (select user_id from public.public_resources where id=fr.source_id)
    when 'group' then (select uploader_id from public.chat_group_files where id=fr.source_id)
  end as user_id
) owner on owner.user_id is not null
on conflict(user_id,source_key) do update set charge_key=excluded.charge_key,bytes=excluded.bytes,storage_class=excluded.storage_class;

-- Everything else already tracked in admin_private.resource_files: 1:1.
insert into quota_private.sources(user_id,source_key,charge_key,bytes,storage_class)
select user_id,key,key,bytes,case when pending then 'reserved' else 'permanent' end
from admin_private.resource_files
where not removed and source not in ('public-resources','group-files')
on conflict(user_id,source_key) do update set charge_key=excluded.charge_key,bytes=excluded.bytes,storage_class=excluded.storage_class;

-- quota_private.* functions are called only from other security definer
-- functions owned by the same (migration-running) role, so no explicit
-- execute grant is needed for that — matching admin_private's own existing
-- convention elsewhere in this schema.
revoke all on all tables in schema quota_private from public,anon,authenticated,service_role;
revoke all on all sequences in schema quota_private from public,anon,authenticated,service_role;
revoke all on all functions in schema quota_private from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
