-- Two additive features on top of 202609250072 (group_admin) and
-- 202609210057 (chat_recall):
--  1. Group-level toggle "allow_member_friend_add" (default true) gating
--     friend requests initiated from the group members list; enforced in
--     chat_contacts_v1 itself, not just hidden client-side.
--  2. @mention support on chat_messages (mentions uuid[], mention_all bool),
--     enforced in chat_api_v1's 'send' path; @所有人 requires owner/admin.
--
-- Every patched function is handled by renaming the original aside and
-- creating a new same-named wrapper that delegates to it. Nothing here
-- depends on the exact whitespace/formatting of any existing function body
-- (an earlier draft of this migration tried textual find/replace on the
-- live function source and failed, because pg_get_functiondef() does not
-- reproduce the original migration file's line-wrapping byte for byte).
begin;

do $$
begin
  if to_regprocedure('public.group_admin_v1(text,jsonb)') is null then
    raise exception 'Missing prerequisite: group_admin_v1 (202609250072)';
  end if;
  if to_regprocedure('public.chat_contacts_v1(text,jsonb)') is null then
    raise exception 'Missing prerequisite: chat_contacts_v1 (202609170014)';
  end if;
  if to_regprocedure('public.chat_api_before_recall(text,jsonb)') is null then
    raise exception 'Missing prerequisite: chat_api_before_recall (202609210057)';
  end if;
end $$;

-- ---------------------------------------------------------------- schema
alter table public.chat_group_settings
  add column if not exists allow_member_friend_add boolean not null default true;
alter table public.chat_messages
  add column if not exists mentions uuid[] not null default '{}',
  add column if not exists mention_all boolean not null default false;

-- ------------------------------------------------ group_admin_v1 wrapper
-- Adds: a manager-level 'member_friend_add' toggle action, exposure of that
-- flag in 'overview'.settings, and honouring it inside 'settings' payloads.
-- Every other action is delegated to the untouched original unchanged.
do $$
begin
  if to_regprocedure('public.group_admin_before_friend_gate(text,jsonb)') is null then
    alter function public.group_admin_v1(text,jsonb) rename to group_admin_before_friend_gate;
  end if;
end $$;
revoke all on function public.group_admin_before_friend_gate(text,jsonb) from public,anon,authenticated;

create or replace function public.group_admin_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); gid uuid; my_role text; result jsonb;
begin
  gid := nullif(p_data->>'room_id','')::uuid;

  if p_action = 'member_friend_add' then
    if actor is null then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
    my_role := public.group_role_of(gid, actor);
    if my_role is null then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
    if my_role not in ('owner','admin') then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
    insert into public.chat_group_settings(group_id, allow_member_friend_add)
      values (gid, coalesce((p_data->>'enabled')::boolean, true))
      on conflict (group_id) do update set allow_member_friend_add = excluded.allow_member_friend_add;
    return jsonb_build_object('allow_member_friend_add', coalesce((p_data->>'enabled')::boolean, true));
  end if;

  result := public.group_admin_before_friend_gate(p_action, p_data);

  if p_action = 'overview' then
    return result || jsonb_build_object('settings',
      coalesce(result->'settings','{}'::jsonb) || jsonb_build_object('allow_member_friend_add',
        coalesce((select allow_member_friend_add from public.chat_group_settings where group_id=gid), true)));
  end if;

  -- The original 'settings' action already validated the caller is the
  -- owner (or it would have raised before returning here); this just
  -- applies the one extra field it doesn't know about yet.
  if p_action = 'settings' and p_data->'settings' ? 'allow_member_friend_add' then
    update public.chat_group_settings set allow_member_friend_add =
        coalesce((p_data->'settings'->>'allow_member_friend_add')::boolean, allow_member_friend_add)
      where group_id = gid;
  end if;

  return result;
end $$;
revoke all on function public.group_admin_v1(text,jsonb) from public,anon;
grant execute on function public.group_admin_v1(text,jsonb) to authenticated;

-- ------------------------------------------------ chat_contacts_v1: gate
-- friend requests that explicitly carry a group_id (i.e. initiated from
-- that group's member list). Requests made any other way (search, stranger
-- profile, existing entry points) are completely unaffected: they never
-- send group_id, so the wrapper proxies them straight through unchanged.
do $$
begin
  if to_regprocedure('public.chat_contacts_before_group_gate(text,jsonb)') is null then
    alter function public.chat_contacts_v1(text,jsonb) rename to chat_contacts_before_group_gate;
  end if;
end $$;
revoke all on function public.chat_contacts_before_group_gate(text,jsonb) from public,anon,authenticated;

create or replace function public.chat_contacts_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); gid uuid; target uuid; my_role text;
begin
  if p_action <> 'request' or not (p_data ? 'group_id') then
    return public.chat_contacts_before_group_gate(p_action, p_data);
  end if;
  if actor is null then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
  gid := nullif(p_data->>'group_id','')::uuid;
  target := nullif(p_data->>'user_id','')::uuid;
  my_role := public.group_role_of(gid, actor);
  if my_role is null or public.group_role_of(gid, target) is null then
    raise exception 'CHAT_NOT_MEMBER' using errcode='42501';
  end if;
  if my_role not in ('owner','admin')
     and not coalesce((select allow_member_friend_add from public.chat_group_settings where group_id=gid), true)
  then raise exception 'GROUP_FRIEND_ADD_DISABLED'; end if;
  return public.chat_contacts_before_group_gate('request', p_data);
end $$;
revoke all on function public.chat_contacts_v1(text,jsonb) from public,anon;
grant execute on function public.chat_contacts_v1(text,jsonb) to authenticated;

-- ------------------------------------------------ chat_api_v1 wrapper
-- 'send': adds @mention support (mentions/mention_all columns, validated
-- against room membership; @所有人 requires owner/admin).
-- 'rooms': merges each group room's own avatar_path in as
-- group_avatar_path, without touching the original room-listing query.
-- Every other action delegates to the untouched original unchanged.
do $$
begin
  if to_regprocedure('public.chat_api_before_mentions(text,jsonb)') is null then
    alter function public.chat_api_before_recall(text,jsonb) rename to chat_api_before_mentions;
  end if;
end $$;
revoke all on function public.chat_api_before_mentions(text,jsonb) from public,anon,authenticated;

create or replace function public.chat_api_before_recall(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); room uuid; r public.chat_rooms; m public.chat_messages;
        mention_ids uuid[]; mention_all_flag boolean; rooms_result jsonb;
begin
  if p_action = 'rooms' then
    rooms_result := public.chat_api_before_mentions('rooms', p_data);
    return coalesce((
      select jsonb_agg(
        case when e.value->>'kind' = 'group' then e.value || jsonb_build_object(
            'group_avatar_path',
            (select gs.avatar_path from public.chat_group_settings gs where gs.group_id=(e.value->>'id')::uuid))
          else e.value end
        order by e.ord)
      from jsonb_array_elements(rooms_result) with ordinality e(value, ord)
    ), '[]'::jsonb);
  end if;

  if p_action <> 'send' then
    return public.chat_api_before_mentions(p_action, p_data);
  end if;

  if actor is null then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
  room := nullif(p_data->>'room_id','')::uuid;
  if not public.chat_member(room) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
  select * into r from public.chat_rooms where id=room;

  select coalesce(array_agg(distinct value::uuid), '{}') into mention_ids
    from jsonb_array_elements_text(coalesce(p_data->'mentions','[]'::jsonb)) value;
  if cardinality(mention_ids) > 50 then raise exception 'CHAT_MENTION_LIMIT'; end if;
  if cardinality(mention_ids) > 0 and exists(
     select 1 from unnest(mention_ids) v
     where not exists(select 1 from public.chat_members where room_id=room and user_id=v and left_at is null)
  ) then raise exception 'CHAT_INVALID_MENTION'; end if;

  mention_all_flag := coalesce((p_data->>'mention_all')::boolean, false) and r.kind='group';
  if mention_all_flag and coalesce(public.group_role_of(room, actor), 'member') not in ('owner','admin') then
    raise exception 'CHAT_MENTION_ALL_DENIED';
  end if;

  -- Delegate the full original validation (body length, block checks, rate
  -- limit, attachment checks, idempotent-retry semantics) and insert.
  perform public.chat_api_before_mentions('send', p_data);
  update public.chat_messages set mentions=mention_ids, mention_all=mention_all_flag
    where id=nullif(p_data->>'id','')::uuid and room_id=room
    returning * into m;
  return to_jsonb(m);
end $$;
revoke all on function public.chat_api_before_recall(text,jsonb) from public,anon;
grant execute on function public.chat_api_before_recall(text,jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
