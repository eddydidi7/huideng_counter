-- Additive migration: authenticated presence and private P2P signalling only.
begin;
create table public.chat_presence (
 user_id uuid not null references auth.users(id), device_id uuid not null,
 seen_at timestamptz not null default now(), primary key(user_id,device_id)
);
create index chat_presence_seen on public.chat_presence(seen_at);
create table public.chat_transfers (
 id uuid primary key, room_id uuid not null references public.chat_rooms(id),
 sender_id uuid not null references auth.users(id), receiver_id uuid not null references auth.users(id),
 sender_device uuid not null, receiver_device uuid,
 name text not null check(length(name) between 1 and 255), size bigint not null check(size between 1 and 3000000000),
 state text not null default 'offered' check(state in ('offered','accepted','complete','cancelled')),
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '2 minutes',
 check(sender_id<>receiver_id)
);
create index chat_transfers_receiver on public.chat_transfers(receiver_id,state,expires_at);
create table public.chat_transfer_signals (
 seq bigint generated always as identity primary key,
 transfer_id uuid not null references public.chat_transfers(id), sender_id uuid not null references auth.users(id),
 nonce uuid not null, payload jsonb not null check(octet_length(payload::text)<=65536),
 created_at timestamptz not null default now(), unique(transfer_id,sender_id,nonce)
);
alter table public.chat_presence enable row level security;
alter table public.chat_transfers enable row level security;
alter table public.chat_transfer_signals enable row level security;
revoke all on public.chat_presence,public.chat_transfers,public.chat_transfer_signals from anon,authenticated;
-- No direct client table access. All operations validate account, membership and device.
create function public.chat_live_v1(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); d uuid:=(p_data->>'device_id')::uuid; t public.chat_transfers;
 target uuid; room uuid; result jsonb;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)
 and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='heartbeat' then
  if d is null then raise exception 'DEVICE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtext(actor::text));
  if not exists(select 1 from public.chat_presence where user_id=actor and device_id=d) and (select count(*) from public.chat_presence where user_id=actor and seen_at>now()-interval '45 seconds')>=16 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_presence values(actor,d,now()) on conflict(user_id,device_id) do update set seen_at=excluded.seen_at;
 elsif p_action='offline' then
  update public.chat_presence set seen_at='epoch' where user_id=actor and device_id=d;
  return '{}'::jsonb;
 end if;
 if p_action in ('heartbeat','status') then
  select jsonb_build_object(
   'online',coalesce((select jsonb_agg(distinct user_id) from public.chat_presence where seen_at>now()-interval '45 seconds'
     and (user_id in (select value::uuid from jsonb_array_elements_text(coalesce(p_data->'users','[]')) limit 300) or exists(select 1 from public.chat_members cm where cm.user_id=chat_presence.user_id and cm.left_at is null and public.chat_member(cm.room_id)))),'[]'::jsonb),
   'peers',coalesce((select jsonb_object_agg(m.room_id,m.user_id) from public.chat_members m join public.chat_rooms r on r.id=m.room_id
     where r.kind='direct' and m.user_id<>actor and m.left_at is null and public.chat_member(r.id)),'{}'::jsonb),
   'offers',coalesce((select jsonb_agg(to_jsonb(x)) from (select pending.*,p.nickname from public.chat_transfers pending join public.chat_profiles p on p.user_id=pending.sender_id
     where pending.receiver_id=actor and pending.state='offered' and pending.expires_at>now() and public.chat_member(pending.room_id)
     order by pending.created_at desc limit 20) x),'[]'::jsonb)) into result;
  return result;
 end if;
 if p_action='offer' then
  target:=(p_data->>'receiver_id')::uuid; room:=(p_data->>'room_id')::uuid;
  perform pg_advisory_xact_lock(hashtext(actor::text));
  if d is null or target=actor or not public.chat_member(room) or not exists(select 1 from public.chat_members where room_id=room and user_id=target and left_at is null) then raise exception 'CHAT_NOT_MEMBER'; end if;
  if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
  if not exists(select 1 from public.chat_presence where user_id=target and seen_at>now()-interval '45 seconds') then raise exception 'PEER_OFFLINE'; end if;
  if (select count(*) from public.chat_transfers where sender_id=actor and created_at>now()-interval '1 minute')>=10 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_transfers(id,room_id,sender_id,receiver_id,sender_device,name,size)
   values((p_data->>'id')::uuid,room,actor,target,d,p_data->>'name',(p_data->>'size')::bigint);
  return '{}'::jsonb;
 end if;
 select * into t from public.chat_transfers where id=(p_data->>'id')::uuid for update;
 if t.id is null or actor not in (t.sender_id,t.receiver_id) or not public.chat_member(t.room_id) then raise exception 'TRANSFER_DENIED' using errcode='42501'; end if;
 if exists(select 1 from public.chat_blocks where (user_id=t.sender_id and blocked_id=t.receiver_id) or (user_id=t.receiver_id and blocked_id=t.sender_id)) then raise exception 'CHAT_BLOCKED'; end if;
 if p_action='accept' then
  if actor<>t.receiver_id or t.state<>'offered' or t.expires_at<now() or d is null then raise exception 'TRANSFER_UNAVAILABLE'; end if;
  update public.chat_transfers set receiver_device=d,state='accepted',expires_at=now()+interval '24 hours' where id=t.id;
  return '{}'::jsonb;
 elsif p_action='cancel' then
  if t.state<>'complete' then update public.chat_transfers set state='cancelled' where id=t.id; end if;
  return '{}'::jsonb;
 end if;
 if d is null or (actor=t.sender_id and d<>t.sender_device) or (actor=t.receiver_id and d is distinct from t.receiver_device) then raise exception 'TRANSFER_DEVICE_DENIED'; end if;
 if p_action='poll' then
  return jsonb_build_object('state',case when t.expires_at<now() then 'expired' else t.state end,
   'signals',coalesce((select jsonb_agg(to_jsonb(s) order by s.seq) from (select seq,payload from public.chat_transfer_signals where transfer_id=t.id and sender_id<>actor and seq>coalesce((p_data->>'after')::bigint,0) order by seq limit 100) s),'[]'::jsonb));
 elsif p_action='signal' then
  if t.state<>'accepted' or t.expires_at<now() then raise exception 'TRANSFER_UNAVAILABLE'; end if;
  if (select count(*) from public.chat_transfer_signals where transfer_id=t.id)>=1000 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_transfer_signals(transfer_id,sender_id,nonce,payload) values(t.id,actor,(p_data->>'nonce')::uuid,p_data->'payload') on conflict do nothing;
 elsif p_action='complete' then
  if actor<>t.receiver_id or t.state<>'accepted' then raise exception 'TRANSFER_DENIED'; end if;
  update public.chat_transfers set state='complete' where id=t.id;
 else raise exception 'UNKNOWN_ACTION'; end if;
 return '{}'::jsonb;
end $$;
revoke all on function public.chat_live_v1(text,jsonb) from public;
grant execute on function public.chat_live_v1(text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;


