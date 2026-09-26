-- Huideng Counter: proposed first Supabase migration. Run once on a test project.
-- No destructive changes to existing application tables. Requires Supabase Auth/Storage.
begin;
create table public.counter_sync_heads (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0)
);
create table public.counter_projects (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  data jsonb not null,
  revision bigint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
create table public.counter_events (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  project_id uuid not null,
  delta bigint not null check (delta between -9007199254740991 and 9007199254740991),
  -- A local observation, NEVER used as the merged total. Legacy v1 taps are unknown.
  count_after bigint check (count_after between 0 and 9007199254740991),
  created_at timestamptz not null,
  updated_at timestamptz not null,
  occurred_at timestamptz not null,
  device_id uuid not null,
  source text not null check (length(source) between 1 and 64),
  session_id uuid,
  note text check (length(note) <= 4000),
  sync_status text not null default 'synced' check (sync_status = 'synced'),
  revision bigint not null,
  received_at timestamptz not null default now(),
  primary key(user_id, id),
  foreign key(user_id, project_id) references public.counter_projects(user_id, id)
);
create index counter_events_history on public.counter_events(user_id, project_id, occurred_at, id);
-- Settings: one document per key; order: one atomic UUID array; sessions: history summary.
create table public.counter_documents (
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check(kind in ('setting','order','session')),
  id text not null,
  data jsonb not null,
  revision bigint not null,
  updated_at timestamptz not null default now(),
  primary key(user_id, kind, id)
);
create table public.counter_change_feed (
  user_id uuid not null references auth.users(id) on delete cascade,
  revision bigint not null,
  kind text not null,
  entity_id text not null,
  payload jsonb not null,
  primary key(user_id, revision)
);
create table public.counter_mutation_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  request jsonb not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key(user_id, request_id)
);

-- Every user-bearing table is RLS protected. Client writes only through bounded RPCs.
-- Read-only table grants prevent bypassing append-only, CAS and feed invariants.
do $$ declare t text; begin
  foreach t in array array['counter_sync_heads','counter_projects','counter_events',
    'counter_documents','counter_change_feed','counter_mutation_receipts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_read on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- Serialized per user. Revision allocation and feed insertion commit together.
-- Do not replace this with a sequence or timestamp cursor: transactions commit out of order.
create function public.counter_push_event(p_event jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid();
  e public.counter_events;
  previous public.counter_events;
  rev bigint;
  canonical jsonb;
begin
  if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if (p_event->>'user_id')::uuid is distinct from u then
    raise exception 'wrong_owner' using errcode='42501';
  end if;
  if pg_catalog.pg_column_size(p_event) > 32768 then raise exception 'payload_too_large'; end if;
  e := jsonb_populate_record(null::public.counter_events, p_event);
  if e.id is null or e.project_id is null or e.delta is null or e.device_id is null
    or e.created_at is null or e.updated_at is null or e.occurred_at is null
    or e.source is null then raise exception 'invalid_event'; end if;
  if e.count_after is null and e.source not in ('legacy_unknown') then
    raise exception 'count_after_required';
  end if;
  e.sync_status := 'synced';
  e.revision := null;
  e.received_at := null;
  canonical := to_jsonb(e) - 'revision' - 'received_at';
  insert into public.counter_sync_heads(user_id) values(u) on conflict do nothing;
  perform 1 from public.counter_sync_heads where user_id=u for update;
  select * into previous from public.counter_events where user_id=u and id=e.id;
  if found then
    if (to_jsonb(previous) - 'revision' - 'received_at') is distinct from canonical then
      return jsonb_build_object('status','conflict','reason','uuid_payload_mismatch','remote',to_jsonb(previous));
    end if;
    return jsonb_build_object('status','accepted','revision',previous.revision);
  end if;
  -- Includes soft-deleted projects so delayed offline history is retained, never resurrected.
  if not exists(select 1 from public.counter_projects where user_id=u and id=e.project_id) then
    return jsonb_build_object('status','dependency_missing');
  end if;
  update public.counter_sync_heads set revision=revision+1 where user_id=u returning revision into rev;
  e.revision := rev;
  e.received_at := clock_timestamp();
  insert into public.counter_events select (e).*;
  insert into public.counter_change_feed values(u,rev,'event',e.id::text,to_jsonb(e));
  return jsonb_build_object('status','accepted','revision',rev);
end $$;

create function public.counter_put_document(
  p_kind text, p_id text, p_expected_revision bigint, p_data jsonb, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid(); rev bigint; old_rev bigint; old_data jsonb;
  req jsonb; receipt public.counter_mutation_receipts; result jsonb;
begin
  if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if p_kind is null or p_kind not in ('project','setting','session','order')
    or p_id is null or length(p_id) not between 1 and 100 or p_request_id is null
    or p_expected_revision is null or p_expected_revision < 0
    or p_data is null or jsonb_typeof(p_data) <> 'object'
    or pg_catalog.pg_column_size(p_data) > 1048576 then raise exception 'invalid_document'; end if;
  if p_kind = 'project' then
    perform p_id::uuid;
    if jsonb_typeof(p_data->'name') is distinct from 'string'
      or length(trim(p_data->>'name')) not between 1 and 80
      or (p_data - array['name','image_key','deleted_at']) <> '{}'::jsonb then
      raise exception 'invalid_project';
    end if;
    if p_data->>'image_key' is not null and
      split_part(p_data->>'image_key','/',1) <> u::text then raise exception 'wrong_image_owner'; end if;
    if p_data->>'deleted_at' is not null then perform (p_data->>'deleted_at')::timestamptz; end if;
  elsif p_kind = 'setting' then
    if p_id not in ('language','haptics','calendarUrl','forumUrl','noticeUrl')
      or jsonb_typeof(p_data->'value') is distinct from 'string'
      or length(p_data->>'value') > 4096 or (p_data - 'value') <> '{}'::jsonb then raise exception 'invalid_setting'; end if;
    if p_id='language' and p_data->>'value' not in ('system','zh','en') then raise exception 'invalid_language'; end if;
    if p_id='haptics' and p_data->>'value' not in ('true','false') then raise exception 'invalid_haptics'; end if;
  elsif p_kind = 'order' then
    if p_id <> 'projects' or jsonb_typeof(p_data->'ids') is distinct from 'array'
      or (p_data - 'ids') <> '{}'::jsonb then raise exception 'invalid_order'; end if;
    if exists(select 1 from jsonb_array_elements_text(p_data->'ids') a(id)
      where not exists(select 1 from public.counter_projects p where p.user_id=u and p.id=a.id::uuid))
      or (select count(*) from jsonb_array_elements_text(p_data->'ids')) <>
         (select count(distinct v) from jsonb_array_elements_text(p_data->'ids') a(v)) then raise exception 'invalid_order_members'; end if;
  elsif p_kind = 'session' then
    perform p_id::uuid;
    if not exists(select 1 from public.counter_projects where user_id=u and id=(p_data->>'project_id')::uuid)
      then raise exception 'invalid_session_project'; end if;
  end if;
  req := jsonb_build_object('kind',p_kind,'id',p_id,'base',p_expected_revision,'data',p_data);
  insert into public.counter_sync_heads(user_id) values(u) on conflict do nothing;
  perform 1 from public.counter_sync_heads where user_id=u for update;
  select * into receipt from public.counter_mutation_receipts where user_id=u and request_id=p_request_id;
  if found then
    if receipt.request <> req then raise exception 'request_uuid_reused'; end if;
    return receipt.response;
  end if;
  if p_kind='project' then
    select revision,data into old_rev,old_data from public.counter_projects where user_id=u and id=p_id::uuid;
  else
    select revision,data into old_rev,old_data from public.counter_documents where user_id=u and kind=p_kind and id=p_id;
  end if;
  if coalesce(old_rev,0) <> p_expected_revision then
    return jsonb_build_object('status','conflict','reason','revision_changed',
      'revision',coalesce(old_rev,0),'remote',old_data);
  end if;
  -- A deleted project cannot be resurrected by an outdated edit; restore is a separate future action.
  if p_kind='project' and old_data->>'deleted_at' is not null and
    (p_data->>'deleted_at') is distinct from (old_data->>'deleted_at') then
    return jsonb_build_object('status','conflict','reason','project_deleted','remote',old_data);
  end if;
  update public.counter_sync_heads set revision=revision+1 where user_id=u returning revision into rev;
  if p_kind='project' then
    insert into public.counter_projects(user_id,id,data,revision) values(u,p_id::uuid,p_data,rev)
      on conflict(user_id,id) do update set data=excluded.data,revision=excluded.revision,updated_at=clock_timestamp();
  else
    insert into public.counter_documents(user_id,kind,id,data,revision) values(u,p_kind,p_id,p_data,rev)
      on conflict(user_id,kind,id) do update set data=excluded.data,revision=excluded.revision,updated_at=clock_timestamp();
  end if;
  insert into public.counter_change_feed values(u,rev,p_kind,p_id,
    jsonb_build_object('user_id',u,'id',p_id,'data',p_data,'revision',rev));
  result := jsonb_build_object('status','accepted','revision',rev);
  insert into public.counter_mutation_receipts(user_id,request_id,request,response) values(u,p_request_id,req,result);
  return result;
end $$;

create function public.counter_pull(p_after bigint default 0, p_limit integer default 200)
returns setof public.counter_change_feed language sql stable security invoker set search_path = '' as $$
  select * from public.counter_change_feed where user_id=auth.uid() and revision > greatest(p_after,0)
  order by revision limit least(greatest(p_limit,1),500)
$$;
create view public.counter_totals with (security_invoker=true) as
  select user_id, project_id, sum(delta) as event_balance from public.counter_events group by user_id,project_id;
grant select on public.counter_totals to authenticated;
revoke all on function public.counter_push_event(jsonb) from public,anon;
revoke all on function public.counter_put_document(text,text,bigint,jsonb,uuid) from public,anon;
revoke all on function public.counter_pull(bigint,integer) from public,anon;
grant execute on function public.counter_push_event(jsonb) to authenticated;
grant execute on function public.counter_put_document(text,text,bigint,jsonb,uuid) to authenticated;
grant execute on function public.counter_pull(bigint,integer) to authenticated;

-- Private immutable image objects: user UUID / project UUID / asset UUID.ext
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('counter-images','counter-images',false,20971520,array['image/jpeg','image/png','image/webp']);
create policy counter_image_read on storage.objects for select to authenticated
using(bucket_id='counter-images' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy counter_image_insert on storage.objects for insert to authenticated
with check(bucket_id='counter-images' and (storage.foldername(name))[1]=(select auth.uid())::text
  and exists(select 1 from public.counter_projects p where p.user_id=(select auth.uid())
    and p.id::text=(storage.foldername(name))[2]));
-- No UPDATE/DELETE policy: create a new asset UUID on replacement. GC is a later server task.
commit;
