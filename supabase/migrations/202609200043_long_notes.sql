begin;
-- Additive chunk transport. Existing notes, receipts and version checks remain.
create or replace function public.note_text_characters(p_body text) returns bigint language plpgsql immutable set search_path=pg_catalog as $$
declare d jsonb; n bigint;
begin
 begin d:=p_body::jsonb; exception when others then return char_length(p_body); end;
 if jsonb_typeof(d)='array' and not exists(select 1 from jsonb_array_elements(d) e where jsonb_typeof(e)<>'object' or not(e ? 'insert')) then
  select coalesce(sum(case when jsonb_typeof(e->'insert')='string' then char_length(e->>'insert') else 0 end),0) into n from jsonb_array_elements(d) e; return n;
 end if;
 return char_length(p_body);
end $$;
do $$ declare definition text; begin
 definition:=pg_get_functiondef('public.sync_note_v1(uuid,uuid,bigint,jsonb,jsonb)'::regprocedure);
 definition:=replace(definition,'octet_length(p_data::text)>2000000','octet_length(p_data::text)>64000000');
 if position('public.note_text_characters' in definition)=0 then
  definition:=replace(definition,'or octet_length(p_history::text)>16000000','or public.note_text_characters(p_data->>''body'')>5000000 or octet_length(p_history::text)>16000000');
 end if;
 definition:=replace(definition,'history=excluded.history,','history=case when excluded.history=''[]''::jsonb then public.user_notes.history else excluded.history end,');
 execute definition;
end $$;
create table if not exists public.note_committed_versions (
 user_id uuid not null references auth.users(id), note_id uuid not null, revision bigint not null, data jsonb not null,
 created_at timestamptz not null default now(), primary key(user_id,note_id,revision)
);
alter table public.note_committed_versions enable row level security;
revoke all on public.note_committed_versions from anon,authenticated;
create or replace function public.archive_note_version() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 insert into public.note_committed_versions(user_id,note_id,revision,data) values(old.user_id,old.id,old.revision,old.data) on conflict do nothing; return new;
end $$;
do $$ begin
 if not exists(select 1 from pg_trigger where tgname='archive_note_version' and tgrelid='public.user_notes'::regclass) then
  create trigger archive_note_version before update on public.user_notes for each row execute function public.archive_note_version();
 end if;
end $$;
create table if not exists public.note_transfer_parts (
 user_id uuid not null references auth.users(id), request_id uuid not null, part integer not null check(part between 0 and 511),
 content text not null check(octet_length(content)<=524288), content_hash text not null, created_at timestamptz not null default now(), primary key(user_id,request_id,part)
);
create table if not exists public.note_transfer_results (
 user_id uuid not null references auth.users(id),request_id uuid not null,result text not null,primary key(user_id,request_id)
);
alter table public.note_transfer_parts enable row level security;
alter table public.note_transfer_results enable row level security;
revoke all on public.note_transfer_parts,public.note_transfer_results from anon,authenticated;
create or replace function public.note_transfer_v2(p_action text,p_request uuid,p_part integer default 0,p_content text default '') returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare u uuid:=auth.uid(); payload jsonb; answer jsonb; stored text; n integer;
begin
 if u is null then raise exception 'Authentication required'; end if;
 if to_regprocedure('public.sync_registered_user()') is not null then
  if not public.sync_registered_user() then raise exception 'Authentication required'; end if;
 end if;
 if p_request is null then raise exception 'Invalid request'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text||p_request::text,43));
 if p_action='part' then
  if p_part not between 0 and 511 or octet_length(p_content)>524288 then raise exception 'Invalid chunk'; end if;
  select content_hash into stored from public.note_transfer_parts where user_id=u and request_id=p_request and part=p_part;
  if found and stored<>encode(sha256(convert_to(p_content,'UTF8')),'hex') then raise exception 'Request UUID reused'; end if;
  -- Bound incomplete per-account uploads without deleting any user data.
  if not found and coalesce((select sum(octet_length(content)) from public.note_transfer_parts where user_id=u),0)+octet_length(p_content)>256000000 then raise exception 'Transfer quota exceeded'; end if;
  insert into public.note_transfer_parts(user_id,request_id,part,content,content_hash) values(u,p_request,p_part,p_content,encode(sha256(convert_to(p_content,'UTF8')),'hex')) on conflict do nothing;
  return jsonb_build_object('ok',true);
 elsif p_action='finish' then
  select result into stored from public.note_transfer_results where user_id=u and request_id=p_request;
  if not found then
   select count(*),string_agg(content,'' order by part) into n,stored from public.note_transfer_parts where user_id=u and request_id=p_request;
   if n<>p_part or n=0 or (select max(part) from public.note_transfer_parts where user_id=u and request_id=p_request)<>n-1 then raise exception 'Incomplete chunks'; end if;
   payload:=stored::jsonb;
   if (payload->>'p_request')::uuid<>p_request then raise exception 'Invalid request'; end if;
   answer:=public.sync_note_v1(p_request,(payload->>'p_id')::uuid,(payload->>'p_base')::bigint,payload->'p_data',payload->'p_history');
   stored:=answer::text;
   insert into public.note_transfer_results values(u,p_request,stored);
   update public.note_transfer_parts set content='' where user_id=u and request_id=p_request;
  end if;
  return jsonb_build_object('parts',ceil(char_length(stored)/131072.0));
 elsif p_action='result' then
  select result into stored from public.note_transfer_results where user_id=u and request_id=p_request;
  if not found or p_part<0 then raise exception 'Missing result'; end if;
  return jsonb_build_object('content',substr(stored,p_part*131072+1,131072));
 else raise exception 'Invalid action'; end if;
end $$;
create or replace function public.pull_note_heads_v2(p_after bigint default 0) returns jsonb language sql stable security invoker set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') from (select id,revision from public.user_notes where user_id=auth.uid() and revision>greatest(p_after,0) order by revision limit 100)t
$$;
create or replace function public.pull_note_part_v2(p_id uuid,p_revision bigint,p_part integer) returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare doc text;
begin
 select (case when octet_length(data::text)>100000 then jsonb_set(to_jsonb(n),'{history}','[]') else to_jsonb(n) end)::text into doc from public.user_notes n where user_id=auth.uid() and id=p_id and revision=p_revision;
 if doc is null or p_part<0 then raise exception 'Note changed; retry'; end if;
 return jsonb_build_object('content',substr(doc,p_part*131072+1,131072),'parts',ceil(char_length(doc)/131072.0));
end $$;
revoke all on function public.note_transfer_v2(text,uuid,integer,text),public.pull_note_heads_v2(bigint),public.pull_note_part_v2(uuid,bigint,integer) from public,anon;
grant execute on function public.note_transfer_v2(text,uuid,integer,text),public.pull_note_heads_v2(bigint),public.pull_note_part_v2(uuid,bigint,integer) to authenticated;
notify pgrst,'reload schema';
commit;
