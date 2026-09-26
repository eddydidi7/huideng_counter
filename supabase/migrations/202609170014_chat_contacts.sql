-- Additive friend/contact module. No existing messages or memberships are changed.
begin;
create table public.chat_friend_requests (
 id uuid primary key default gen_random_uuid(), sender_id uuid not null references auth.users(id),
 receiver_id uuid not null references auth.users(id), note text not null default '' check(length(note)<=200),
 state text not null default 'pending' check(state in ('pending','accepted','declined')),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(sender_id,receiver_id),check(sender_id<>receiver_id)
);
create table public.chat_friends (
 user_id uuid not null references auth.users(id),friend_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(),deleted_at timestamptz,
 primary key(user_id,friend_id),check(user_id<>friend_id)
);
create table public.chat_contact_lookups (
 user_id uuid not null references auth.users(id), searched_at timestamptz not null default now()
);
create index chat_contact_lookup_rate on public.chat_contact_lookups(user_id,searched_at);
alter table public.chat_friend_requests enable row level security;
alter table public.chat_friends enable row level security;
alter table public.chat_contact_lookups enable row level security;
revoke all on public.chat_friend_requests,public.chat_friends,public.chat_contact_lookups from anon,authenticated;
grant select on public.chat_friend_requests,public.chat_friends to authenticated;
create policy chat_requests_own on public.chat_friend_requests for select to authenticated using(auth.uid() in(sender_id,receiver_id));
create policy chat_friends_own on public.chat_friends for select to authenticated using(user_id=auth.uid());
create function public.chat_contacts_v1(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();target uuid;req public.chat_friend_requests;result jsonb;q text;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='list' then
  return jsonb_build_object('friends',coalesce((select jsonb_agg(x order by x.nickname,x.user_id) from (
   select p.user_id,p.nickname,exists(select 1 from public.chat_blocks b where b.user_id=actor and b.blocked_id=p.user_id) as blocked
   from public.chat_friends f join public.chat_profiles p on p.user_id=f.friend_id where f.user_id=actor and f.deleted_at is null) x),'[]'::jsonb),
   'requests',coalesce((select jsonb_agg(x order by x.updated_at desc) from (select r.*,p.nickname from public.chat_friend_requests r
    join public.chat_profiles p on p.user_id=case when r.sender_id=actor then r.receiver_id else r.sender_id end
    where actor in(r.sender_id,r.receiver_id) order by r.updated_at desc limit 100) x),'[]'::jsonb));
 elsif p_action='search' then
  q:=btrim(coalesce(p_data->>'query',''));
  if length(q) not between 2 and 254 then raise exception 'CHAT_SEARCH_LENGTH'; end if;
  perform pg_advisory_xact_lock(hashtext(actor::text));
  if (select count(*) from public.chat_contact_lookups where user_id=actor and searched_at>now()-interval '1 minute')>=20 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_contact_lookups(user_id) values(actor);
  select coalesce(jsonb_agg(x),'[]') into result from (
   select p.user_id,p.nickname,exists(select 1 from public.chat_friends f where f.user_id=actor and f.friend_id=p.user_id and f.deleted_at is null) as friend
   from public.chat_profiles p join auth.users u on u.id=p.user_id
   where p.user_id<>actor and not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<now())
   and not exists(select 1 from public.chat_blocks b where (b.user_id=actor and b.blocked_id=p.user_id) or (b.user_id=p.user_id and b.blocked_id=actor))
   and (case when strpos(q,'@')>0 then lower(u.email)=lower(q) else strpos(lower(p.nickname),lower(q))>0 or p.user_id::text=q end)
   order by p.nickname,p.user_id limit 30) x; return result;
 elsif p_action='request' then
  target:=(p_data->>'user_id')::uuid;
  if target=actor or not exists(select 1 from public.chat_profiles p join auth.users u on u.id=p.user_id where p.user_id=target and not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<now())) then raise exception 'CHAT_INVALID_USER'; end if;
  perform pg_advisory_xact_lock(hashtext(least(actor::text,target::text)||greatest(actor::text,target::text)));
  if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
  if exists(select 1 from public.chat_friends where user_id=actor and friend_id=target and deleted_at is null) then return '{}'::jsonb; end if;
  select * into req from public.chat_friend_requests where sender_id=actor and receiver_id=target;
  if req.state='pending' then return '{}'::jsonb; end if;
  if req.updated_at>now()-interval '1 minute' or (select count(*) from public.chat_friend_requests where sender_id=actor and updated_at>now()-interval '1 minute')>=10 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_friend_requests(sender_id,receiver_id,note) values(actor,target,coalesce(p_data->>'note',''))
  on conflict(sender_id,receiver_id) do update set note=excluded.note,state='pending',updated_at=now();
 elsif p_action='review' then
  select * into req from public.chat_friend_requests where id=(p_data->>'id')::uuid;
  if req.id is null or req.receiver_id<>actor then raise exception 'CHAT_REQUEST_DENIED' using errcode='42501'; end if;
  target:=req.sender_id;
  perform pg_advisory_xact_lock(hashtext(least(actor::text,target::text)||greatest(actor::text,target::text)));
  select * into req from public.chat_friend_requests where id=req.id for update;
  if req.state<>'pending' then return '{}'::jsonb; end if;
  if coalesce((p_data->>'accept')::boolean,false) then
   if exists(select 1 from public.chat_blocks where (user_id=actor and blocked_id=target) or (user_id=target and blocked_id=actor)) then raise exception 'CHAT_BLOCKED'; end if;
   insert into public.chat_friends(user_id,friend_id) values(actor,target),(target,actor) on conflict(user_id,friend_id) do update set deleted_at=null;
   update public.chat_friend_requests set state='accepted',updated_at=now() where (sender_id=actor and receiver_id=target) or (sender_id=target and receiver_id=actor);
  else update public.chat_friend_requests set state='declined',updated_at=now() where id=req.id; end if;
 elsif p_action='remove' then
  target:=(p_data->>'user_id')::uuid;
  perform pg_advisory_xact_lock(hashtext(least(actor::text,target::text)||greatest(actor::text,target::text)));
  update public.chat_friends set deleted_at=now() where (user_id=actor and friend_id=target) or (user_id=target and friend_id=actor);
 else raise exception 'UNKNOWN_ACTION'; end if;
 return '{}'::jsonb;
end $$;
revoke all on function public.chat_contacts_v1(text,jsonb) from public;
grant execute on function public.chat_contacts_v1(text,jsonb) to authenticated;
-- Realtime only delivers rows allowed by the SELECT policies above.
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  alter publication supabase_realtime add table public.chat_friend_requests,public.chat_friends;
 end if;
end $$;
-- Attachment size is taken from trusted Storage metadata, not client claims.
alter table public.chat_messages add column attachment_size bigint;
create function public.chat_attachment_size() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.attachment_path is not null then
  select (to_jsonb(o)->'metadata'->>'size')::bigint into new.attachment_size from storage.objects o where o.bucket_id='chat-files' and o.name=new.attachment_path limit 1;
 end if;
 return new;
end $$;
revoke all on function public.chat_attachment_size() from public;
create trigger chat_message_attachment_size before insert on public.chat_messages for each row execute function public.chat_attachment_size();
notify pgrst,'reload schema';
commit;

