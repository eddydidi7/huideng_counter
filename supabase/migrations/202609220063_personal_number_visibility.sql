-- Personal numbers are the public-facing account identifier. UUIDs remain
-- internal keys for every relationship and historic author reference.
begin;
do $$
declare definition text;
begin
  if to_regprocedure('public.community_profile_v1(uuid,jsonb)') is null then
    raise exception 'Missing prerequisite: community_profile_v1';
  end if;
  definition := pg_get_functiondef('public.community_profile_v1(uuid,jsonb)'::regprocedure);
  definition := replace(
    definition,
    'case when coalesce(x.show_account,false) or c.user_id=auth.uid() then to_jsonb(c)->''personal_number'' else null end',
    'to_jsonb(c)->''personal_number'''
  );
  if position('''personal_number'',to_jsonb(c)->''personal_number''' in definition) = 0 then
    raise exception 'Could not update personal-number projection safely';
  end if;
  execute definition;
end $$;
notify pgrst,'reload schema';
commit;
