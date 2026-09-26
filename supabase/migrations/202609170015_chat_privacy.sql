-- Additive migration after 014. No existing messages or profiles are rewritten.
begin;
create table public.chat_privacy (
 user_id uuid primary key references auth.users(id),
 allow_strangers boolean not null default true,
 updated_at timestamptz not null default now()
);
alter table public.chat_privacy enable row level security;
revoke all on public.chat_privacy from anon,authenticated;
grant select on public.chat_privacy to authenticated;
create policy own_chat_privacy on public.chat_privacy for select to authenticated using(user_id=auth.uid());

create function public.chat_can_contact(sender uuid, recipient uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.chat_blocks where
 (user_id=sender and blocked_id=recipient) or (user_id=recipient and blocked_id=sender))
 and (coalesce((select allow_strangers from public.chat_privacy where user_id=recipient),true)
 or exists(select 1 from public.chat_friends where user_id=recipient and friend_id=sender and deleted_at is null))
$$;
revoke all on function public.chat_can_contact(uuid,uuid) from public,anon,authenticated;

create function public.chat_directory_v2(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); result jsonb; target uuid; cursor_id uuid;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)
 and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='privacy_set' then
  if jsonb_typeof(p_data->'allow_strangers') is distinct from 'boolean' then raise exception 'CHAT_INVALID_SETTING'; end if;
  insert into public.chat_privacy(user_id,allow_strangers) values(actor,(p_data->>'allow_strangers')::boolean)
  on conflict(user_id) do update set allow_strangers=excluded.allow_strangers,updated_at=now();
 elsif p_action='check' then
  target:=(p_data->>'user_id')::uuid;
  if target is null or target=actor or not exists(select 1 from auth.users where id=target and not coalesce(is_anonymous,false)
    and (banned_until is null or banned_until<now())) then raise exception 'CHAT_INVALID_USER'; end if;
  if not public.chat_can_contact(actor,target) then raise exception 'CHAT_STRANGERS_DISABLED' using errcode='42501'; end if;
  return jsonb_build_object('allowed',true);
 elsif p_action='directory' then
  cursor_id:=nullif(p_data->>'after','')::uuid;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.user_id),'[]') into result from (
   select u.id user_id,coalesce(p.nickname,'学友 '||left(u.id::text,8)) nickname,
    exists(select 1 from public.chat_friends f where f.user_id=actor and f.friend_id=u.id and f.deleted_at is null) is_friend
   from auth.users u left join public.chat_profiles p on p.user_id=u.id
   where not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<now())
    and (cursor_id is null or u.id>cursor_id)
    and not exists(select 1 from public.chat_blocks b where
     (b.user_id=actor and b.blocked_id=u.id) or (b.user_id=u.id and b.blocked_id=actor))
   order by u.id limit 100
  ) t;
  return result;
 elsif p_action<>'privacy' then raise exception 'CHAT_INVALID_ACTION';
 end if;
 return jsonb_build_object('allow_strangers',coalesce((select allow_strangers from public.chat_privacy where user_id=actor),true));
end $$;
revoke all on function public.chat_directory_v2(text,jsonb) from public,anon;
grant execute on function public.chat_directory_v2(text,jsonb) to authenticated;

-- Enforce on actual inserts too: older clients cannot bypass recipient privacy.
create function public.chat_guard_privacy() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.chat_rooms where id=new.room_id and kind='direct') and
 exists(select 1 from public.chat_members m where m.room_id=new.room_id and m.user_id<>new.sender_id
   and not public.chat_can_contact(new.sender_id,m.user_id)) then
  raise exception 'CHAT_STRANGERS_DISABLED' using errcode='42501';
 end if;
 return new;
end $$;
revoke all on function public.chat_guard_privacy() from public,anon,authenticated;
create trigger chat_message_privacy before insert on public.chat_messages for each row execute function public.chat_guard_privacy();
-- Apply the same recipient gate to new private P2P offers when 013 is installed.
do $$ begin
 if to_regclass('public.chat_transfers') is not null then
  execute 'create trigger chat_transfer_privacy before insert on public.chat_transfers for each row execute function public.chat_guard_privacy()';
 end if;
end $$;
notify pgrst,'reload schema';
commit;
