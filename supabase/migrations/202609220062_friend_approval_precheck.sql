-- The client needs the recipient policy before deciding whether to show the
-- optional verification-message editor. Actual request inserts remain guarded
-- by chat_auto_accept_friend, so an old/malicious client cannot bypass it.
begin;

create or replace function public.chat_directory_v2(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); result jsonb; target uuid; cursor_id uuid;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor
   and (banned_until is null or banned_until<now())) then
   raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501';
 end if;
 if p_action='privacy_set' then
  if jsonb_typeof(p_data->'allow_strangers') is distinct from 'boolean' then raise exception 'CHAT_INVALID_SETTING'; end if;
  insert into public.chat_privacy(user_id,allow_strangers) values(actor,(p_data->>'allow_strangers')::boolean)
  on conflict(user_id) do update set allow_strangers=excluded.allow_strangers,updated_at=now();
 elsif p_action='check' then
  target:=(p_data->>'user_id')::uuid;
  if target is null or target=actor or not exists(select 1 from auth.users where id=target
    and (banned_until is null or banned_until<now())) then raise exception 'CHAT_INVALID_USER'; end if;
  if not public.chat_can_contact(actor,target) then raise exception 'CHAT_STRANGERS_DISABLED' using errcode='42501'; end if;
  return jsonb_build_object(
    'allowed',true,
    'require_friend_approval',coalesce((select require_friend_approval from public.chat_privacy where user_id=target),false)
  );
 elsif p_action='directory' then
  cursor_id:=nullif(p_data->>'after','')::uuid;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.user_id),'[]') into result from (
   select u.id user_id,coalesce(p.nickname,'学友 '||left(u.id::text,8)) nickname,
    exists(select 1 from public.chat_friends f where f.user_id=actor and f.friend_id=u.id and f.deleted_at is null) is_friend
   from auth.users u left join public.chat_profiles p on p.user_id=u.id
   where (u.banned_until is null or u.banned_until<now())
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
notify pgrst,'reload schema';
commit;
