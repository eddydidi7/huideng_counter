-- Chat file bytes stay on the DataChannel. Only signalling is stored here.
begin;
alter table public.chat_transfers drop constraint if exists chat_transfers_size_check;
alter table public.chat_transfers add constraint chat_transfers_size_check
  check (size between 1 and 5368709120);
alter table public.chat_transfers add column if not exists protocol integer not null default 1;

create or replace function public.chat_transfer_v2(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid := auth.uid();
  d uuid := (p_data->>'device_id')::uuid;
  t public.chat_transfers;
  result jsonb;
begin
  if actor is null or d is null or not exists(select 1 from auth.users
    where id=actor and (banned_until is null or banned_until<now())) then
    raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501';
  end if;
  if p_action='offer' then
    result := public.chat_live_v1('offer', p_data);
    update public.chat_transfers set protocol=2, expires_at=now()+interval '7 days'
      where id=(p_data->>'id')::uuid and sender_id=actor;
    return result;
  end if;
  select * into t from public.chat_transfers where id=(p_data->>'id')::uuid for update;
  if t.id is null or t.protocol<>2 or actor not in(t.sender_id,t.receiver_id)
    or not public.chat_member(t.room_id) then raise exception 'TRANSFER_DENIED' using errcode='42501'; end if;
  if exists(select 1 from public.chat_blocks where
    (user_id=t.sender_id and blocked_id=t.receiver_id) or
    (user_id=t.receiver_id and blocked_id=t.sender_id)) then raise exception 'CHAT_BLOCKED'; end if;
  if exists(select 1 from public.chat_rooms where id=t.room_id and kind='direct')
    and not public.chat_can_contact(t.sender_id,t.receiver_id) then
    raise exception 'CHAT_STRANGERS_DISABLED';
  end if;
  if p_action='restart' then
    if actor=t.sender_id and d=t.sender_device and t.state='complete' then
      return jsonb_build_object('state','complete');
    end if;
    if actor<>t.sender_id or d<>t.sender_device or t.state not in('offered','accepted')
      or t.expires_at<now() then raise exception 'TRANSFER_UNAVAILABLE'; end if;
    delete from public.chat_transfer_signals where transfer_id=t.id;
    update public.chat_transfers set state='offered',receiver_device=null,
      expires_at=now()+interval '7 days' where id=t.id;
    return '{}'::jsonb;
  end if;
  result := public.chat_live_v1(p_action,p_data);
  if p_action='accept' then
    update public.chat_transfers set expires_at=now()+interval '7 days' where id=t.id;
  end if;
  return result;
end $$;
revoke all on function public.chat_transfer_v2(text,jsonb) from public,anon;
grant execute on function public.chat_transfer_v2(text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
