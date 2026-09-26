-- Group administration: up to 10 admins, timed/permanent mutes, all-mute
-- exemptions, blacklist, join modes and approval, new-member mute, required
-- announcements, message moderation and pins, anti-spam limits, pinned files,
-- paged members/files/search, member group nicknames and an audit log.
--
-- Additive and non-destructive. Enforcement lives in triggers on the shared
-- tables, so every existing path (invite, QR, legacy RPCs, old app versions)
-- obeys the same rules. Personal recall (chat_api_v1 'recall') is unchanged.
begin;

do $$
begin
  if to_regprocedure('public.group_learning_v1(text,jsonb)') is null then
    raise exception 'Missing prerequisite: group_learning_v1 (202609180031)';
  end if;
  if to_regprocedure('public.group_invite_v1(uuid,uuid[])') is null then
    raise exception 'Missing prerequisite: group_invite_v1 (202609210061)';
  end if;
  if to_regclass('public.chat_attachment_retirements') is null then
    raise exception 'Missing prerequisite: chat_attachment_retirements (202609210057)';
  end if;
end $$;

-- ---------------------------------------------------------------- schema
alter table public.chat_group_settings
  add column if not exists join_mode text not null default 'open',
  add column if not exists allow_qr boolean not null default true,
  add column if not exists qr_valid_days integer not null default 7,
  add column if not exists joins_paused boolean not null default false,
  add column if not exists new_member_mute_minutes integer not null default 0,
  add column if not exists require_announcement_read boolean not null default false,
  add column if not exists allow_member_nickname boolean not null default true,
  add column if not exists spam_guard boolean not null default true,
  add column if not exists description text not null default '',
  add column if not exists avatar_path text;
do $$ begin
  alter table public.chat_group_settings add constraint chat_group_settings_join_mode
    check (join_mode in ('open','approval','invite'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.chat_group_settings add constraint chat_group_settings_limits check (
    qr_valid_days between 1 and 365 and new_member_mute_minutes between 0 and 10080
    and char_length(description) <= 500);
exception when duplicate_object then null; end $$;

alter table public.chat_group_roles
  add column if not exists nickname text,
  add column if not exists admin_remark text,
  add column if not exists exempt_all_mute boolean not null default false;
do $$ begin
  alter table public.chat_group_roles add constraint chat_group_roles_text_limits check (
    char_length(coalesce(nickname,'')) <= 40 and char_length(coalesce(admin_remark,'')) <= 80);
exception when duplicate_object then null; end $$;

alter table public.chat_messages add column if not exists moderated_by uuid references auth.users(id);
create index if not exists chat_messages_room_sender_time
  on public.chat_messages(room_id, sender_id, created_at desc);
create index if not exists chat_members_room_joined
  on public.chat_members(room_id, joined_at desc, user_id) where left_at is null;
alter table public.chat_group_files add column if not exists is_pinned boolean not null default false;
alter table public.chat_group_content add column if not exists popup boolean not null default false;

create table if not exists public.chat_group_bans (
  group_id uuid not null references public.chat_rooms(id),
  user_id uuid not null references auth.users(id),
  banned_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create table if not exists public.chat_group_join_requests (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.chat_rooms(id),
  user_id uuid not null references auth.users(id),
  inviter_id uuid references auth.users(id),
  message text not null default '' check (char_length(message) <= 200),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_by uuid references auth.users(id),
  decided_at timestamptz
);
create unique index if not exists chat_group_join_requests_pending
  on public.chat_group_join_requests(group_id, user_id) where status = 'pending';
create table if not exists public.chat_group_logs (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.chat_rooms(id),
  actor_id uuid references auth.users(id),
  action text not null,
  target_id uuid,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists chat_group_logs_group on public.chat_group_logs(group_id, id desc);
create table if not exists public.chat_group_pins (
  group_id uuid not null references public.chat_rooms(id),
  message_id uuid not null references public.chat_messages(id),
  pinned_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (group_id, message_id)
);
do $$
declare t text;
begin
  foreach t in array array['chat_group_bans','chat_group_join_requests','chat_group_logs','chat_group_pins'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public.group_role_of(p_group uuid, p_user uuid) returns text
language sql stable security definer set search_path=pg_catalog,public as $$
  select case
    when not exists(select 1 from public.chat_members m where m.room_id=p_group and m.user_id=p_user and m.left_at is null) then null
    when exists(select 1 from public.chat_rooms r where r.id=p_group and r.kind='group' and r.owner_id=p_user) then 'owner'
    when exists(select 1 from public.chat_group_roles g where g.group_id=p_group and g.user_id=p_user and g.role='admin') then 'admin'
    else 'member' end
$$;
revoke all on function public.group_role_of(uuid,uuid) from public, anon, authenticated;

-- Owner manages everyone but themself; admins manage ordinary members only.
create or replace function public.group_can_manage(p_group uuid, p_actor uuid, p_target uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select p_actor is distinct from p_target and case public.group_role_of(p_group, p_actor)
    when 'owner' then public.group_role_of(p_group, p_target) in ('admin','member')
    when 'admin' then public.group_role_of(p_group, p_target) = 'member'
    else false end
$$;
revoke all on function public.group_can_manage(uuid,uuid,uuid) from public, anon, authenticated;

create or replace function public.group_log(p_group uuid, p_action text, p_target uuid, p_detail jsonb default '{}')
returns void language sql security definer set search_path=pg_catalog,public as $$
  insert into public.chat_group_logs(group_id, actor_id, action, target_id, detail)
  values (p_group, auth.uid(), p_action, p_target, coalesce(p_detail, '{}'))
$$;
revoke all on function public.group_log(uuid,text,uuid,jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- limits and audit triggers
create or replace function public.group_admin_limit_guard() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.role = 'admin' and (tg_op = 'INSERT' or old.role is distinct from 'admin') then
    if (select count(*) from public.chat_group_roles g
        join public.chat_members m on m.room_id=g.group_id and m.user_id=g.user_id and m.left_at is null
        where g.group_id=new.group_id and g.role='admin' and g.user_id<>new.user_id) >= 10 then
      raise exception 'GROUP_ADMIN_LIMIT' using errcode='P0001';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.group_admin_limit_guard() from public, anon, authenticated;
drop trigger if exists group_admin_limit_guard on public.chat_group_roles;
create trigger group_admin_limit_guard before insert or update of role on public.chat_group_roles
  for each row execute function public.group_admin_limit_guard();

create or replace function public.group_roles_audit() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if coalesce(current_setting('huideng.group_quiet', true), '') = '1' then return null; end if;
  -- Role resets caused by leaving are not admin actions.
  if not exists(select 1 from public.chat_members where room_id=new.group_id and user_id=new.user_id and left_at is null) then
    return null;
  end if;
  if new.role is distinct from (case when tg_op='INSERT' then 'member' else old.role end) then
    perform public.group_log(new.group_id, case when new.role='admin' then 'set_admin' else 'unset_admin' end, new.user_id);
  end if;
  if new.muted_until is distinct from (case when tg_op='INSERT' then null else old.muted_until end) then
    perform public.group_log(new.group_id,
      case when new.muted_until is null or new.muted_until <= now() then 'unmute' else 'mute' end,
      new.user_id, jsonb_build_object('until', new.muted_until));
  end if;
  if new.exempt_all_mute is distinct from (case when tg_op='INSERT' then false else old.exempt_all_mute end) then
    perform public.group_log(new.group_id, 'exempt', new.user_id, jsonb_build_object('enabled', new.exempt_all_mute));
  end if;
  return null;
end $$;
revoke all on function public.group_roles_audit() from public, anon, authenticated;
drop trigger if exists group_roles_audit on public.chat_group_roles;
create trigger group_roles_audit after insert or update on public.chat_group_roles
  for each row execute function public.group_roles_audit();

create or replace function public.group_settings_audit() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare changed text[];
begin
  if tg_op='UPDATE' and new.all_muted is distinct from old.all_muted
     or tg_op='INSERT' and new.all_muted then
    perform public.group_log(new.group_id, 'all_mute', null, jsonb_build_object('enabled', new.all_muted));
  end if;
  select coalesce(array_agg(k), '{}') into changed
    from jsonb_each(to_jsonb(new)) n(k, v)
    where k not in ('group_id','all_muted')
      and (tg_op='INSERT' or v is distinct from to_jsonb(old)->k);
  if cardinality(changed) > 0 and tg_op='UPDATE' then
    perform public.group_log(new.group_id, 'settings', null, jsonb_build_object('fields', changed));
  end if;
  return null;
end $$;
revoke all on function public.group_settings_audit() from public, anon, authenticated;
drop trigger if exists group_settings_audit on public.chat_group_settings;
create trigger group_settings_audit after insert or update on public.chat_group_settings
  for each row execute function public.group_settings_audit();

create or replace function public.group_room_audit() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.kind='group' and new.title is distinct from old.title then
    perform public.group_log(new.id, 'rename', null, jsonb_build_object('from', old.title, 'to', new.title));
  end if;
  if new.kind='group' and new.owner_id is distinct from old.owner_id then
    perform public.group_log(new.id, 'transfer_owner', new.owner_id, jsonb_build_object('from', old.owner_id));
  end if;
  return null;
end $$;
revoke all on function public.group_room_audit() from public, anon, authenticated;
drop trigger if exists group_room_audit on public.chat_rooms;
create trigger group_room_audit after update of title, owner_id on public.chat_rooms
  for each row execute function public.group_room_audit();

create or replace function public.group_content_audit() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.kind <> 'announcement' then return null; end if;
  if tg_op='UPDATE' and new.deleted_at is not null and old.deleted_at is null then
    perform public.group_log(new.group_id, 'announcement_remove', null, jsonb_build_object('title', new.title));
  elsif tg_op='INSERT' or new.title is distinct from old.title or new.body is distinct from old.body
     or new.is_pinned is distinct from old.is_pinned or new.popup is distinct from old.popup then
    perform public.group_log(new.group_id, 'announcement', null, jsonb_build_object('title', new.title));
  end if;
  return null;
end $$;
revoke all on function public.group_content_audit() from public, anon, authenticated;
drop trigger if exists group_content_audit on public.chat_group_content;
create trigger group_content_audit after insert or update on public.chat_group_content
  for each row execute function public.group_content_audit();

-- ---------------------------------------------------------------- joining
-- Every route into a group (invite, QR, approval, legacy RPCs) passes here.
-- Trusted RPCs mark their route with the transaction-local setting
-- huideng.group_join: 'manager', 'approved' or 'member_invite'.
create or replace function public.group_join_guard() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.chat_rooms; s public.chat_group_settings;
  route text := coalesce(current_setting('huideng.group_join', true), '');
begin
  if new.left_at is not null then return new; end if;
  if tg_op='UPDATE' and old.left_at is null then return new; end if;
  select * into r from public.chat_rooms where id=new.room_id;
  if r.kind is distinct from 'group' or new.user_id = r.owner_id then return new; end if;
  if exists(select 1 from public.chat_group_bans where group_id=new.room_id and user_id=new.user_id) then
    raise exception 'GROUP_BANNED' using errcode='42501';
  end if;
  select * into s from public.chat_group_settings where group_id=new.room_id;
  if not found or route in ('manager','approved') then return new; end if;
  if s.joins_paused then raise exception 'GROUP_JOINS_PAUSED' using errcode='42501'; end if;
  if route = 'member_invite' then
    if s.join_mode = 'approval' then raise exception 'GROUP_APPROVAL_REQUIRED' using errcode='42501'; end if;
    return new;
  end if;
  -- Unmarked: QR / self-service join.
  if not s.allow_qr then raise exception 'GROUP_QR_DISABLED' using errcode='42501'; end if;
  if s.join_mode = 'invite' then raise exception 'GROUP_INVITE_ONLY' using errcode='42501'; end if;
  if s.join_mode = 'approval' then raise exception 'GROUP_APPROVAL_REQUIRED' using errcode='42501'; end if;
  return new;
end $$;
revoke all on function public.group_join_guard() from public, anon, authenticated;
drop trigger if exists group_join_guard on public.chat_members;
create trigger group_join_guard before insert or update of left_at on public.chat_members
  for each row execute function public.group_join_guard();

create or replace function public.group_after_membership() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.chat_rooms; minutes integer;
begin
  select * into r from public.chat_rooms where id=new.room_id;
  if r.kind is distinct from 'group' then return null; end if;
  if new.left_at is null and (tg_op='INSERT' or old.left_at is not null) then
    select new_member_mute_minutes into minutes from public.chat_group_settings where group_id=new.room_id;
    if coalesce(minutes, 0) > 0 and new.user_id <> r.owner_id then
      perform set_config('huideng.group_quiet', '1', true);
      insert into public.chat_group_roles(group_id, user_id, muted_until)
        values (new.room_id, new.user_id, now() + make_interval(mins => minutes))
        on conflict (group_id, user_id) do update set muted_until =
          greatest(coalesce(public.chat_group_roles.muted_until, now()), excluded.muted_until);
      perform set_config('huideng.group_quiet', '', true);
    end if;
  elsif tg_op='UPDATE' and new.left_at is not null and old.left_at is null
        and auth.uid() is distinct from new.user_id then
    perform public.group_log(new.room_id, 'remove', new.user_id);
  end if;
  return null;
end $$;
revoke all on function public.group_after_membership() from public, anon, authenticated;
drop trigger if exists group_after_membership on public.chat_members;
create trigger group_after_membership after insert or update of left_at on public.chat_members
  for each row execute function public.group_after_membership();

-- Invitations: managers always may; members only when allowed; in approval
-- mode a member's invitation becomes a pending request for managers.
create or replace function public.group_invite_v1(p_group uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); target uuid; added integer:=0; requested integer:=0; skipped integer:=0;
  actor_name text; target_name text; manager boolean; s public.chat_group_settings;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.chat_rooms where id=p_group and kind='group' for update;
 if not found or not public.chat_member(p_group) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 manager := public.group_manager(p_group);
 select * into s from public.chat_group_settings where group_id=p_group;
 if coalesce(s.managers_invite_only,false) and not manager then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
 if coalesce(s.joins_paused,false) and not manager then raise exception 'GROUP_JOINS_PAUSED' using errcode='42501'; end if;
 if p_users is null or cardinality(p_users) not between 1 and 100 then raise exception 'CHAT_INVALID_USERS'; end if;
 select nickname into actor_name from public.chat_profiles where user_id=actor;
 perform set_config('huideng.group_join', case when manager then 'manager' else 'member_invite' end, true);
 for target in select distinct unnest(p_users) loop
   if target is null or not exists(select 1 from public.chat_profiles where user_id=target) or not exists(select 1 from auth.users where id=target and (banned_until is null or banned_until<now())) then raise exception 'CHAT_INVALID_USER'; end if;
   if exists(select 1 from public.chat_members where room_id=p_group and user_id=target and left_at is null) then continue; end if;
   if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
   if exists(select 1 from public.chat_group_bans where group_id=p_group and user_id=target) then skipped:=skipped+1; continue; end if;
   if not manager and s.join_mode = 'approval' then
     insert into public.chat_group_join_requests(group_id,user_id,inviter_id)
       values(p_group,target,actor) on conflict do nothing;
     requested:=requested+1;
     continue;
   end if;
   insert into public.chat_members(room_id,user_id) values(p_group,target)
     on conflict(room_id,user_id) do update set left_at=null,joined_at=now();
   select nickname into target_name from public.chat_profiles where user_id=target;
   insert into public.chat_messages(id,room_id,sender_id,body,is_system)
     values(gen_random_uuid(),p_group,actor,coalesce(actor_name,'学友')||'邀请'||coalesce(target_name,'学友')||'加入了群聊',true);
   added:=added+1;
 end loop;
 perform set_config('huideng.group_join', '', true);
 if added>0 then update public.chat_rooms set updated_at=clock_timestamp() where id=p_group; end if;
 return jsonb_build_object('added',added,'requested',requested,'banned',skipped);
end $$;
revoke all on function public.group_invite_v1(uuid,uuid[]) from public,anon;
grant execute on function public.group_invite_v1(uuid,uuid[]) to authenticated;

-- ---------------------------------------------------------------- speaking
-- Why p_user may not post, or null when allowed. Managers are never blocked.
create or replace function public.group_speak_block(p_group uuid, p_user uuid) returns text
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare s public.chat_group_settings; ro public.chat_group_roles; role text;
begin
  if p_user is null or not exists(select 1 from public.chat_rooms where id=p_group and kind='group') then return null; end if;
  role := public.group_role_of(p_group, p_user);
  if role in ('owner','admin') then return null; end if;
  select * into ro from public.chat_group_roles where group_id=p_group and user_id=p_user;
  if ro.muted_until is not null and ro.muted_until > now() then return 'GROUP_MUTED'; end if;
  select * into s from public.chat_group_settings where group_id=p_group;
  if found then
    if s.all_muted and not coalesce(ro.exempt_all_mute, false) then return 'GROUP_ALL_MUTED'; end if;
    if s.require_announcement_read and exists(
        select 1 from public.chat_group_content c
        where c.group_id=p_group and c.kind='announcement' and c.popup and c.deleted_at is null
          and not exists(select 1 from public.chat_group_reads d where d.item_id=c.id and d.user_id=p_user)) then
      return 'GROUP_READ_ANNOUNCEMENT';
    end if;
  end if;
  return null;
end $$;
revoke all on function public.group_speak_block(uuid,uuid) from public, anon, authenticated;

create or replace function public.group_speak_allowed(p_group uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select public.group_speak_block(p_group, auth.uid()) is null
$$;
revoke all on function public.group_speak_allowed(uuid) from public;
grant execute on function public.group_speak_allowed(uuid) to authenticated;

-- Anti-spam: reject and explain; the long window lifts itself. No automatic
-- permanent ban - managers see offenders in group_admin_v1('spam_watch').
create or replace function public.group_spam_check(m public.chat_messages) returns void
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare guard boolean;
begin
  select coalesce((select spam_guard from public.chat_group_settings where group_id=m.room_id), true) into guard;
  if not guard then return; end if;
  if (select count(*) from public.chat_messages x where x.room_id=m.room_id and x.sender_id=m.sender_id
      and not x.is_system and x.created_at > now() - interval '5 minutes') >= 40 then
    raise exception 'GROUP_TEMP_LIMITED' using errcode='P0001';
  end if;
  if (select count(*) from public.chat_messages x where x.room_id=m.room_id and x.sender_id=m.sender_id
      and not x.is_system and x.created_at > now() - interval '10 seconds') >= 8 then
    raise exception 'GROUP_SLOW_DOWN' using errcode='P0001';
  end if;
  if coalesce(m.body,'') <> '' and (select count(*) from public.chat_messages x where x.room_id=m.room_id
      and x.sender_id=m.sender_id and x.body=m.body and x.created_at > now() - interval '60 seconds') >= 2 then
    raise exception 'GROUP_DUPLICATE' using errcode='P0001';
  end if;
  if m.attachment_kind='image' and (select count(*) from public.chat_messages x where x.room_id=m.room_id
      and x.sender_id=m.sender_id and x.attachment_kind='image' and x.created_at > now() - interval '60 seconds') >= 6 then
    raise exception 'GROUP_TOO_MANY_IMAGES' using errcode='P0001';
  end if;
  if m.body ~* '(https?://|www\.)' and (select count(*) from public.chat_messages x where x.room_id=m.room_id
      and x.sender_id=m.sender_id and x.body ~* '(https?://|www\.)' and x.created_at > now() - interval '60 seconds') >= 4 then
    raise exception 'GROUP_TOO_MANY_LINKS' using errcode='P0001';
  end if;
end $$;
revoke all on function public.group_spam_check(public.chat_messages) from public, anon, authenticated;

create or replace function public.guard_group_message() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare reason text;
begin
  if new.is_system or auth.uid() is null then return new; end if;
  reason := public.group_speak_block(new.room_id, auth.uid());
  if reason is not null then raise exception '%', reason using errcode='42501'; end if;
  if exists(select 1 from public.chat_rooms where id=new.room_id and kind='group')
     and public.group_role_of(new.room_id, auth.uid()) = 'member' then
    perform public.group_spam_check(new);
  end if;
  return new;
end $$;

-- Group avatars live in the owner's chat-avatars folder; members may read.
drop policy if exists chat_group_avatar_read on storage.objects;
create policy chat_group_avatar_read on storage.objects for select to authenticated using (
  bucket_id='chat-avatars' and exists(select 1 from public.chat_group_settings s
    where s.avatar_path = storage.objects.name and public.chat_member(s.group_id)));

-- ---------------------------------------------------------------- moderation helper
-- Same effect as a personal recall (attachments retired, content blanked),
-- plus who removed it. Members' apps drop it via message_presence.
create or replace function public.group_remove_message(p_id uuid, p_actor uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare m public.chat_messages; path text;
begin
  select * into m from public.chat_messages where id=p_id for update;
  if not found or m.recalled_at is not null or m.is_system then return false; end if;
  if m.attachment_path is not null then
    insert into public.chat_attachment_retirements(bucket,object_key,message_id)
      values('chat-files',m.attachment_path,m.id) on conflict do nothing;
  end if;
  if m.voice_file_id is not null then
    select object_key into path from public.chat_voice_files where id=m.voice_file_id;
    if path is not null then
      insert into public.chat_attachment_retirements(bucket,object_key,message_id)
        values('chat-voice',path,m.id) on conflict do nothing;
    end if;
  end if;
  update public.chat_messages set body='',attachment_path=null,attachment_name=null,
    attachment_kind=null,attachment_size=null,attachment_mime_type=null,
    voice_file_id=null,voice_duration_ms=null,voice_file_size=null,voice_storage_provider=null,
    recalled_at=clock_timestamp(),updated_at=clock_timestamp(),moderated_by=p_actor where id=m.id;
  update public.chat_group_content set title='内容',body='',payload='{}',deleted_at=clock_timestamp()
    where group_id=m.room_id and kind='highlight' and payload->>'message_id'=m.id::text;
  delete from public.chat_group_pins where message_id=m.id;
  return true;
end $$;
revoke all on function public.group_remove_message(uuid,uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- API
create or replace function public.group_admin_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  actor uuid := auth.uid(); gid uuid; r public.chat_rooms; my_role text; target uuid; t uuid;
  lim integer; q text; done integer := 0; skipped integer := 0; minutes integer; until_at timestamptz;
  before_at timestamptz; before_id uuid; before_log bigint; req public.chat_group_join_requests;
  s public.chat_group_settings; invite public.chat_qr_invites; val text; result jsonb;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' or octet_length(p_data::text) > 100000 then
    raise exception 'INVALID_INPUT' using errcode='22023';
  end if;
  if actor is null or not exists(select 1 from auth.users where id=actor and (banned_until is null or banned_until < now())) then
    raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501';
  end if;
  lim := least(greatest(coalesce((p_data->>'limit')::integer, 50), 1), 100);
  q := nullif(btrim(coalesce(p_data->>'query','')), '');
  before_at := nullif(p_data->>'before_at','')::timestamptz;
  before_id := coalesce(nullif(p_data->>'before_id','')::uuid, 'ffffffff-ffff-ffff-ffff-ffffffffffff');

  -- A non-member asks to join a group from its QR code (approval mode).
  if p_action = 'request_join' then
    select * into invite from public.chat_qr_invites where token = nullif(p_data->>'token','')::uuid;
    if not found or invite.expires_at <= now() then raise exception 'QR_EXPIRED'; end if;
    gid := invite.room_id;
    select * into s from public.chat_group_settings where group_id=gid;
    if found and not s.allow_qr then raise exception 'GROUP_QR_DISABLED'; end if;
    if found and s.joins_paused then raise exception 'GROUP_JOINS_PAUSED'; end if;
    if coalesce(s.join_mode,'open') <> 'approval' then raise exception 'GROUP_APPROVAL_NOT_NEEDED'; end if;
    if exists(select 1 from public.chat_group_bans where group_id=gid and user_id=actor) then raise exception 'GROUP_BANNED'; end if;
    if public.chat_member(gid) then return jsonb_build_object('member', true); end if;
    perform pg_advisory_xact_lock(hashtextextended('join-request:'||actor::text, 72));
    if (select count(*) from public.chat_group_join_requests where user_id=actor and created_at > now() - interval '1 hour') >= 20 then
      raise exception 'CHAT_RATE_LIMIT';
    end if;
    insert into public.chat_group_join_requests(group_id, user_id, message)
      values (gid, actor, left(coalesce(p_data->>'message',''), 200))
      on conflict do nothing;
    return jsonb_build_object('requested', true);
  end if;

  gid := nullif(p_data->>'room_id','')::uuid;
  select * into r from public.chat_rooms where id=gid and kind='group';
  if not found then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
  my_role := public.group_role_of(gid, actor);
  if my_role is null then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
  select * into s from public.chat_group_settings where group_id=gid;
  target := nullif(p_data->>'user_id','')::uuid;

  -- ---------- read-only views for every member ----------
  if p_action = 'overview' then
    return jsonb_build_object(
      'my_role', my_role, 'owner_id', r.owner_id, 'title', r.title,
      'member_count', (select count(*) from public.chat_members where room_id=gid and left_at is null),
      'admin_count', (select count(*) from public.chat_group_roles g join public.chat_members m
         on m.room_id=g.group_id and m.user_id=g.user_id and m.left_at is null where g.group_id=gid and g.role='admin'),
      'settings', coalesce(to_jsonb(s), jsonb_build_object('group_id', gid)) || jsonb_build_object(
         'join_mode', coalesce(s.join_mode,'open'), 'allow_qr', coalesce(s.allow_qr,true),
         'qr_valid_days', coalesce(s.qr_valid_days,7), 'joins_paused', coalesce(s.joins_paused,false),
         'new_member_mute_minutes', coalesce(s.new_member_mute_minutes,0),
         'require_announcement_read', coalesce(s.require_announcement_read,false),
         'allow_member_nickname', coalesce(s.allow_member_nickname,true),
         'spam_guard', coalesce(s.spam_guard,true), 'description', coalesce(s.description,''),
         'all_muted', coalesce(s.all_muted,false), 'allow_upload', coalesce(s.allow_upload,true),
         'managers_invite_only', coalesce(s.managers_invite_only,false)),
      'my_nickname', (select nickname from public.chat_group_roles where group_id=gid and user_id=actor),
      'speak_block', public.group_speak_block(gid, actor),
      'pending_requests', case when my_role in ('owner','admin') then
         (select count(*) from public.chat_group_join_requests where group_id=gid and status='pending') else 0 end);
  end if;

  if p_action = 'members' then
    -- Managers (<= 11) come first on the first page; the rest is paged.
    return jsonb_build_object(
      'managers', case when before_at is null and q is null then coalesce((select jsonb_agg(to_jsonb(x) order by x.role_rank, x.joined_at) from (
          select m.user_id, p.nickname, p.avatar_path, p.personal_number, m.joined_at,
            g.nickname as group_nickname, public.group_role_of(gid, m.user_id) as role,
            case when public.group_role_of(gid, m.user_id)='owner' then 0 else 1 end as role_rank,
            case when my_role in ('owner','admin') then g.muted_until end as muted_until,
            case when my_role in ('owner','admin') then g.admin_remark end as admin_remark,
            coalesce(g.exempt_all_mute,false) as exempt_all_mute
          from public.chat_members m join public.chat_profiles p on p.user_id=m.user_id
          left join public.chat_group_roles g on g.group_id=m.room_id and g.user_id=m.user_id
          where m.room_id=gid and m.left_at is null
            and (m.user_id=r.owner_id or g.role='admin')) x), '[]'::jsonb) else '[]'::jsonb end,
      'items', coalesce((select jsonb_agg(to_jsonb(x) order by x.joined_at desc, x.user_id desc) from (
          select m.user_id, p.nickname, p.avatar_path, p.personal_number, m.joined_at,
            g.nickname as group_nickname, public.group_role_of(gid, m.user_id) as role,
            case when my_role in ('owner','admin') then g.muted_until end as muted_until,
            case when my_role in ('owner','admin') then g.admin_remark end as admin_remark,
            coalesce(g.exempt_all_mute,false) as exempt_all_mute
          from public.chat_members m join public.chat_profiles p on p.user_id=m.user_id
          left join public.chat_group_roles g on g.group_id=m.room_id and g.user_id=m.user_id
          where m.room_id=gid and m.left_at is null
            and (q is not null or (m.user_id<>r.owner_id and coalesce(g.role,'member')<>'admin'))
            and (q is null or strpos(lower(p.nickname), lower(q))>0 or strpos(lower(coalesce(g.nickname,'')), lower(q))>0
                 or p.personal_number::text = q)
            and (before_at is null or (m.joined_at, m.user_id) < (before_at, before_id))
          order by m.joined_at desc, m.user_id desc limit lim) x), '[]'::jsonb),
      'total', (select count(*) from public.chat_members where room_id=gid and left_at is null));
  end if;

  if p_action = 'pins' then
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.pinned_at desc) from (
      select m.id, m.sender_id, p.nickname, m.body, m.attachment_kind, m.attachment_name, m.created_at,
        pn.created_at as pinned_at
      from public.chat_group_pins pn join public.chat_messages m on m.id=pn.message_id
      join public.chat_profiles p on p.user_id=m.sender_id
      where pn.group_id=gid and m.recalled_at is null limit 50) x), '[]'::jsonb);
  end if;

  if p_action = 'search' then
    -- Server-side, paged, newest first. kind: text|image|video|file|link.
    val := coalesce(p_data->>'kind', '');
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc, x.id desc) from (
      select m.id, m.sender_id, p.nickname, m.body, m.attachment_kind, m.attachment_name,
        m.attachment_mime_type, m.attachment_size, m.created_at
      from public.chat_messages m join public.chat_profiles p on p.user_id=m.sender_id
      where m.room_id=gid and m.recalled_at is null and not m.is_system
        and (q is null or strpos(lower(m.body), lower(q))>0 or strpos(lower(coalesce(m.attachment_name,'')), lower(q))>0)
        and (target is null or m.sender_id=target)
        and (p_data->>'from' is null or m.created_at >= (p_data->>'from')::timestamptz)
        and (p_data->>'to' is null or m.created_at < (p_data->>'to')::timestamptz)
        and case val
          when 'image' then m.attachment_kind='image'
          when 'video' then coalesce(m.attachment_mime_type,'') like 'video/%'
          when 'file' then m.attachment_kind='file' and coalesce(m.attachment_mime_type,'') not like 'video/%'
          when 'link' then m.body ~* '(https?://|www\.)'
          when 'text' then m.attachment_kind is null and m.voice_file_id is null
          else true end
        and (before_at is null or (m.created_at, m.id) < (before_at, before_id))
      order by m.created_at desc, m.id desc limit lim) x), '[]'::jsonb);
  end if;

  if p_action = 'files' then
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.is_pinned desc, x.created_at desc, x.id desc) from (
      select f.id, f.file_id, f.folder_id, f.is_pinned, f.created_at, f.uploader_id, p.nickname as uploader_name,
        a.file_name, a.file_size, a.object_key, a.bucket, a.checksum, a.storage_provider
      from public.chat_group_files f join public.community_files a on a.id=f.file_id
      left join public.chat_profiles p on p.user_id=f.uploader_id
      where f.group_id=gid and f.deleted_at is null and public.group_file_readable(f.file_id)
        and (q is null or strpos(lower(a.file_name), lower(q))>0)
        and (p_data->>'folder_id' is null or f.folder_id=(p_data->>'folder_id')::uuid)
        and (before_at is null or (f.created_at, f.id) < (before_at, before_id))
      order by f.is_pinned desc, f.created_at desc, f.id desc limit lim) x), '[]'::jsonb);
  end if;

  if p_action = 'announcements' then
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.is_pinned desc, x.created_at desc, x.id desc) from (
      select c.id, c.title, c.body, c.payload, c.is_pinned, c.popup, c.created_at, c.author_id,
        p.nickname as author_name,
        exists(select 1 from public.chat_group_reads d where d.item_id=c.id and d.user_id=actor) as is_read,
        (select count(*) from public.chat_group_reads d where d.item_id=c.id) as read_count
      from public.chat_group_content c left join public.chat_profiles p on p.user_id=c.author_id
      where c.group_id=gid and c.kind='announcement' and c.deleted_at is null
        and (before_at is null or (c.created_at, c.id) < (before_at, before_id))
      order by c.is_pinned desc, c.created_at desc, c.id desc limit lim) x), '[]'::jsonb);
  end if;

  if p_action = 'popup' then
    -- The newest unread "show on entry" announcement, if any.
    return coalesce((select to_jsonb(x) from (
      select c.id, c.title, c.body, c.payload, c.created_at
      from public.chat_group_content c
      where c.group_id=gid and c.kind='announcement' and c.popup and c.deleted_at is null
        and not exists(select 1 from public.chat_group_reads d where d.item_id=c.id and d.user_id=actor)
      order by c.created_at desc limit 1) x), 'null'::jsonb);
  end if;

  if p_action = 'ack' then
    if not exists(select 1 from public.chat_group_content where id=(p_data->>'item_id')::uuid and group_id=gid) then
      raise exception 'INVALID_INPUT';
    end if;
    insert into public.chat_group_reads(item_id, user_id) values ((p_data->>'item_id')::uuid, actor) on conflict do nothing;
    return jsonb_build_object('read', true);
  end if;

  if p_action = 'my_nickname' then
    val := nullif(btrim(coalesce(p_data->>'nickname','')), '');
    if char_length(coalesce(val,'')) > 40 then raise exception 'INVALID_INPUT'; end if;
    if not coalesce(s.allow_member_nickname, true) and my_role = 'member' then
      raise exception 'GROUP_NICKNAME_DISABLED' using errcode='42501';
    end if;
    perform set_config('huideng.group_quiet', '1', true);
    insert into public.chat_group_roles(group_id, user_id, nickname) values (gid, actor, val)
      on conflict (group_id, user_id) do update set nickname = excluded.nickname;
    perform set_config('huideng.group_quiet', '', true);
    return jsonb_build_object('nickname', val);
  end if;

  -- ---------- everything below needs owner or admin ----------
  if my_role not in ('owner','admin') then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('group-admin:'||gid::text, 72));

  if p_action = 'mute' then
    -- minutes: 0 = lift mute, -1 = permanent, otherwise 1..525600.
    minutes := (p_data->>'minutes')::integer;
    if minutes is null or minutes < -1 or minutes > 525600 then raise exception 'INVALID_INPUT'; end if;
    until_at := case when minutes = 0 then null when minutes = -1 then 'infinity'::timestamptz
                     else now() + make_interval(mins => minutes) end;
    for t in select distinct value::uuid from jsonb_array_elements_text(coalesce(p_data->'user_ids', jsonb_build_array(target))) loop
      if public.group_can_manage(gid, actor, t) then
        insert into public.chat_group_roles(group_id, user_id, muted_until) values (gid, t, until_at)
          on conflict (group_id, user_id) do update set muted_until = excluded.muted_until;
        done := done + 1;
      else skipped := skipped + 1; end if;
      exit when done + skipped >= 200;
    end loop;
    return jsonb_build_object('done', done, 'skipped', skipped);
  end if;

  if p_action = 'remove' then
    for t in select distinct value::uuid from jsonb_array_elements_text(coalesce(p_data->'user_ids', jsonb_build_array(target))) loop
      if public.group_can_manage(gid, actor, t) then
        if coalesce((p_data->>'ban')::boolean, false) then
          insert into public.chat_group_bans(group_id, user_id, banned_by) values (gid, t, actor) on conflict do nothing;
          perform public.group_log(gid, 'ban', t);
        end if;
        update public.chat_members set left_at = now() where room_id=gid and user_id=t and left_at is null;
        perform set_config('huideng.group_quiet', '1', true);
        update public.chat_group_roles set role='member', muted_until=null, exempt_all_mute=false where group_id=gid and user_id=t;
        perform set_config('huideng.group_quiet', '', true);
        done := done + 1;
      else skipped := skipped + 1; end if;
      exit when done + skipped >= 200;
    end loop;
    return jsonb_build_object('done', done, 'skipped', skipped);
  end if;

  if p_action = 'bans' then
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select b.user_id, p.nickname, p.personal_number, b.created_at, b.banned_by
      from public.chat_group_bans b left join public.chat_profiles p on p.user_id=b.user_id
      where b.group_id=gid order by b.created_at desc limit 500) x), '[]'::jsonb);
  end if;
  if p_action = 'unban' then
    delete from public.chat_group_bans where group_id=gid and user_id=target;
    if found then perform public.group_log(gid, 'unban', target); end if;
    return jsonb_build_object('done', true);
  end if;

  if p_action = 'remark' then
    if not public.group_can_manage(gid, actor, target) and target is distinct from actor then raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501'; end if;
    val := nullif(btrim(coalesce(p_data->>'remark','')), '');
    if char_length(coalesce(val,'')) > 80 then raise exception 'INVALID_INPUT'; end if;
    perform set_config('huideng.group_quiet', '1', true);
    insert into public.chat_group_roles(group_id, user_id, admin_remark) values (gid, target, val)
      on conflict (group_id, user_id) do update set admin_remark = excluded.admin_remark;
    perform set_config('huideng.group_quiet', '', true);
    return jsonb_build_object('remark', val);
  end if;

  if p_action = 'requests' then
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from (
      select q2.id, q2.user_id, p.nickname, p.personal_number, q2.message, q2.created_at, q2.inviter_id,
        ip.nickname as inviter_name
      from public.chat_group_join_requests q2 left join public.chat_profiles p on p.user_id=q2.user_id
      left join public.chat_profiles ip on ip.user_id=q2.inviter_id
      where q2.group_id=gid and q2.status='pending' order by q2.created_at limit 200) x), '[]'::jsonb);
  end if;
  if p_action = 'decide' then
    select * into req from public.chat_group_join_requests
      where id=(p_data->>'request_id')::uuid and group_id=gid and status='pending' for update;
    if not found then raise exception 'REQUEST_UNAVAILABLE'; end if;
    if coalesce((p_data->>'approve')::boolean, false) then
      perform set_config('huideng.group_join', 'approved', true);
      insert into public.chat_members(room_id, user_id) values (gid, req.user_id)
        on conflict (room_id, user_id) do update set left_at=null, joined_at=now();
      perform set_config('huideng.group_join', '', true);
      insert into public.chat_messages(id, room_id, sender_id, body, is_system)
        values (gen_random_uuid(), gid, actor,
          coalesce((select nickname from public.chat_profiles where user_id=req.user_id),'学友')||'加入了群聊', true);
    end if;
    update public.chat_group_join_requests set status = case when (p_data->>'approve')::boolean then 'approved' else 'rejected' end,
      decided_by = actor, decided_at = now() where id = req.id;
    perform public.group_log(gid, case when (p_data->>'approve')::boolean then 'approve_join' else 'reject_join' end, req.user_id);
    return jsonb_build_object('done', true);
  end if;

  if p_action = 'delete_messages' then
    for t in select distinct value::uuid from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb)) limit 100 loop
      -- Own messages, members one may manage, or people who already left
      -- (never the owner's messages unless you are the owner).
      if exists(select 1 from public.chat_messages m where m.id=t and m.room_id=gid
          and (m.sender_id=actor or public.group_can_manage(gid, actor, m.sender_id)
               or (public.group_role_of(gid, m.sender_id) is null and m.sender_id <> r.owner_id)))
         and public.group_remove_message(t, actor) then
        done := done + 1;
      else skipped := skipped + 1; end if;
    end loop;
    if done > 0 then
      perform public.group_log(gid, 'delete_messages', null, jsonb_build_object('count', done));
      update public.chat_rooms set updated_at=clock_timestamp() where id=gid;
    end if;
    return jsonb_build_object('done', done, 'skipped', skipped);
  end if;

  if p_action = 'purge_member' then
    -- A member's recent messages (default 24 h, at most 7 days / 1000 messages).
    if not public.group_can_manage(gid, actor, target)
       and not (public.group_role_of(gid, target) is null and target is distinct from r.owner_id) then
      raise exception 'CHAT_MANAGER_REQUIRED' using errcode='42501';
    end if;
    minutes := least(greatest(coalesce((p_data->>'hours')::integer, 24), 1), 168) * 60;
    for t in select id from public.chat_messages where room_id=gid and sender_id=target and recalled_at is null
        and not is_system and created_at > now() - make_interval(mins => minutes)
        order by created_at desc limit 1000 loop
      if public.group_remove_message(t, actor) then done := done + 1; end if;
    end loop;
    if done > 0 then
      perform public.group_log(gid, 'purge_member', target, jsonb_build_object('count', done, 'hours', minutes / 60));
      update public.chat_rooms set updated_at=clock_timestamp() where id=gid;
    end if;
    return jsonb_build_object('done', done);
  end if;

  if p_action = 'pin' then
    t := (p_data->>'message_id')::uuid;
    if not exists(select 1 from public.chat_messages where id=t and room_id=gid and recalled_at is null) then
      raise exception 'CHAT_INVALID_MESSAGE';
    end if;
    if coalesce((p_data->>'enabled')::boolean, true) then
      if (select count(*) from public.chat_group_pins where group_id=gid) >= 50 then raise exception 'GROUP_PIN_LIMIT'; end if;
      insert into public.chat_group_pins(group_id, message_id, pinned_by) values (gid, t, actor) on conflict do nothing;
      perform public.group_log(gid, 'pin_message', null, jsonb_build_object('message_id', t));
    else
      delete from public.chat_group_pins where group_id=gid and message_id=t;
      perform public.group_log(gid, 'unpin_message', null, jsonb_build_object('message_id', t));
    end if;
    return jsonb_build_object('done', true);
  end if;

  if p_action = 'file_pin' then
    update public.chat_group_files set is_pinned = coalesce((p_data->>'enabled')::boolean, true)
      where id=(p_data->>'file_id')::uuid and group_id=gid and deleted_at is null;
    return jsonb_build_object('done', found);
  end if;

  if p_action = 'announce' then
    -- Text + payload {images, links, files}; pinned; "show once on entry".
    t := coalesce(nullif(p_data->>'id','')::uuid, gen_random_uuid());
    val := btrim(coalesce(p_data->>'title',''));
    if char_length(val) not between 1 and 160 or char_length(coalesce(p_data->>'body','')) > 20000
       or jsonb_typeof(coalesce(p_data->'payload','{}'::jsonb)) <> 'object' then
      raise exception 'INVALID_INPUT';
    end if;
    delete from public.chat_group_reads where item_id=t and exists(select 1 from public.chat_group_content c
      where c.id=t and c.group_id=gid and (c.title is distinct from val or c.body is distinct from coalesce(p_data->>'body','')));
    insert into public.chat_group_content(id, group_id, author_id, kind, title, body, payload, is_pinned, popup)
      values (t, gid, actor, 'announcement', val, coalesce(p_data->>'body',''), coalesce(p_data->'payload','{}'::jsonb),
        coalesce((p_data->>'is_pinned')::boolean, false), coalesce((p_data->>'popup')::boolean, false))
      on conflict (id) do update set title=excluded.title, body=excluded.body, payload=excluded.payload,
        is_pinned=excluded.is_pinned, popup=excluded.popup
      where public.chat_group_content.group_id=gid and public.chat_group_content.kind='announcement';
    return jsonb_build_object('id', t);
  end if;
  if p_action = 'announcement_remove' then
    update public.chat_group_content set deleted_at=now()
      where id=(p_data->>'item_id')::uuid and group_id=gid and kind='announcement' and deleted_at is null;
    return jsonb_build_object('done', found);
  end if;

  if p_action = 'spam_watch' then
    -- Recent heavy senders for managers to review; nothing is banned automatically.
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.recent desc) from (
      select m.sender_id as user_id, p.nickname, count(*) as recent,
        count(*) filter (where m.body ~* '(https?://|www\.)') as links,
        count(*) filter (where m.attachment_kind='image') as images
      from public.chat_messages m join public.chat_profiles p on p.user_id=m.sender_id
      where m.room_id=gid and not m.is_system and m.created_at > now() - interval '30 minutes'
        and public.group_role_of(gid, m.sender_id)='member'
      group by m.sender_id, p.nickname having count(*) >= 20 limit 50) x), '[]'::jsonb);
  end if;

  if p_action = 'all_mute' then
    insert into public.chat_group_settings(group_id, all_muted) values (gid, coalesce((p_data->>'enabled')::boolean, false))
      on conflict (group_id) do update set all_muted = excluded.all_muted;
    return jsonb_build_object('all_muted', coalesce((p_data->>'enabled')::boolean, false));
  end if;

  -- ---------- owner only ----------
  if my_role <> 'owner' then raise exception 'GROUP_OWNER_REQUIRED' using errcode='42501'; end if;

  if p_action = 'set_admin' then
    if target is null or target = actor or public.group_role_of(gid, target) is null then raise exception 'INVALID_INPUT'; end if;
    insert into public.chat_group_roles(group_id, user_id, role)
      values (gid, target, case when coalesce((p_data->>'enabled')::boolean, true) then 'admin' else 'member' end)
      on conflict (group_id, user_id) do update set role = excluded.role;
    return jsonb_build_object('done', true);
  end if;

  if p_action = 'exempt' then
    if public.group_role_of(gid, target) is null then raise exception 'INVALID_INPUT'; end if;
    insert into public.chat_group_roles(group_id, user_id, exempt_all_mute)
      values (gid, target, coalesce((p_data->>'enabled')::boolean, true))
      on conflict (group_id, user_id) do update set exempt_all_mute = excluded.exempt_all_mute;
    return jsonb_build_object('done', true);
  end if;

  if p_action = 'settings' then
    val := p_data->'settings'->>'avatar_path';
    if val is not null and val <> '' and (split_part(val,'/',1) is distinct from actor::text or not exists(
        select 1 from storage.objects o where o.bucket_id='chat-avatars' and o.name=val)) then
      raise exception 'CHAT_INVALID_AVATAR';
    end if;
    insert into public.chat_group_settings(group_id) values (gid) on conflict do nothing;
    update public.chat_group_settings x set
      join_mode = coalesce(p_data->'settings'->>'join_mode', x.join_mode),
      allow_qr = coalesce((p_data->'settings'->>'allow_qr')::boolean, x.allow_qr),
      qr_valid_days = coalesce((p_data->'settings'->>'qr_valid_days')::integer, x.qr_valid_days),
      joins_paused = coalesce((p_data->'settings'->>'joins_paused')::boolean, x.joins_paused),
      new_member_mute_minutes = coalesce((p_data->'settings'->>'new_member_mute_minutes')::integer, x.new_member_mute_minutes),
      require_announcement_read = coalesce((p_data->'settings'->>'require_announcement_read')::boolean, x.require_announcement_read),
      allow_member_nickname = coalesce((p_data->'settings'->>'allow_member_nickname')::boolean, x.allow_member_nickname),
      spam_guard = coalesce((p_data->'settings'->>'spam_guard')::boolean, x.spam_guard),
      managers_invite_only = coalesce((p_data->'settings'->>'managers_invite_only')::boolean, x.managers_invite_only),
      allow_upload = coalesce((p_data->'settings'->>'allow_upload')::boolean, x.allow_upload),
      history_files = coalesce((p_data->'settings'->>'history_files')::boolean, x.history_files),
      all_muted = coalesce((p_data->'settings'->>'all_muted')::boolean, x.all_muted),
      description = coalesce(p_data->'settings'->>'description', x.description),
      avatar_path = case when p_data->'settings' ? 'avatar_path' then nullif(val,'') else x.avatar_path end
      where x.group_id = gid;
    return jsonb_build_object('done', true);
  end if;

  if p_action = 'transfer_owner' then
    if target is null or target = actor or public.group_role_of(gid, target) is null then raise exception 'INVALID_INPUT'; end if;
    perform 1 from public.chat_rooms where id=gid for update;
    perform set_config('huideng.group_quiet', '1', true);
    update public.chat_group_roles set role='member', muted_until=null where group_id=gid and user_id=target;
    perform set_config('huideng.group_quiet', '', true);
    update public.chat_rooms set owner_id=target, updated_at=clock_timestamp() where id=gid;
    -- The previous owner stays as an admin when a seat is free.
    begin
      insert into public.chat_group_roles(group_id, user_id, role) values (gid, actor, 'admin')
        on conflict (group_id, user_id) do update set role='admin';
    exception when others then null;
    end;
    return jsonb_build_object('owner_id', target);
  end if;

  if p_action = 'logs' then
    before_log := nullif(p_data->>'before_log','')::bigint;
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (
      select l.id, l.action, l.actor_id, a.nickname as actor_name, l.target_id, tp.nickname as target_name,
        l.detail, l.created_at
      from public.chat_group_logs l left join public.chat_profiles a on a.user_id=l.actor_id
      left join public.chat_profiles tp on tp.user_id=l.target_id
      where l.group_id=gid and (before_log is null or l.id < before_log)
      order by l.id desc limit lim) x), '[]'::jsonb);
  end if;

  raise exception 'INVALID_ACTION';
end $$;
revoke all on function public.group_admin_v1(text,jsonb) from public, anon;
grant execute on function public.group_admin_v1(text,jsonb) to authenticated;

-- QR codes use the group's validity period (default 7 days).
do $$
declare definition text;
begin
  definition := pg_get_functiondef('public.chat_qr_v1(text,jsonb)'::regprocedure);
  if position('qr_valid_days' in definition) = 0 then
    if position('insert into public.chat_qr_invites(room_id) values(rid)' in definition) > 0
       and position('expires_at=now()+interval ''7 days''' in definition) > 0 then
      definition := replace(definition, 'insert into public.chat_qr_invites(room_id) values(rid)',
        'insert into public.chat_qr_invites(room_id,expires_at) values(rid,now()+make_interval(days=>coalesce((select s.qr_valid_days from public.chat_group_settings s where s.group_id=rid),7)))');
      definition := replace(definition, 'expires_at=now()+interval ''7 days''',
        'expires_at=now()+make_interval(days=>coalesce((select s.qr_valid_days from public.chat_group_settings s where s.group_id=rid),7))');
      execute definition;
    else
      raise notice 'chat_qr_v1 expiry expression not found; QR validity stays 7 days';
    end if;
  end if;
end $$;

notify pgrst, 'reload schema';
commit;
