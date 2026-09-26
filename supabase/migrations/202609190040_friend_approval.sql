begin;
alter table public.chat_privacy add column if not exists require_friend_approval boolean not null default false;
create or replace function public.chat_friend_setting_v1(p_value boolean default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_value is not null then
  insert into public.chat_privacy(user_id,require_friend_approval) values(actor,p_value)
  on conflict(user_id) do update set require_friend_approval=excluded.require_friend_approval,updated_at=now();
 end if;
 return jsonb_build_object('require_friend_approval',coalesce((select require_friend_approval from public.chat_privacy where user_id=actor),false));
end $$;
revoke all on function public.chat_friend_setting_v1(boolean) from public,anon;
grant execute on function public.chat_friend_setting_v1(boolean) to authenticated;

create or replace function public.chat_auto_accept_friend() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='pending' and not coalesce((select require_friend_approval from public.chat_privacy where user_id=new.receiver_id),false) then
  if exists(select 1 from public.chat_blocks where (user_id=new.sender_id and blocked_id=new.receiver_id) or (user_id=new.receiver_id and blocked_id=new.sender_id)) then raise exception 'CHAT_BLOCKED'; end if;
  insert into public.chat_friends(user_id,friend_id) values(new.sender_id,new.receiver_id),(new.receiver_id,new.sender_id)
   on conflict(user_id,friend_id) do update set deleted_at=null;
  new.state:='accepted';
 end if;
 return new;
end $$;
revoke all on function public.chat_auto_accept_friend() from public,anon,authenticated;
create or replace trigger chat_friend_auto_accept before insert or update on public.chat_friend_requests
 for each row execute function public.chat_auto_accept_friend();
-- Existing pending requests stay pending; changing a setting does not process old requests.
notify pgrst,'reload schema';
commit;
