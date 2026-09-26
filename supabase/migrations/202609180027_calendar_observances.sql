begin;
-- Requires 023. Existing links.save role checks, audit and version locking apply.
create or replace function public.valid_calendar_observances(v jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare e jsonb; k text; seen text[] := array[]::text[];
begin
  if v is null then return true; end if;
  if jsonb_typeof(v) is distinct from 'object' or v->'schema' is distinct from '1'::jsonb or jsonb_typeof(v->'entries') is distinct from 'array' then return false; end if;
  if jsonb_array_length(v->'entries') > 500 then return false; end if;
  foreach k in array array['title_zh','title_en','note_zh','note_en'] loop
    if jsonb_typeof(v->k) is distinct from 'string' or length(v->>k)>10000 then return false; end if;
  end loop;
  for e in select value from jsonb_array_elements(v->'entries') loop
    foreach k in array array['id','zh','en','source','url'] loop
      if jsonb_typeof(e->k) is distinct from 'string' or length(e->>k)>2000 then return false; end if;
    end loop;
    if e->>'id'='' or btrim(e->>'zh')='' or (e->>'id')=any(seen) then return false; end if;
    seen := array_append(seen,e->>'id');
    foreach k in array array['month','day','end_day'] loop
      if jsonb_typeof(e->k) is distinct from 'number' or (e->>k) !~ '^[0-9]{1,2}$' then return false; end if;
    end loop;
    if (e->>'month')::int not between 0 and 12 or (e->>'day')::int not between 1 and 30 or (e->>'end_day')::int not between (e->>'day')::int and 30 then return false; end if;
    if jsonb_typeof(e->'enabled') is distinct from 'boolean' or jsonb_typeof(e->'include_leap') is distinct from 'boolean' or coalesce(e->>'repeat','') not in ('both','first','second') then return false; end if;
    if e->>'url'<>'' and ((e->>'url') !~ '^https://[^/@[:space:]?#]+([/?#].*)?$' or (e->>'url') ~ '[[:space:]]') then return false; end if;
  end loop;
  return true;
end $$;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.app_links'::regclass and conname='app_links_observances_valid') then
    alter table public.app_links add constraint app_links_observances_valid check(public.valid_calendar_observances(calendar_traditions->'observances'));
  end if;
end $$;
commit;
