-- No historical messages or objects are deleted by this migration.
-- Recall erases payload, retaining an ID-only sync tombstone to prevent retries
-- resurrecting a message. Storage cleanup is queued, never a SQL objects DELETE.
begin;
create table if not exists public.chat_attachment_retirements (
 bucket text not null, object_key text not null, message_id uuid not null,
 requested_at timestamptz not null default now(),
 checked_at timestamptz not null default 'epoch',
 state text not null default 'pending' check(state in ('pending','shared','deleting','deleted')),
 primary key(bucket,object_key,message_id)
);
alter table public.chat_attachment_retirements enable row level security;
revoke all on public.chat_attachment_retirements from public,anon,authenticated;

do $$ begin
 if to_regprocedure('public.chat_api_before_recall(text,jsonb)') is null then
  alter function public.chat_api_v1(text,jsonb) rename to chat_api_before_recall;
 end if;
end $$;
revoke all on function public.chat_api_before_recall(text,jsonb) from public,anon,authenticated;

create or replace function public.chat_api_v1(p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); rid uuid; m public.chat_messages; result jsonb; path text;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor
   and (banned_until is null or banned_until<now()))
 then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='rooms' then
  result:=public.chat_api_before_recall(p_action,p_data);
  return coalesce((select jsonb_agg(e.value || jsonb_build_object('preview',coalesce((
   select left(x.body,80) from public.chat_messages x where x.room_id=(e.value->>'id')::uuid
   and x.recalled_at is null order by x.created_at desc,x.id desc limit 1),'')) order by e.ord)
   from jsonb_array_elements(result) with ordinality e(value,ord)),'[]');
 end if;
 if p_action not in ('recall','messages','message_presence') then
  return public.chat_api_before_recall(p_action,p_data);
 end if;
 rid:=(p_data->>'room_id')::uuid;
 if p_action='recall' then
  -- Ownership, not a time window or moderator power. Serialise with send.
  perform 1 from public.chat_rooms where id=rid for update;
  select * into m from public.chat_messages where id=(p_data->>'id')::uuid and room_id=rid for update;
  if not found or m.sender_id<>actor or m.is_system then
   raise exception 'CHAT_RECALL_DENIED' using errcode='42501'; end if;
  if m.recalled_at is not null then return '{}'::jsonb; end if;
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
   recalled_at=clock_timestamp(),updated_at=clock_timestamp() where id=m.id;
  update public.chat_group_content set title='内容',body='',payload='{}',deleted_at=clock_timestamp()
   where group_id=rid and kind='highlight' and payload->>'message_id'=m.id::text;
  -- Wake room-list subscribers too; preview is recomputed from live messages.
  update public.chat_rooms set updated_at=clock_timestamp() where id=rid;
  return '{}'::jsonb;
 end if;
 if not public.chat_member(rid) then raise exception 'CHAT_NOT_MEMBER' using errcode='42501'; end if;
 if p_action='message_presence' then
  if jsonb_typeof(p_data->'ids') is distinct from 'array' or jsonb_array_length(p_data->'ids')>500
   then raise exception 'CHAT_INVALID_MESSAGE'; end if;
  return coalesce((select jsonb_agg(id) from public.chat_messages where room_id=rid
   and recalled_at is null and id in(select value::uuid from jsonb_array_elements_text(p_data->'ids'))),'[]');
 end if;
 return coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from (
  select x.*,p.nickname from public.chat_messages x join public.chat_profiles p on p.user_id=x.sender_id
  where x.room_id=rid and x.recalled_at is null
   and (p_data->>'before' is null or x.created_at<(p_data->>'before')::timestamptz)
  order by x.created_at desc,x.id desc limit 100)t),'[]');
end $$;
revoke all on function public.chat_api_v1(text,jsonb) from public,anon;
grant execute on function public.chat_api_v1(text,jsonb) to authenticated;

-- Conservative reference scan. Unknown references retain the object; nothing
-- deletes storage.objects metadata directly. The service uses Storage.remove.
create or replace function public.chat_object_referenced(p_bucket text,p_key text)
returns boolean language plpgsql security definer set search_path='' as $$
declare tab text; found_ref boolean;
begin
 if exists(select 1 from public.chat_messages m where m.recalled_at is null and
  ((p_bucket='chat-files' and m.attachment_path=p_key) or (p_bucket='chat-voice' and
   exists(select 1 from public.chat_voice_files f where f.id=m.voice_file_id and f.object_key=p_key)))) then return true; end if;
 -- Include snapshots and history: a user may still restore a saved reference.
 foreach tab in array array['user_notes','note_committed_versions','note_web_snapshots',
  'forum_posts','forum_attachments','community_files','saved_content',
  'personal_library_assets','personal_library_entries','chat_group_content'] loop
  if to_regclass('public.'||tab) is not null then
   execute format('select exists(select 1 from public.%I t where strpos(to_jsonb(t)::text,$1)>0)',tab)
     into found_ref using p_key;
   if found_ref then return true; end if;
  end if;
 end loop;
 return false;
end $$;
revoke all on function public.chat_object_referenced(text,text) from public,anon,authenticated;

-- Serialize reference writes with claiming a retirement, closing the gap
-- between the reference check and the external Storage removal request.
create or replace function public.guard_retired_chat_reference() returns trigger
language plpgsql security definer set search_path='' as $$
declare item record; content text;
begin
 perform pg_advisory_xact_lock(57057);
 content:=to_jsonb(new)::text;
 for item in select distinct bucket,object_key from public.chat_attachment_retirements where state in ('deleting','deleted') loop
  if strpos(content,item.object_key)>0 or (tg_table_name='chat_messages' and
   exists(select 1 from public.chat_voice_files f where f.id::text=to_jsonb(new)->>'voice_file_id' and f.object_key=item.object_key))
  then raise exception 'CHAT_ATTACHMENT_UNAVAILABLE' using errcode='23514'; end if;
 end loop;
 return new;
end $$;
revoke all on function public.guard_retired_chat_reference() from public,anon,authenticated;
do $$ declare tab text; begin
 foreach tab in array array['chat_messages','user_notes','note_committed_versions','note_web_snapshots',
  'forum_posts','forum_attachments','community_files','saved_content','personal_library_assets','personal_library_entries','chat_group_content'] loop
  if to_regclass('public.'||tab) is not null then
   execute format('drop trigger if exists guard_retired_chat_reference on public.%I',tab);
   execute format('create trigger guard_retired_chat_reference before insert or update on public.%I for each row execute function public.guard_retired_chat_reference()',tab);
  end if;
 end loop;
end $$;

create or replace function public.huideng_chat_cleanup(actor uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare item record; items jsonb:='[]';
begin
 if not exists(select 1 from admin_private.members where user_id=actor and enabled and role in ('super_admin','admin'))
  then raise exception 'forbidden' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(57057);
 if p_action='completed' then
  update public.chat_attachment_retirements set state='deleted'
   where bucket=p_data->>'bucket' and object_key=p_data->>'object_key' and state='deleting';
  return '{}';
 end if;
 if p_action<>'claim' then raise exception 'invalid action'; end if;
 for item in select bucket,object_key from public.chat_attachment_retirements
  where state<>'deleted' and requested_at<now()-interval '1 day'
  group by bucket,object_key order by min(checked_at),bucket,object_key limit 10 loop
  update public.chat_attachment_retirements set checked_at=clock_timestamp() where bucket=item.bucket and object_key=item.object_key;
  if public.chat_object_referenced(item.bucket,item.object_key) then
   update public.chat_attachment_retirements set state='shared' where bucket=item.bucket and object_key=item.object_key;
  else
   update public.chat_attachment_retirements set state='deleting' where bucket=item.bucket and object_key=item.object_key;
   items:=items||jsonb_build_array(jsonb_build_object('bucket',item.bucket,'object_key',item.object_key));
  end if;
 end loop;
 return jsonb_build_object('files',items);
end $$;
revoke all on function public.huideng_chat_cleanup(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.huideng_chat_cleanup(uuid,text,jsonb) to service_role;
commit;
