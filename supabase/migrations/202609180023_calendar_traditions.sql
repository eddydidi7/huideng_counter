begin;
-- Editable calendar copy; existing app_links RLS and administrator audit apply.
create or replace function public.valid_calendar_traditions(v jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
declare entry jsonb; field jsonb; k text;
begin
  if v = '{}'::jsonb then return true; end if;
  if jsonb_typeof(v) is distinct from 'object'
    or jsonb_typeof(v->'texts') is distinct from 'object'
    or jsonb_typeof(v->'days') is distinct from 'array' then return false; end if;
  if jsonb_array_length(v->'days') <> 30 then return false; end if;
  foreach k in array array['heading','tableTitle','haircutLabel','washingLabel','annual','infant','tableAnnual','handling','source','caution','specialPurify','specialWisdom'] loop
    field := v->'texts'->k;
    if jsonb_typeof(field->'zh') is distinct from 'string' or jsonb_typeof(field->'en') is distinct from 'string'
      or length(field->>'zh') > 10000 or length(field->>'en') > 10000 then return false; end if;
  end loop;
  for entry in select value from jsonb_array_elements(v->'days') loop
    foreach k in array array['haircut','washing'] loop
      field := entry->k;
      if jsonb_typeof(field->'zh') is distinct from 'string' or jsonb_typeof(field->'en') is distinct from 'string'
        or length(field->>'zh') > 10000 or length(field->>'en') > 10000 then return false; end if;
    end loop;
  end loop;
  return true;
end $$;
alter table public.app_links add column if not exists calendar_traditions jsonb not null default '{}'::jsonb;
do $$
declare definition text; old_assignment text := 'else link.published_notes end,version=version+1';
begin
  if not exists (select 1 from pg_constraint where conrelid='public.app_links'::regclass and conname='app_links_calendar_traditions_valid') then
    alter table public.app_links add constraint app_links_calendar_traditions_valid check(public.valid_calendar_traditions(calendar_traditions));
  end if;
  definition := pg_get_functiondef('public.huideng_admin_dispatch(uuid,text,jsonb,uuid)'::regprocedure);
  if strpos(definition, 'calendar_traditions=') = 0 then
    if strpos(definition, old_assignment) = 0 then raise exception '请先执行后台005、007、008迁移；未修改现有发布函数'; end if;
    execute replace(definition, old_assignment,
      'else link.published_notes end,calendar_traditions=case when payload ? ''calendar_traditions'' then payload->''calendar_traditions'' else link.calendar_traditions end,version=version+1');
  end if;
end $$;
commit;
