begin;
-- Additive only. Existing messages, members and friend permissions are preserved.
create table if not exists public.chat_qr_invites (
 room_id uuid primary key references public.chat_rooms(id),
 token uuid not null unique default gen_random_uuid(),
 expires_at timestamptz not null default now() + interval '7 days'
);
alter table public.chat_qr_invites enable row level security;
revoke all on public.chat_qr_invites from public, anon, authenticated;
create or replace function public.chat_qr_v1(p_action text, p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid := auth.uid(); room public.chat_rooms; invite public.chat_qr_invites; rid uuid;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<=now())) then raise exception 'CHAT_LOGIN_REQUIRED'; end if;
 if p_action in ('code','rotate') then
  rid := (p_data->>'room_id')::uuid;
 else
  if p_action not in ('resolve','join') then raise exception 'INVALID_ACTION'; end if;
  select room_id into rid from public.chat_qr_invites where token=(p_data->>'token')::uuid;
 end if;
 -- Serializes joins, refreshes and expiry checks on one group.
 select * into room from public.chat_rooms where id=rid and kind='group' for update;
 if not found then raise exception 'QR_UNAVAILABLE'; end if;
 if not exists(select 1 from auth.users where id=room.owner_id and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<=now())) then raise exception 'QR_UNAVAILABLE'; end if;
 if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=room.owner_id) or (user_id=room.owner_id and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
 select * into invite from public.chat_qr_invites where room_id=rid;
 if p_action in ('code','rotate') then
  if not public.chat_member(rid) then raise exception 'CHAT_FORBIDDEN'; end if;
  if p_action='rotate' or invite.room_id is null or invite.expires_at<=now() then
   if room.owner_id<>actor then raise exception 'ASK_GROUP_OWNER_FOR_QR'; end if;
   insert into public.chat_qr_invites(room_id) values(rid)
   on conflict(room_id) do update set token=gen_random_uuid(),expires_at=now()+interval '7 days'
   returning * into invite;
  end if;
  return jsonb_build_object('token',invite.token,'expires_at',invite.expires_at);
 end if;
 if invite.token is distinct from (p_data->>'token')::uuid or invite.expires_at<=now() then raise exception 'QR_EXPIRED'; end if;
 -- Removed/left users must be invited again by the owner, not bypass removal with a saved QR.
 if exists(select 1 from public.chat_members where room_id=rid and user_id=actor and left_at is not null) then raise exception 'ASK_GROUP_OWNER_TO_INVITE'; end if;
 if p_action='resolve' then return jsonb_build_object('title',room.title); end if;
 if not public.chat_member(rid) then
  if (select count(*) from public.chat_members where room_id=rid and left_at is null)>=100 then raise exception 'GROUP_FULL'; end if;
  insert into public.chat_members(room_id,user_id) values(rid,actor);
 end if;
 return jsonb_build_object('id',rid,'title',room.title,'kind','group','owner_id',room.owner_id);
end $$;
revoke all on function public.chat_qr_v1(text,jsonb) from public,anon;
grant execute on function public.chat_qr_v1(text,jsonb) to authenticated;
commit;
