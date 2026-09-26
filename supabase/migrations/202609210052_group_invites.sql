begin;
-- Additive configuration: existing groups allow members to invite by default.
alter table public.chat_group_settings add column if not exists managers_invite_only boolean not null default false;
alter table public.chat_messages add column if not exists is_system boolean not null default false;

create or replace function public.group_invite_v1(p_group uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); target uuid; added integer:=0; actor_name text; target_name text;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)
   and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 -- Lock the room to serialize invitations and capacity enforcement.
 perform 1 from public.chat_rooms where id=p_group and kind='group' for update;
 if not found or not public.chat_member(p_group) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 if coalesce((select managers_invite_only from public.chat_group_settings where group_id=p_group),false)
   and not public.group_manager(p_group) then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
 if p_users is null or cardinality(p_users) not between 1 and 100 then raise exception 'CHAT_INVALID_USERS'; end if;
 select nickname into actor_name from public.chat_profiles where user_id=actor;
 for target in select distinct unnest(p_users) loop
   if target is null or not exists(select 1 from auth.users where id=target and not coalesce(is_anonymous,false)
      and (banned_until is null or banned_until<now())) then raise exception 'CHAT_INVALID_USER'; end if;
   if exists(select 1 from public.chat_members where room_id=p_group and user_id=target and left_at is null) then continue; end if;
   if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
   insert into public.chat_members(room_id,user_id) values(p_group,target)
     on conflict(room_id,user_id) do update set left_at=null,joined_at=now();
   select nickname into target_name from public.chat_profiles where user_id=target;
   insert into public.chat_messages(id,room_id,sender_id,body,is_system)
     values(gen_random_uuid(),p_group,actor,coalesce(actor_name,'学友')||'邀请'||coalesce(target_name,'学友')||'加入了群聊',true);
   added:=added+1;
 end loop;
 if added>0 then update public.chat_rooms set updated_at=clock_timestamp() where id=p_group; end if;
 return jsonb_build_object('added',added);
end $$;
revoke all on function public.group_invite_v1(uuid,uuid[]) from public,anon;
grant execute on function public.group_invite_v1(uuid,uuid[]) to authenticated;
-- Clients have SELECT only on chat_messages; only trusted RPCs create system rows.
-- A muted member may still invite when group settings allow invitations.
create or replace function public.guard_group_message() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not new.is_system and auth.uid() is not null and not public.group_speak_allowed(new.room_id) then
   raise exception 'GROUP_MUTED' using errcode='42501';
 end if;
 return new;
end $$;
notify pgrst,'reload schema';
commit;
