-- Additive chat module. No existing counter, notes, forum or auth data is deleted.
begin;
create table public.chat_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 nickname text not null check(length(nickname) between 1 and 40),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.chat_rooms (
 id uuid primary key default gen_random_uuid(), kind text not null check(kind in ('direct','group')),
 title text not null default '' check(length(title)<=80), owner_id uuid not null references auth.users(id),
 direct_key text unique, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.chat_members (
 room_id uuid not null references public.chat_rooms(id), user_id uuid not null references auth.users(id),
 joined_at timestamptz not null default now(), left_at timestamptz,
 read_at timestamptz not null default 'epoch', pinned boolean not null default false,
 muted boolean not null default false, primary key(room_id,user_id)
);
create table public.chat_messages (
 id uuid primary key, room_id uuid not null references public.chat_rooms(id),
 sender_id uuid not null references auth.users(id), body text not null check(length(body)<=8000),
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default now(),
 recalled_at timestamptz, attachment_path text, attachment_name text,
 attachment_kind text check(attachment_kind in ('image','file'))
);
create index chat_messages_room_time on public.chat_messages(room_id,created_at,id);
create index chat_members_user on public.chat_members(user_id,room_id);
create table public.chat_blocks (
 user_id uuid not null references auth.users(id), blocked_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(), primary key(user_id,blocked_id), check(user_id<>blocked_id)
);

create function public.chat_member(p_room uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.chat_members where room_id=p_room and user_id=auth.uid() and left_at is null)
$$;
revoke all on function public.chat_member(uuid) from public;
grant execute on function public.chat_member(uuid) to authenticated;

alter table public.chat_profiles enable row level security;
alter table public.chat_rooms enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_blocks enable row level security;
revoke all on public.chat_profiles,public.chat_rooms,public.chat_members,public.chat_messages,public.chat_blocks from anon,authenticated;
grant select on public.chat_profiles,public.chat_rooms,public.chat_members,public.chat_messages,public.chat_blocks to authenticated;
create policy chat_profiles_read on public.chat_profiles for select to authenticated using (auth.uid() is not null);
create policy chat_rooms_read on public.chat_rooms for select to authenticated using(public.chat_member(id));
create policy chat_members_read on public.chat_members for select to authenticated using(user_id=auth.uid());
create policy chat_messages_read on public.chat_messages for select to authenticated using(public.chat_member(room_id));
create policy chat_blocks_read on public.chat_blocks for select to authenticated using(user_id=auth.uid());

create function public.chat_register_profile() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(new.is_anonymous,false) then
  insert into public.chat_profiles(user_id,nickname) values(new.id,'学友 '||left(new.id::text,8)) on conflict do nothing;
 end if;
 return new;
end $$;
revoke all on function public.chat_register_profile() from public;
create trigger huideng_chat_profile after insert on auth.users for each row execute function public.chat_register_profile();
insert into public.chat_profiles(user_id,nickname)
 select id,'学友 '||left(id::text,8) from auth.users where not coalesce(is_anonymous,false) on conflict do nothing;

create function public.chat_api_v1(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid(); target uuid; room uuid; msg uuid; other uuid; pair text;
 r public.chat_rooms; m public.chat_messages; result jsonb; content text; member_ids uuid[];
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)
   and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='directory' then
  select coalesce(jsonb_agg(to_jsonb(t)),'[]') into result from (
   select p.user_id,p.nickname,exists(select 1 from public.chat_blocks b where b.user_id=actor and b.blocked_id=p.user_id) as blocked
   from public.chat_profiles p join auth.users u on u.id=p.user_id
   where (u.banned_until is null or u.banned_until<now()) and p.nickname ilike '%'||left(coalesce(p_data->>'search',''),80)||'%'
   order by p.nickname,p.user_id limit 100 offset greatest(0,least(coalesce((p_data->>'offset')::int,0),1000000))
  ) t; return result;
 elsif p_action='profile' then
  content:=btrim(p_data->>'nickname');
  if content is null or length(content) not between 1 and 40 then raise exception 'CHAT_INVALID_NAME'; end if;
  update public.chat_profiles set nickname=content,updated_at=now() where user_id=actor; return '{}'::jsonb;
 elsif p_action='block' then
  target:=(p_data->>'user_id')::uuid;
  if coalesce((p_data->>'blocked')::boolean,true) then
   insert into public.chat_blocks values(actor,target,now()) on conflict do nothing;
  else delete from public.chat_blocks where user_id=actor and blocked_id=target; end if;
  return '{}'::jsonb;
 elsif p_action='rooms' then
  select coalesce(jsonb_agg(to_jsonb(t)),'[]') into result from (
   select c.id,c.kind,c.owner_id,
    case when c.kind='group' then c.title else coalesce((select p.nickname from public.chat_members n join public.chat_profiles p on p.user_id=n.user_id where n.room_id=c.id and n.user_id<>actor limit 1),'学友') end title,
    c.updated_at,s.pinned,s.muted,
    (select count(*) from public.chat_messages x where x.room_id=c.id and x.sender_id<>actor and x.created_at>s.read_at and x.recalled_at is null) unread,
    (select case when x.recalled_at is null then left(x.body,80) else '消息已撤回' end from public.chat_messages x where x.room_id=c.id order by x.created_at desc,x.id desc limit 1) preview
   from public.chat_rooms c join public.chat_members s on s.room_id=c.id
   where s.user_id=actor and s.left_at is null order by s.pinned desc,c.updated_at desc limit 200
  ) t; return result;
 elsif p_action='direct' then
  target:=(p_data->>'user_id')::uuid;
  if target=actor or not exists(select 1 from public.chat_profiles where user_id=target) then raise exception 'CHAT_INVALID_USER'; end if;
  if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
  pair:=least(actor::text,target::text)||':'||greatest(actor::text,target::text);
  insert into public.chat_rooms(kind,owner_id,direct_key) values('direct',actor,pair)
   on conflict(direct_key) do update set direct_key=excluded.direct_key returning id into room;
  insert into public.chat_members(room_id,user_id) values(room,actor),(room,target) on conflict do nothing;
  return jsonb_build_object('id',room);
 elsif p_action='create_group' then
  room:=(p_data->>'id')::uuid; content:=btrim(p_data->>'title');
  if room is null or content is null or length(content) not between 1 and 80 then raise exception 'CHAT_INVALID_NAME'; end if;
  if exists(select 1 from public.chat_rooms where id=room and owner_id=actor and kind='group') then return jsonb_build_object('id',room); end if;
  select array_agg(distinct value::uuid) into member_ids from jsonb_array_elements_text(p_data->'members');
  if coalesce(cardinality(member_ids),0) not between 1 and 99 then raise exception 'CHAT_GROUP_SIZE'; end if;
  if exists(select 1 from unnest(member_ids) v where not exists(select 1 from public.chat_profiles where user_id=v)) then raise exception 'CHAT_INVALID_USER'; end if;
  if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=any(member_ids)) or (blocked_id=actor and user_id=any(member_ids))) then raise exception 'CHAT_BLOCKED'; end if;
  if (select count(*) from public.chat_rooms where owner_id=actor and kind='group' and created_at>now()-interval '1 hour')>=10 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_rooms(id,kind,title,owner_id) values(room,'group',content,actor);
  insert into public.chat_members(room_id,user_id) select room,v from unnest(array_append(member_ids,actor)) v on conflict do nothing;
  return jsonb_build_object('id',room);
 end if;
 room:=(p_data->>'room_id')::uuid;
 if not public.chat_member(room) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 select * into r from public.chat_rooms where id=room for update;
 if p_action='messages' then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at,t.id),'[]') into result from (
   select x.*,p.nickname from public.chat_messages x join public.chat_profiles p on p.user_id=x.sender_id
   where x.room_id=room and (p_data->>'before' is null or x.created_at<(p_data->>'before')::timestamptz)
   order by x.created_at desc,x.id desc limit 100
  ) t; return result;
 elsif p_action='members' then
  select coalesce(jsonb_agg(jsonb_build_object('user_id',s.user_id,'nickname',p.nickname,'read_at',s.read_at)),'[]') into result
  from public.chat_members s join public.chat_profiles p on p.user_id=s.user_id where s.room_id=room and s.left_at is null; return result;
 elsif p_action='send' then
  msg:=(p_data->>'id')::uuid; content:=btrim(p_data->>'body');
  select * into m from public.chat_messages where id=msg;
  if found then
   if m.sender_id=actor and m.room_id=room then return to_jsonb(m); end if;
   raise exception 'CHAT_UUID_CONFLICT';
  end if;
  if msg is null or content is null or length(content) not between 1 and 8000 then raise exception 'CHAT_INVALID_MESSAGE'; end if;
  if r.kind='direct' and exists(select 1 from public.chat_members s join public.chat_blocks b
    on (b.user_id=actor and b.blocked_id=s.user_id) or (b.blocked_id=actor and b.user_id=s.user_id)
    where s.room_id=room and s.user_id<>actor) then raise exception 'CHAT_BLOCKED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text,12));
  if (select count(*) from public.chat_messages where sender_id=actor and created_at>now()-interval '1 minute')>=30 then raise exception 'CHAT_RATE_LIMIT'; end if;
  if p_data->>'attachment_path' is not null then
   if p_data->>'attachment_kind' not in ('image','file') or p_data->>'attachment_kind' is null
     or length(coalesce(p_data->>'attachment_name','')) not between 1 and 200
     or not starts_with(p_data->>'attachment_path',room::text||'/'||actor::text||'/')
     or not exists(select 1 from storage.objects where bucket_id='chat-files' and name=p_data->>'attachment_path')
   then raise exception 'CHAT_INVALID_ATTACHMENT'; end if;
  end if;
  insert into public.chat_messages(id,room_id,sender_id,body,attachment_path,attachment_name,attachment_kind)
   values(msg,room,actor,content,p_data->>'attachment_path',p_data->>'attachment_name',p_data->>'attachment_kind') returning * into m;
  update public.chat_rooms set updated_at=m.created_at where id=room; return to_jsonb(m);
 elsif p_action='read' then
  update public.chat_members set read_at=greatest(read_at,least(coalesce((p_data->>'at')::timestamptz,'epoch'),clock_timestamp())) where room_id=room and user_id=actor;
 elsif p_action='preferences' then
  update public.chat_members set pinned=coalesce((p_data->>'pinned')::boolean,pinned), muted=coalesce((p_data->>'muted')::boolean,muted) where room_id=room and user_id=actor;
 elsif p_action='recall' then
  update public.chat_messages set body='',attachment_path=null,attachment_name=null,attachment_kind=null,recalled_at=now(),updated_at=now() where id=(p_data->>'id')::uuid and room_id=room and sender_id=actor and created_at>now()-interval '2 minutes';
  if not found then raise exception 'CHAT_RECALL_EXPIRED'; end if;
 elsif p_action='rename' then
  if r.kind<>'group' or r.owner_id<>actor then raise exception 'CHAT_OWNER_REQUIRED' using errcode='42501'; end if;
  content:=btrim(p_data->>'title');
  if content is null or length(content) not between 1 and 80 then raise exception 'CHAT_INVALID_NAME'; end if;
  update public.chat_rooms set title=content,updated_at=now() where id=room;
 elsif p_action in ('invite','remove','leave') then
  if r.kind<>'group' then raise exception 'CHAT_GROUP_REQUIRED'; end if;
  target:=case when p_action='leave' then actor else (p_data->>'user_id')::uuid end;
  if p_action<>'leave' and r.owner_id<>actor then raise exception 'CHAT_OWNER_REQUIRED' using errcode='42501'; end if;
  if target=r.owner_id then raise exception 'CHAT_OWNER_CANNOT_LEAVE'; end if;
  if p_action='invite' then
   if not exists(select 1 from public.chat_profiles where user_id=target) then raise exception 'CHAT_INVALID_USER'; end if;
   if (select count(*) from public.chat_members where room_id=room and left_at is null)>=100 then raise exception 'CHAT_GROUP_SIZE'; end if;
   if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
   insert into public.chat_members(room_id,user_id) values(room,target) on conflict(room_id,user_id) do update set left_at=null,joined_at=now();
  else update public.chat_members set left_at=now() where room_id=room and user_id=target; end if;
 else raise exception 'CHAT_UNKNOWN_ACTION'; end if;
 return '{}'::jsonb;
end $$;
revoke all on function public.chat_api_v1(text,jsonb) from public,anon;
grant execute on function public.chat_api_v1(text,jsonb) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit) values('chat-files','chat-files',false,10485760) on conflict(id) do nothing;
create function public.chat_file_member(p_name text) returns boolean
language plpgsql stable security definer set search_path='' as $$
begin return public.chat_member(split_part(p_name,'/',1)::uuid);
exception when invalid_text_representation then return false;
end $$;
revoke all on function public.chat_file_member(text) from public;
grant execute on function public.chat_file_member(text) to authenticated;
create policy chat_files_upload on storage.objects for insert to authenticated with check(
 bucket_id='chat-files' and (storage.foldername(name))[2]=auth.uid()::text and public.chat_file_member(name)
);
create policy chat_files_download on storage.objects for select to authenticated using(
 bucket_id='chat-files' and public.chat_file_member(name)
 and exists(select 1 from public.chat_messages where attachment_path=name and recalled_at is null)
);
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  alter publication supabase_realtime add table public.chat_messages,public.chat_rooms,public.chat_members;
 end if;
end $$;
notify pgrst,'reload schema';
commit;
