begin;

-- Only relax empty-post validation: no historical post rows are rewritten.
-- Keep the installed functions' auth, ownership, version, length and media checks.
do $patch$
declare definition text; signature text; old_rule text; new_rule text;
begin
  signature := 'public.forum_action_v2(text,jsonb)';
  definition := pg_get_functiondef(signature::regprocedure);
  old_rule := 'if coalesce(btrim(p_data->>''body''),'''')='''' and jsonb_array_length';
  new_rule := 'if coalesce(btrim(p_data->>''title''),'''')='''' and coalesce(btrim(p_data->>''body''),'''')='''' and jsonb_array_length';
  if position(new_rule in definition) = 0 then
    if position(old_rule in definition) = 0 then
      raise exception 'Cannot locate empty-post validation in %; migration not applied', signature;
    end if;
    execute replace(definition, old_rule, new_rule);
  end if;

  foreach signature in array array[
    'public.forum_author_write_v1(jsonb)',
    'public.forum_author_write_v2(jsonb)'
  ] loop
    definition := pg_get_functiondef(signature::regprocedure);
    old_rule := 'if content='''' and cardinality(';
    new_rule := 'if heading='''' and content='''' and cardinality(';
    if position(new_rule in definition) = 0 then
      if position(old_rule in definition) = 0 then
        raise exception 'Cannot locate empty-post validation in %; migration not applied', signature;
      end if;
      execute replace(definition, old_rule, new_rule);
    end if;
  end loop;
end $patch$;

notify pgrst, 'reload schema';
commit;
