begin;
-- Additive configuration: existing groups allow members to invite by default.
alter table public.chat_group_settings add column if not exists managers_invite_only boolean not null default false;
alter table public.chat_messages add column if not exists is_system boolean not null default false;

create or replace function public.group_invite_v1(p_group uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); target uuid; added integer:=0; actor_name text; target_name text;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 -- Lock the room to serialize invitations and capacity enforcement.
 perform 1 from public.chat_rooms where id=p_group and kind='group' for update;
 if not found or not public.chat_member(p_group) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 if coalesce((select managers_invite_only from public.chat_group_settings where group_id=p_group),false)
   and not public.group_manager(p_group) then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
 if p_users is null or cardinality(p_users) not between 1 and 100 then raise exception 'CHAT_INVALID_USERS'; end if;
 select nickname into actor_name from public.chat_profiles where user_id=actor;
 for target in select distinct unnest(p_users) loop
   if target is null or not exists(select 1 from public.chat_profiles where user_id=target) or not exists(select 1 from auth.users where id=target and (banned_until is null or banned_until<now())) then raise exception 'CHAT_INVALID_USER'; end if;
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

-- Reuse current membership/manager/capacity rules. No direct client table writes.
create or replace function public.group_manage_v2(p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); rid uuid:=(p_data->>'room_id')::uuid; r public.chat_rooms;
 new_id uuid; label text; actor_name text; users uuid[]; result jsonb;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 select * into r from public.chat_rooms where id=rid for update;
 if not found or not public.chat_member(rid) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 if p_action='info' then
  return jsonb_build_object('title',r.title,'can_rename',r.kind='group' and public.group_manager(rid));
 elsif p_action='rename' then
  if r.kind<>'group' or not public.group_manager(rid) then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
  label:=btrim(p_data->>'title');
  if label is null or length(label) not between 1 and 80 then raise exception 'CHAT_INVALID_NAME'; end if;
  if label is distinct from r.title then
   select nickname into actor_name from public.chat_profiles where user_id=actor;
   update public.chat_rooms set title=label,updated_at=clock_timestamp() where id=rid;
   insert into public.chat_messages(id,room_id,sender_id,body,is_system) values(gen_random_uuid(),rid,actor,coalesce(actor_name,'学友')||'将群聊名称修改为“'||label||'”',true);
  end if;
  return jsonb_build_object('title',label);
 elsif p_action='from_direct' then
  if r.kind<>'direct' then raise exception 'CHAT_DIRECT_REQUIRED'; end if;
  new_id:=(p_data->>'id')::uuid;
  if new_id is null then raise exception 'CHAT_INVALID_USERS'; end if;
  perform pg_advisory_xact_lock(hashtextextended(new_id::text,61));
  if exists(select 1 from public.chat_rooms where id=new_id and kind='group' and owner_id=actor) then return jsonb_build_object('id',new_id); end if;
  if jsonb_typeof(p_data->'users') is distinct from 'array' or jsonb_array_length(p_data->'users') not between 1 and 100 then raise exception 'CHAT_INVALID_USERS'; end if;
  select array_agg(distinct value::uuid) into users from jsonb_array_elements_text(p_data->'users');
  if not exists(select 1 from unnest(users) u where not exists(select 1 from public.chat_members where room_id=rid and user_id=u and left_at is null)) then raise exception 'CHAT_NO_NEW_MEMBERS'; end if;
  select array_agg(distinct u) into users from (select unnest(users) u union select user_id from public.chat_members where room_id=rid and left_at is null) t where u<>actor;
  if (select count(*) from public.chat_rooms where kind='group' and owner_id=actor and created_at>now()-interval '1 hour')>=10 then raise exception 'CHAT_RATE_LIMIT'; end if;
  label:=coalesce(nullif(btrim(p_data->>'title'),''),'新群聊');
  if length(label)>80 then raise exception 'CHAT_INVALID_NAME'; end if;
  insert into public.chat_rooms(id,kind,title,owner_id) values(new_id,'group',label,actor);
  insert into public.chat_members(room_id,user_id) values(new_id,actor);
  -- The original peer plus 100 selected users can exceed one invitation batch.
  result:=public.group_invite_v1(new_id,users[1:100]);
  if cardinality(users)>100 then result:=public.group_invite_v1(new_id,users[101:200]); end if;
  return jsonb_build_object('id',new_id);
 end if;
 raise exception 'CHAT_INVALID_ACTION';
end $$;
revoke all on function public.group_manage_v2(text,jsonb) from public,anon;
grant execute on function public.group_manage_v2(text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
