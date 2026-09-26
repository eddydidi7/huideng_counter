-- Additive private text-note sync. Does not alter the counter protocol or feed.
begin;
create table public.note_sync_heads (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0 check(revision>=0)
);
create table public.user_notes (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null, data jsonb not null, history jsonb not null default '[]',
  revision bigint not null, conflict_of uuid,
  received_at timestamptz not null default now(),
  primary key(user_id,id)
);
create index user_notes_pull on public.user_notes(user_id,revision);
create table public.note_sync_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null, request jsonb not null, response jsonb not null,
  created_at timestamptz not null default now(), primary key(user_id,request_id)
);
alter table public.note_sync_heads enable row level security;
alter table public.user_notes enable row level security;
alter table public.note_sync_receipts enable row level security;
create policy notes_owner_read on public.user_notes for select to authenticated using(user_id=auth.uid());
create policy notes_head_owner on public.note_sync_heads for select to authenticated using(user_id=auth.uid());
create policy notes_receipt_owner on public.note_sync_receipts for select to authenticated using(user_id=auth.uid());
revoke all on public.user_notes,public.note_sync_heads,public.note_sync_receipts from anon,authenticated;
grant select on public.user_notes,public.note_sync_heads to authenticated;

create function public.sync_note_v1(p_request uuid,p_id uuid,p_base bigint,p_data jsonb,p_history jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  u uuid := auth.uid(); req jsonb; prior record; current_note public.user_notes;
  saved public.user_notes; target uuid; rev bigint; response jsonb; conflict boolean;
begin
  if u is null then raise exception 'Authentication required'; end if;
  if p_request is null or p_id is null or p_base is null or p_base<0
     or p_data is null or jsonb_typeof(p_data)<>'object'
     or jsonb_typeof(p_data->'title') is distinct from 'string'
     or jsonb_typeof(p_data->'body') is distinct from 'string'
     or p_history is null or jsonb_typeof(p_history)<>'array'
     or octet_length(p_data::text)>2000000 or octet_length(p_history::text)>16000000
     or not (p_data ?& array['isPinned','isFavorite','isArchived','createdAt','updatedAt','deletedAt'])
     or jsonb_typeof(p_data->'isPinned') is distinct from 'number'
     or jsonb_typeof(p_data->'isFavorite') is distinct from 'number'
     or jsonb_typeof(p_data->'isArchived') is distinct from 'number'
     or (p_data->>'isPinned') not in ('0','1') or (p_data->>'isFavorite') not in ('0','1')
     or (p_data->>'isArchived') not in ('0','1')
     or jsonb_typeof(p_data->'createdAt') is distinct from 'string'
     or jsonb_typeof(p_data->'updatedAt') is distinct from 'string'
  then raise exception 'Invalid note'; end if;
  perform (p_data->>'createdAt')::timestamptz, (p_data->>'updatedAt')::timestamptz,
    (p_data->>'deletedAt')::timestamptz;
  if exists(select 1 from jsonb_array_elements(p_history) h where
    jsonb_typeof(h->'id') is distinct from 'string' or
    jsonb_typeof(h->'payload') is distinct from 'string' or
    jsonb_typeof(h->'createdAt') is distinct from 'string')
  then raise exception 'Invalid history'; end if;
  req := jsonb_build_object('id',p_id,'base',p_base,'data',p_data,'history',p_history);
  insert into public.note_sync_heads(user_id) values(u) on conflict do nothing;
  -- A per-user transactional head prevents a cursor from skipping late commits.
  perform 1 from public.note_sync_heads where user_id=u for update;
  select r.request,r.response into prior from public.note_sync_receipts r where r.user_id=u and r.request_id=p_request;
  if found then
    if prior.request<>req then raise exception 'Request UUID reused'; end if;
    return prior.response;
  end if;
  select * into current_note from public.user_notes where user_id=u and id=p_id;
  if current_note.id is null and p_base<>0 then raise exception 'Missing base note'; end if;
  conflict := current_note.id is not null and current_note.revision<>p_base;
  target := case when conflict then p_request else p_id end;
  if conflict and exists(select 1 from public.user_notes where user_id=u and id=target)
  then raise exception 'Conflict UUID collision'; end if;
  update public.note_sync_heads set revision=revision+1 where user_id=u returning revision into rev;
  insert into public.user_notes(user_id,id,data,history,revision,conflict_of)
    values(u,target,p_data,p_history,rev,case when conflict then p_id else null end)
    on conflict(user_id,id) do update set data=excluded.data,history=excluded.history,
      revision=excluded.revision,received_at=now()
    returning * into saved;
  response:=jsonb_build_object('saved',to_jsonb(saved),'conflict',conflict,'current',case when conflict then to_jsonb(current_note) else null end);
  insert into public.note_sync_receipts(user_id,request_id,request,response) values(u,p_request,req,response);
  return response;
end $$;

create function public.pull_notes_v1(p_after bigint default 0)
returns setof public.user_notes language sql stable security invoker set search_path=pg_catalog,public as $$
 select * from public.user_notes where user_id=auth.uid() and revision>greatest(p_after,0)
 order by revision limit 100
$$;
revoke all on function public.sync_note_v1(uuid,uuid,bigint,jsonb,jsonb) from public,anon;
revoke all on function public.pull_notes_v1(bigint) from public,anon;
grant execute on function public.sync_note_v1(uuid,uuid,bigint,jsonb,jsonb) to authenticated;
grant execute on function public.pull_notes_v1(bigint) to authenticated;
commit;
