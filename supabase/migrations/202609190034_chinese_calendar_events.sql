begin;
-- Optional data-only extension. Existing calendar content remains unchanged.
create or replace function public.valid_chinese_calendar_events(v jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare e record; k text; d date;
begin
  if v is null then return true; end if;
  if jsonb_typeof(v) is distinct from 'object' then return false; end if;
  if (select count(*) from jsonb_each(v)) > 2000 then return false; end if;
  for e in select key,value from jsonb_each(v) loop
    if e.key !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return false; end if;
    begin d := e.key::date; exception when others then return false; end;
    if to_char(d,'YYYY-MM-DD') <> e.key then return false; end if;
    if jsonb_typeof(e.value) is distinct from 'object' then return false; end if;
    foreach k in array array['zh','en'] loop
      if jsonb_typeof(e.value->k) is distinct from 'string' or length(e.value->>k) > 2000 then return false; end if;
    end loop;
  end loop;
  return true;
end $$;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.app_links'::regclass and conname='app_links_chinese_events_valid') then
    alter table public.app_links add constraint app_links_chinese_events_valid check(public.valid_chinese_calendar_events(calendar_traditions->'chinese_events'));
  end if;
end $$;
commit;
