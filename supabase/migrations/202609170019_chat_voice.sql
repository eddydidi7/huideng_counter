-- Additive voice messages and private 1:1 call signalling. No audio in PostgreSQL.
begin;
create table public.chat_voice_files (
 id uuid primary key, room_id uuid not null references public.chat_rooms(id),
 user_id uuid not null references auth.users(id), object_key text not null unique,
 duration_ms integer not null check(duration_ms between 500 and 60000),
 file_size bigint not null check(file_size between 1 and 10485760),
 storage_provider text not null default 'supabase' check(storage_provider='supabase'),
 codec text not null check(codec in ('opus','aac')),
 created_at timestamptz not null default now(),
 check(object_key=room_id::text||'/'||user_id::text||'/'||id::text||case when codec='opus' then '.ogg' else '.m4a' end)
);
alter table public.chat_messages add column voice_file_id uuid references public.chat_voice_files(id),
 add column voice_duration_ms integer, add column voice_file_size bigint, add column voice_storage_provider text;
alter table public.chat_voice_files enable row level security;
revoke all on public.chat_voice_files from anon,authenticated;
grant select on public.chat_voice_files to authenticated;
create policy voice_file_read on public.chat_voice_files for select to authenticated using(
 public.chat_member(room_id) and exists(select 1 from public.chat_messages m where m.voice_file_id=chat_voice_files.id and m.recalled_at is null));
create function public.chat_voice_user_active() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users u where u.id=auth.uid() and not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<now()))
$$;
revoke all on function public.chat_voice_user_active() from public,anon;
grant execute on function public.chat_voice_user_active() to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('chat-voice','chat-voice',false,10485760,array['audio/ogg','audio/mp4']) on conflict(id) do nothing;
create policy voice_upload on storage.objects for insert to authenticated with check(
 bucket_id='chat-voice' and (storage.foldername(name))[2]=auth.uid()::text and public.chat_file_member(name)
 and public.chat_voice_user_active());
create policy voice_download on storage.objects for select to authenticated using(
 bucket_id='chat-voice' and exists(select 1 from public.chat_voice_files f join public.chat_messages m on m.voice_file_id=f.id
 where f.object_key=name and m.recalled_at is null and public.chat_member(m.room_id)));
create function public.chat_voice_v1(p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); rid uuid:=(p_data->>'room_id')::uuid; mid uuid:=(p_data->>'id')::uuid;
 fid uuid:=(p_data->>'file_id')::uuid; path text; size_bytes bigint; m public.chat_messages; payload jsonb;
begin
 if actor is null or not public.chat_member(rid) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 if not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(mid::text,19));
 select * into m from public.chat_messages where id=mid;
 if found then
  if m.sender_id<>actor or m.room_id<>rid or m.voice_file_id is distinct from fid then raise exception 'CHAT_UUID_CONFLICT'; end if;
  return to_jsonb(m);
 end if;
 if p_data->>'codec' not in ('opus','aac') or p_data->>'codec' is null then raise exception 'VOICE_INVALID'; end if;
 path:=rid::text||'/'||actor::text||'/'||fid::text||case when p_data->>'codec'='opus' then '.ogg' else '.m4a' end;
 select (metadata->>'size')::bigint into size_bytes from storage.objects where bucket_id='chat-voice' and name=path;
 if size_bytes is null or size_bytes not between 1 and 10485760 then raise exception 'VOICE_FILE_MISSING'; end if;
 insert into public.chat_voice_files(id,room_id,user_id,object_key,duration_ms,file_size,codec)
 values(fid,rid,actor,path,(p_data->>'duration_ms')::integer,size_bytes,p_data->>'codec');
 -- Existing send RPC preserves blocks, privacy, membership, rate limits and UUID semantics.
 payload:=public.chat_api_v1('send',jsonb_build_object('id',mid,'room_id',rid,'body','[语音]'));
 update public.chat_messages set voice_file_id=fid,voice_duration_ms=(p_data->>'duration_ms')::integer,
 voice_file_size=size_bytes,voice_storage_provider='supabase' where id=mid returning * into m;
 return to_jsonb(m);
end $$;
revoke all on function public.chat_voice_v1(jsonb) from public,anon;
grant execute on function public.chat_voice_v1(jsonb) to authenticated;

create table public.chat_calls (
 id uuid primary key, room_id uuid not null references public.chat_rooms(id),
 caller_id uuid not null references auth.users(id), callee_id uuid not null references auth.users(id),
 caller_device uuid not null, callee_device uuid,
 state text not null check(state in ('ringing','accepted','ended','declined','missed')),
 created_at timestamptz not null default now(), accepted_at timestamptz, ended_at timestamptz,
 expires_at timestamptz not null, check(caller_id<>callee_id)
);
create index chat_calls_inbox on public.chat_calls(callee_id,expires_at);
create table public.chat_call_signals (
 seq bigint generated always as identity primary key, call_id uuid not null references public.chat_calls(id),
 sender_id uuid not null references auth.users(id), nonce uuid not null, payload jsonb not null,
 created_at timestamptz not null default now(), unique(call_id,sender_id,nonce), check(octet_length(payload::text)<=65536)
);
create function public.chat_call_member(cid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.chat_calls c where c.id=cid and auth.uid() in (c.caller_id,c.callee_id) and public.chat_member(c.room_id))
$$;
revoke all on function public.chat_call_member(uuid) from public,anon;
grant execute on function public.chat_call_member(uuid) to authenticated;
alter table public.chat_calls enable row level security;
alter table public.chat_call_signals enable row level security;
revoke all on public.chat_calls,public.chat_call_signals from anon,authenticated;
grant select on public.chat_calls,public.chat_call_signals to authenticated;
create policy call_read on public.chat_calls for select to authenticated using(auth.uid() in(caller_id,callee_id) and public.chat_member(room_id));
create policy call_signal_read on public.chat_call_signals for select to authenticated using(public.chat_call_member(call_id));

create function public.chat_call_v1(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); dev uuid:=(p_data->>'device_id')::uuid; rid uuid; target uuid; cid uuid; c public.chat_calls; result jsonb;
begin
 if actor is null or dev is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='inbox' then
  select to_jsonb(x) into result from (select incoming.*,p.nickname from public.chat_calls incoming join public.chat_profiles p on p.user_id=incoming.caller_id
   where incoming.callee_id=actor and incoming.state='ringing' and incoming.expires_at>now() and public.chat_member(incoming.room_id)
   and public.chat_can_contact(incoming.caller_id,actor) order by incoming.created_at desc limit 1) x;
  return coalesce(result,'null'::jsonb);
 end if;
 cid:=(p_data->>'id')::uuid;
 if p_action='start' then
  rid:=(p_data->>'room_id')::uuid;
  if not public.chat_member(rid) or not exists(select 1 from public.chat_rooms where id=rid and kind='direct') then raise exception 'CALL_DIRECT_ONLY' using errcode='42501'; end if;
  select user_id into target from public.chat_members where room_id=rid and user_id<>actor and left_at is null;
  if target is null or not public.chat_can_contact(actor,target) or not exists(select 1 from auth.users where id=target and (banned_until is null or banned_until<now())) then raise exception 'CHAT_BLOCKED' using errcode='42501'; end if;
  -- Sorted participant locks prevent simultaneous crossed calls or two callers winning.
  perform pg_advisory_xact_lock(hashtextextended(least(actor::text,target::text),20));
  perform pg_advisory_xact_lock(hashtextextended(greatest(actor::text,target::text),20));
  select * into c from public.chat_calls where id=cid;
  if found then
   if c.caller_id=actor and c.caller_device=dev and c.room_id=rid then return to_jsonb(c); end if;
   raise exception 'CALL_DENIED' using errcode='42501';
  end if;
  if exists(select 1 from public.chat_calls where state in('ringing','accepted') and expires_at>now() and (caller_id in(actor,target) or callee_id in(actor,target))) then raise exception 'CALL_BUSY'; end if;
  if (select count(*) from public.chat_calls where caller_id=actor and created_at>now()-interval '1 minute')>=5 then raise exception 'CHAT_RATE_LIMIT'; end if;
  insert into public.chat_calls(id,room_id,caller_id,callee_id,caller_device,state,expires_at)
   values(cid,rid,actor,target,dev,'ringing',now()+interval '45 seconds') returning * into c;
  return to_jsonb(c);
 end if;
 select * into c from public.chat_calls where id=cid for update;
 if not found or actor not in(c.caller_id,c.callee_id) or not public.chat_member(c.room_id) then raise exception 'CALL_DENIED' using errcode='42501'; end if;
 if c.state in('ringing','accepted') and (c.expires_at<now() or not public.chat_can_contact(c.caller_id,c.callee_id)) then
  update public.chat_calls set state=case when state='ringing' then 'missed' else 'ended' end,ended_at=now() where id=cid returning * into c;
 end if;
 if p_action='accept' then
  if actor<>c.callee_id or (c.callee_device is not null and c.callee_device<>dev) then raise exception 'CALL_DENIED' using errcode='42501'; end if;
  if c.state='ringing' then update public.chat_calls set state='accepted',callee_device=dev,accepted_at=now(),expires_at=now()+interval '90 seconds' where id=cid returning * into c; end if;
 elsif p_action in('decline','end') then
  if (actor=c.caller_id and c.caller_device<>dev) or (actor=c.callee_id and c.callee_device is not null and c.callee_device<>dev) then raise exception 'CALL_DENIED' using errcode='42501'; end if;
  if p_action='decline' and actor<>c.callee_id then raise exception 'CALL_DENIED'; end if;
  if c.state in('ringing','accepted') then update public.chat_calls set state=case when p_action='decline' then 'declined' else 'ended' end,ended_at=now() where id=cid returning * into c; end if;
 elsif p_action in('poll','signal','heartbeat') then
  if (actor=c.caller_id and c.caller_device<>dev) or (actor=c.callee_id and c.callee_device is not null and c.callee_device<>dev) then raise exception 'CALL_DENIED' using errcode='42501'; end if;
  if p_action='signal' then
   if c.state<>'accepted' or c.callee_device is null then raise exception 'CALL_NOT_ACTIVE'; end if;
   if p_data->'payload'->>'type' not in('offer','answer','candidate','restart') or p_data->'payload'->>'type' is null then raise exception 'CALL_INVALID_SIGNAL'; end if;
   if (p_data->'payload'->>'type'='offer' and actor<>c.caller_id) or (p_data->'payload'->>'type'='answer' and actor<>c.callee_id) then raise exception 'CALL_DENIED'; end if;
   if (select count(*) from public.chat_call_signals where call_id=cid and sender_id=actor and created_at>now()-interval '1 minute')>=180 then raise exception 'CHAT_RATE_LIMIT'; end if;
   insert into public.chat_call_signals(call_id,sender_id,nonce,payload) values(cid,actor,(p_data->>'nonce')::uuid,p_data->'payload') on conflict(call_id,sender_id,nonce) do nothing;
  elsif p_action='heartbeat' and c.state='accepted' then
   update public.chat_calls set expires_at=least(now()+interval '90 seconds',created_at+interval '2 hours') where id=cid returning * into c;
  end if;
 else raise exception 'CALL_INVALID_ACTION'; end if;
 select coalesce(jsonb_agg(to_jsonb(s) order by s.seq),'[]') into result from (
  select seq,payload from public.chat_call_signals where call_id=cid and sender_id<>actor and seq>coalesce((p_data->>'after')::bigint,0) order by seq limit 200) s;
 return jsonb_build_object('call',to_jsonb(c),'signals',result);
end $$;
revoke all on function public.chat_call_v1(text,jsonb) from public,anon;
grant execute on function public.chat_call_v1(text,jsonb) to authenticated;
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  alter publication supabase_realtime add table public.chat_calls,public.chat_call_signals;
 end if;
end $$;
notify pgrst,'reload schema';
commit;

