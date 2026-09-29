-- Admin-to-user file broadcast. Independent of the jieyuan (结缘) level system:
-- app_broadcast_levels only gates broadcast targeting, nothing else.
--
-- Delivery model: one admin_broadcasts row per send, one denormalized
-- admin_broadcast_recipients row per target user (so a single Realtime
-- subscription on that table, filtered by user_id via RLS, is enough for a
-- recipient's own device to see it — no join needed at read time). Files are
-- either a fresh upload to the 'broadcast-files' bucket (storage_path) or a
-- reused https URL, e.g. an existing app_releases.download_url (download_url).
-- Exactly one of the two is set: no duplicate storage of the same APK.
begin;

create table if not exists public.app_broadcast_levels (
  user_id uuid primary key references auth.users(id) on delete cascade,
  level integer not null default 1 check (level between 1 and 5),
  updated_at timestamptz not null default now()
);
alter table public.app_broadcast_levels enable row level security;
revoke all on public.app_broadcast_levels from public,anon,authenticated;

create table if not exists public.admin_broadcasts (
  id uuid primary key default gen_random_uuid(),
  actor uuid not null references auth.users(id),
  title text not null default '' check (char_length(title) <= 200),
  note text not null default '' check (char_length(note) <= 2000),
  file_name text not null check (char_length(file_name) between 1 and 255),
  file_size bigint not null check (file_size between 1 and 5368709120),
  sha256 text check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path text,
  download_url text check (download_url is null or download_url ~ '^https://[^/[:space:]]+/'),
  target_type text not null check (target_type in ('all','users','level')),
  target_level integer check (target_level between 1 and 5),
  recipient_count integer not null default 0,
  created_at timestamptz not null default now(),
  check ((storage_path is not null) <> (download_url is not null))
);
alter table public.admin_broadcasts enable row level security;
revoke all on public.admin_broadcasts from public,anon,authenticated;

create table if not exists public.admin_broadcast_recipients (
  broadcast_id uuid not null references public.admin_broadcasts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null default '',
  note text not null default '',
  file_name text not null,
  file_size bigint not null,
  sha256 text,
  storage_path text,
  download_url text,
  read_at timestamptz,
  downloaded_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (broadcast_id, user_id)
);
create index if not exists admin_broadcast_recipients_user on public.admin_broadcast_recipients(user_id, created_at desc);
alter table public.admin_broadcast_recipients enable row level security;
-- No revoke here: keep default grants so Realtime (which evaluates RLS as
-- the subscriber's own "authenticated" role) can watch this table, same as
-- chat_messages. Only a recipient's own rows are visible; all writes still
-- go through the security-definer RPCs below, since no insert/update policy
-- exists for authenticated.
drop policy if exists admin_broadcast_recipients_read on public.admin_broadcast_recipients;
create policy admin_broadcast_recipients_read on public.admin_broadcast_recipients
  for select to authenticated using (user_id = auth.uid());

insert into storage.buckets(id,name,public,file_size_limit)
  values('broadcast-files','broadcast-files',false,5368709120) on conflict(id) do nothing;

create or replace function public.broadcast_file_readable(p_name text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.admin_broadcast_recipients r
    where r.storage_path=p_name and r.user_id=auth.uid())
$$;
revoke all on function public.broadcast_file_readable(text) from public;
grant execute on function public.broadcast_file_readable(text) to authenticated;
drop policy if exists broadcast_file_download on storage.objects;
create policy broadcast_file_download on storage.objects for select to authenticated using(
  bucket_id='broadcast-files' and public.broadcast_file_readable(name)
);

-- Admin side. service_role only: the admin app connects with the service
-- key and calls this directly, same pattern as huideng_admin_releases /
-- huideng_admin_jieyuan. Every write is idempotent on (actor,request_id)
-- and audit-logged.
create or replace function public.huideng_admin_broadcast(actor uuid, action text, payload jsonb, request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare
  role_name text; result jsonb; previous admin_private.requests;
  target uuid; lvl integer;
  bid uuid; v_storage_path text; v_download_url text; v_file_name text; v_title text; v_note text;
  v_target_type text; v_target_level integer; v_size bigint; v_sha256 text; n_recipients integer; n_requested integer;
begin
  select role into role_name from admin_private.members where user_id=actor and enabled;
  if role_name is null or role_name not in ('super_admin','admin') then raise exception 'forbidden' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text,76));
  select * into previous from admin_private.requests r where r.actor=huideng_admin_broadcast.actor and r.request_id=huideng_admin_broadcast.request_id;
  if found then
    if previous.action<>action or previous.payload<>payload then raise exception 'request_conflict'; end if;
    return previous.result;
  end if;

  if action='levels.get' then
    target:=(payload->>'user_id')::uuid;
    if target is null then raise exception 'invalid_input'; end if;
    result:=jsonb_build_object('user_id',target,
      'level',coalesce((select level from public.app_broadcast_levels where user_id=target),1));

  elsif action='levels.set' then
    target:=(payload->>'user_id')::uuid;
    lvl:=(payload->>'level')::integer;
    if target is null or lvl not between 1 and 5 then raise exception 'invalid_input'; end if;
    insert into public.app_broadcast_levels(user_id,level) values(target,lvl)
      on conflict(user_id) do update set level=excluded.level, updated_at=now();
    result:=jsonb_build_object('user_id',target,'level',lvl);

  elsif action='send' then
    v_storage_path:=nullif(payload->>'storage_path','');
    v_download_url:=nullif(payload->>'download_url','');
    v_file_name:=payload->>'file_name';
    v_title:=coalesce(payload->>'title','');
    v_note:=coalesce(payload->>'note','');
    v_target_type:=payload->>'target_type';
    v_target_level:=(payload->>'target_level')::integer;
    v_sha256:=lower(nullif(payload->>'sha256',''));
    if v_target_type not in ('all','users','level') then raise exception 'invalid_target'; end if;
    if (v_storage_path is null) = (v_download_url is null) then raise exception 'invalid_file_reference'; end if;
    if v_file_name is null or char_length(v_file_name) not between 1 and 255 then raise exception 'invalid_file_name'; end if;
    if v_storage_path is not null then
      select (o.metadata->>'size')::bigint into v_size from storage.objects o
        where o.bucket_id='broadcast-files' and o.name=v_storage_path;
      if v_size is null then raise exception 'file_missing'; end if;
    else
      v_size:=(payload->>'file_size')::bigint;
      if v_size is null or v_size not between 1 and 5368709120 then raise exception 'invalid_file_size'; end if;
    end if;

    bid:=gen_random_uuid();
    insert into public.admin_broadcasts(id,actor,title,note,file_name,file_size,sha256,storage_path,download_url,target_type,target_level)
      values(bid,actor,v_title,v_note,v_file_name,v_size,v_sha256,v_storage_path,v_download_url,v_target_type,v_target_level);

    if v_target_type='all' then
      insert into public.admin_broadcast_recipients(broadcast_id,user_id,title,note,file_name,file_size,sha256,storage_path,download_url)
      select bid,u.id,v_title,v_note,v_file_name,v_size,v_sha256,v_storage_path,v_download_url
      from auth.users u where not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<now());
    elsif v_target_type='users' then
      if jsonb_typeof(payload->'target_ids') is distinct from 'array'
        or jsonb_array_length(payload->'target_ids') not between 1 and 5000 then raise exception 'invalid_targets'; end if;
      select count(*) into n_requested from (select distinct value from jsonb_array_elements_text(payload->'target_ids')) x;
      insert into public.admin_broadcast_recipients(broadcast_id,user_id,title,note,file_name,file_size,sha256,storage_path,download_url)
      select bid,x.id,v_title,v_note,v_file_name,v_size,v_sha256,v_storage_path,v_download_url
      from (select distinct (value)::uuid as id from jsonb_array_elements_text(payload->'target_ids')) x
      join auth.users u on u.id=x.id and (u.banned_until is null or u.banned_until<now());
    else
      if v_target_level is null or v_target_level not between 1 and 5 then raise exception 'invalid_level'; end if;
      insert into public.admin_broadcast_recipients(broadcast_id,user_id,title,note,file_name,file_size,sha256,storage_path,download_url)
      select bid,u.id,v_title,v_note,v_file_name,v_size,v_sha256,v_storage_path,v_download_url
      from auth.users u
      where not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<now())
        and coalesce((select level from public.app_broadcast_levels where user_id=u.id),1)=v_target_level;
    end if;

    select count(*) into n_recipients from public.admin_broadcast_recipients where broadcast_id=bid;
    update public.admin_broadcasts set recipient_count=n_recipients where id=bid;
    result:=jsonb_build_object('broadcast_id',bid,'recipient_count',n_recipients,'target_type',v_target_type,
      'failed',case when v_target_type='users' then greatest(n_requested-n_recipients,0) else 0 end);

  elsif action='list' then
    result:=jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from (
      select b.*, (select count(*) from public.admin_broadcast_recipients r where r.broadcast_id=b.id and r.read_at is not null) read_count,
        (select count(*) from public.admin_broadcast_recipients r where r.broadcast_id=b.id and r.downloaded_at is not null) downloaded_count
      from public.admin_broadcasts b order by b.created_at desc limit 200) t),'[]'));

  elsif action='detail' then
    target:=(payload->>'broadcast_id')::uuid;
    result:=jsonb_build_object(
      'broadcast',(select to_jsonb(b) from public.admin_broadcasts b where b.id=target),
      'recipients',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'read_at',r.read_at,'downloaded_at',r.downloaded_at,'created_at',r.created_at) order by r.created_at)
        from public.admin_broadcast_recipients r where r.broadcast_id=target),'[]'));

  else raise exception 'invalid_action';
  end if;

  insert into admin_private.audit_logs(actor,action,target,after_data) values(actor,action,coalesce(bid,target)::text,payload);
  insert into admin_private.requests(actor,request_id,action,payload,result) values(actor,request_id,action,payload,result);
  return result;
end $$;
revoke all on function public.huideng_admin_broadcast(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.huideng_admin_broadcast(uuid,text,jsonb,uuid) to service_role;

-- User side: authenticated only, own rows only.
create or replace function public.broadcast_inbox_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid(); target uuid; result jsonb; since timestamptz;
begin
  if actor is null then raise exception 'login_required'; end if;
  if p_action='list' then
    since:=nullif(p_data->>'since','')::timestamptz;
    result:=jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from (
      select broadcast_id,title,note,file_name,file_size,sha256,storage_path,download_url,read_at,downloaded_at,created_at
      from public.admin_broadcast_recipients
      where user_id=actor and (since is null or created_at>since)
      order by created_at desc limit least(coalesce((p_data->>'limit')::integer,100),200)) r),'[]'));
    return result;
  elsif p_action='mark_read' then
    target:=(p_data->>'broadcast_id')::uuid;
    update public.admin_broadcast_recipients set read_at=now() where broadcast_id=target and user_id=actor and read_at is null;
    return '{}'::jsonb;
  elsif p_action='mark_downloaded' then
    target:=(p_data->>'broadcast_id')::uuid;
    update public.admin_broadcast_recipients set downloaded_at=now() where broadcast_id=target and user_id=actor and downloaded_at is null;
    return '{}'::jsonb;
  else raise exception 'invalid_action';
  end if;
end $$;
revoke all on function public.broadcast_inbox_v1(text,jsonb) from public;
grant execute on function public.broadcast_inbox_v1(text,jsonb) to authenticated;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
     and not exists(select 1 from pg_publication_tables
       where pubname='supabase_realtime' and schemaname='public' and tablename='admin_broadcast_recipients') then
    alter publication supabase_realtime add table public.admin_broadcast_recipients;
  end if;
end $$;

notify pgrst,'reload schema';
commit;
