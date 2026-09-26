-- Run only in a disposable Supabase test project AFTER the migration.
-- Rolls back all fixtures. An exception means the gate failed.
begin;
insert into auth.users(id,email) values
 ('aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa','counter-test-a@example.invalid'),
 ('bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb','counter-test-b@example.invalid');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}',true);
do $$ declare first_result jsonb; replay jsonb; ev jsonb; r jsonb; begin
  first_result := public.counter_put_document('project','11111111-1111-4111-8111-111111111111',0,
    '{"name":"A project","image_key":null,"deleted_at":null}', '10000000-0000-4000-8000-000000000001');
  if first_result->>'status' <> 'accepted' then raise exception 'project insert failed'; end if;
  replay := public.counter_put_document('project','11111111-1111-4111-8111-111111111111',0,
    '{"name":"A project","image_key":null,"deleted_at":null}', '10000000-0000-4000-8000-000000000001');
  if replay <> first_result then raise exception 'receipt replay failed'; end if;
  r := public.counter_put_document('project','11111111-1111-4111-8111-111111111111',0,
    '{"name":"Stale edit"}', '10000000-0000-4000-8000-000000000002');
  if r->>'status' <> 'conflict' then raise exception 'CAS failed'; end if;
  ev := '{"user_id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","id":"20000000-0000-4000-8000-000000000001",
    "project_id":"11111111-1111-4111-8111-111111111111","delta":1,"count_after":1,
    "created_at":"2026-09-15T00:00:00Z","updated_at":"2026-09-15T00:00:00Z","occurred_at":"2026-09-15T00:00:00Z",
    "device_id":"30000000-0000-4000-8000-000000000001","source":"screen"}';
  first_result := public.counter_push_event(ev);
  if first_result->>'status' <> 'accepted' then raise exception 'event insert failed'; end if;
  if public.counter_push_event(ev) <> first_result then raise exception 'duplicate event failed'; end if;
  r := public.counter_push_event(ev || '{"delta":2}');
  if r->>'status' <> 'conflict' then raise exception 'UUID collision not detected'; end if;
  r := public.counter_push_event(ev || '{"id":"20000000-0000-4000-8000-000000000002","device_id":"30000000-0000-4000-8000-000000000002"}');
  if (select event_balance from public.counter_totals) <> 2 then raise exception 'event union failed'; end if;
  if (select count(*) from public.counter_pull(0,200)) <> 3 then raise exception 'feed includes duplicate or missing rows'; end if;
  begin
    delete from public.counter_events;
    raise exception 'direct delete unexpectedly succeeded';
  exception when insufficient_privilege then null; end;
end $$;

select set_config('request.jwt.claims','{"sub":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}',true);
do $$ begin
  if exists(select 1 from public.counter_projects) or exists(select 1 from public.counter_events)
    or exists(select 1 from public.counter_documents) or exists(select 1 from public.counter_pull(0,200))
    or exists(select 1 from public.counter_totals) or exists(select 1 from public.counter_mutation_receipts)
    then raise exception 'RLS cross-account read'; end if;
  begin
    perform public.counter_push_event('{"user_id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"}');
    raise exception 'cross-account event accepted';
  exception when insufficient_privilege then null; end;
end $$;
set local role anon;
select set_config('request.jwt.claims','{}',true);
do $$ begin
  begin
    perform public.counter_push_event('{}');
    raise exception 'anonymous RPC allowed';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
-- Additionally required: two real users test Storage upload/read and guessed paths,
-- delayed concurrent transactions test feed order, expired JWT, image replacement,
-- and Android/Windows offline restart + account switching. Not covered by this SQL.
