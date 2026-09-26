-- 文件传输助手: the same account moves files between its own devices
-- (Android <-> Windows). The server only authenticates, lists the account's
-- devices and relays WebRTC signalling. File bytes never touch Supabase:
-- no Storage bucket, no file column. Additive; existing chat P2P untouched.
begin;

create table if not exists public.user_devices (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  name text not null default '' check (char_length(name) <= 60),
  platform text not null default '' check (char_length(platform) <= 20),
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

-- size is bigint (64-bit). 1 TiB ceiling; the product minimum is 5 GB.
create table if not exists public.device_transfers (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  sender_device uuid not null,
  receiver_device uuid not null,
  name text not null check (char_length(name) between 1 and 255),
  size bigint not null check (size between 1 and 1099511627776),
  block_size integer not null check (block_size between 65536 and 16777216),
  state text not null default 'offered' check (state in ('offered','accepted','complete','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  check (sender_device <> receiver_device)
);
create index if not exists device_transfers_receiver on public.device_transfers(user_id, receiver_device, state);

create table if not exists public.device_transfer_signals (
  seq bigint generated always as identity primary key,
  transfer_id uuid not null references public.device_transfers(id) on delete cascade,
  from_device uuid not null,
  nonce uuid not null,
  payload jsonb not null check (octet_length(payload::text) <= 65536),
  created_at timestamptz not null default now(),
  unique (transfer_id, from_device, nonce)
);
create index if not exists device_transfer_signals_poll on public.device_transfer_signals(transfer_id, seq);

alter table public.user_devices enable row level security;
alter table public.device_transfers enable row level security;
alter table public.device_transfer_signals enable row level security;
revoke all on public.user_devices, public.device_transfers, public.device_transfer_signals from public, anon, authenticated;

create or replace function public.device_transfer_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  actor uuid := auth.uid();
  d uuid := nullif(p_data->>'device_id','')::uuid;
  t public.device_transfers;
  other uuid;
begin
  if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until < now())) then
    raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or octet_length(p_data::text) > 70000 then
    raise exception 'INVALID_INPUT';
  end if;
  if d is null then raise exception 'DEVICE_REQUIRED'; end if;

  if p_action = 'heartbeat' then
    perform pg_advisory_xact_lock(hashtextextended('device:'||actor::text, 73));
    if not exists(select 1 from public.user_devices where user_id=actor and device_id=d)
       and (select count(*) from public.user_devices where user_id=actor) >= 20 then
      -- Forget the longest-unused device rather than refusing a new one.
      delete from public.user_devices where (user_id, device_id) in (
        select user_id, device_id from public.user_devices where user_id=actor order by last_seen limit 1);
    end if;
    insert into public.user_devices(user_id, device_id, name, platform, last_seen)
      values (actor, d, left(coalesce(p_data->>'name',''), 60), left(coalesce(p_data->>'platform',''), 20), now())
      on conflict (user_id, device_id) do update set
        name = excluded.name, platform = excluded.platform, last_seen = now();
    -- Housekeeping for this account only.
    update public.device_transfers set state='cancelled', updated_at=now()
      where user_id=actor and state in ('offered','accepted') and expires_at < now();
    delete from public.device_transfer_signals s using public.device_transfers x
      where s.transfer_id=x.id and x.user_id=actor and x.state in ('complete','cancelled')
        and x.updated_at < now() - interval '1 day';
    return jsonb_build_object(
      'devices', coalesce((select jsonb_agg(jsonb_build_object(
          'device_id', v.device_id, 'name', v.name, 'platform', v.platform,
          'online', v.last_seen > now() - interval '45 seconds', 'last_seen', v.last_seen,
          'self', v.device_id = d) order by v.last_seen desc)
        from public.user_devices v where v.user_id=actor), '[]'::jsonb),
      'offers', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from public.device_transfers x
        where x.user_id=actor and x.receiver_device=d and x.state='offered' and x.expires_at > now()), '[]'::jsonb),
      'active', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from public.device_transfers x
        where x.user_id=actor and d in (x.sender_device, x.receiver_device)
          and x.state='accepted' and x.expires_at > now()), '[]'::jsonb));
  end if;

  if p_action = 'offer' then
    other := nullif(p_data->>'receiver_device','')::uuid;
    if other is null or other = d
       or not exists(select 1 from public.user_devices where user_id=actor and device_id=d)
       or not exists(select 1 from public.user_devices where user_id=actor and device_id=other) then
      raise exception 'DEVICE_UNAVAILABLE';
    end if;
    if not exists(select 1 from public.user_devices where user_id=actor and device_id=other
        and last_seen > now() - interval '45 seconds') then
      raise exception 'PEER_OFFLINE';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('device:'||actor::text, 73));
    if (select count(*) from public.device_transfers where user_id=actor and created_at > now() - interval '1 minute') >= 20 then
      raise exception 'CHAT_RATE_LIMIT';
    end if;
    insert into public.device_transfers(id, user_id, sender_device, receiver_device, name, size, block_size)
      values ((p_data->>'id')::uuid, actor, d, other, p_data->>'name', (p_data->>'size')::bigint,
              coalesce((p_data->>'block_size')::integer, 4194304))
      on conflict (id) do nothing;
    return jsonb_build_object('id', p_data->>'id');
  end if;

  select * into t from public.device_transfers where id=(p_data->>'id')::uuid for update;
  if not found or t.user_id <> actor or d not in (t.sender_device, t.receiver_device) then
    raise exception 'TRANSFER_DENIED' using errcode='42501';
  end if;

  if p_action = 'accept' then
    if d <> t.receiver_device or t.state not in ('offered','accepted') or t.expires_at < now() then
      raise exception 'TRANSFER_UNAVAILABLE';
    end if;
    -- Accepted transfers stay resumable for 7 days.
    update public.device_transfers set state='accepted', updated_at=now(), expires_at=now()+interval '7 days' where id=t.id;
    return jsonb_build_object('state', 'accepted');
  end if;

  if p_action = 'cancel' then
    if t.state <> 'complete' then
      update public.device_transfers set state='cancelled', updated_at=now() where id=t.id;
    end if;
    return jsonb_build_object('state', 'cancelled');
  end if;

  if p_action = 'poll' then
    return jsonb_build_object(
      'state', case when t.expires_at < now() and t.state in ('offered','accepted') then 'expired' else t.state end,
      'peer_online', exists(select 1 from public.user_devices where user_id=actor
          and device_id = case when d = t.sender_device then t.receiver_device else t.sender_device end
          and last_seen > now() - interval '45 seconds'),
      'signals', coalesce((select jsonb_agg(to_jsonb(s) order by s.seq) from (
          select seq, payload from public.device_transfer_signals
          where transfer_id=t.id and from_device <> d and seq > coalesce((p_data->>'after')::bigint, 0)
          order by seq limit 200) s), '[]'::jsonb));
  end if;

  if p_action = 'signal' then
    if t.state <> 'accepted' or t.expires_at < now() then raise exception 'TRANSFER_UNAVAILABLE'; end if;
    if (select count(*) from public.device_transfer_signals where transfer_id=t.id) >= 20000 then
      raise exception 'CHAT_RATE_LIMIT';
    end if;
    insert into public.device_transfer_signals(transfer_id, from_device, nonce, payload)
      values (t.id, d, (p_data->>'nonce')::uuid, p_data->'payload') on conflict do nothing;
    update public.device_transfers set updated_at=now() where id=t.id;
    return '{}'::jsonb;
  end if;

  if p_action = 'complete' then
    if d <> t.receiver_device or t.state <> 'accepted' then raise exception 'TRANSFER_DENIED'; end if;
    update public.device_transfers set state='complete', updated_at=now() where id=t.id;
    return jsonb_build_object('state', 'complete');
  end if;

  raise exception 'UNKNOWN_ACTION';
end $$;
revoke all on function public.device_transfer_v1(text,jsonb) from public, anon;
grant execute on function public.device_transfer_v1(text,jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
