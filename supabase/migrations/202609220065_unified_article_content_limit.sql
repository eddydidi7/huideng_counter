-- Notes and Redbook use the same maximum: 5,000,000 Unicode characters.
-- This is non-destructive: it only relaxes checks and keeps every existing
-- post, reply, attachment, reaction and author-edit history intact.
begin;

alter table public.forum_posts drop constraint if exists forum_posts_body_check;
alter table public.forum_posts add constraint forum_posts_body_check
  check (char_length(body) between 0 and 5000000);

do $$
declare definition text;
begin
  -- The create path is v3 -> v2 -> v1.  All three functions must accept the
  -- same JSON payload, otherwise a long body fails in an inner legacy layer.
  definition := pg_get_functiondef('public.forum_action_v1(text,jsonb)'::regprocedure);
  definition := replace(definition, 'octet_length(p_data::text)>100000', 'octet_length(p_data::text)>67108864');
  definition := replace(definition, 'length(content)>20000', 'char_length(content)>5000000');
  execute definition;

  definition := pg_get_functiondef('public.forum_action_v2(text,jsonb)'::regprocedure);
  definition := replace(definition, 'octet_length(p_data::text)>2000000', 'octet_length(p_data::text)>67108864');
  execute definition;

  definition := pg_get_functiondef('public.forum_action_v3(text,jsonb)'::regprocedure);
  definition := replace(definition, 'octet_length(p_data::text)>2000000', 'octet_length(p_data::text)>67108864');
  execute definition;

  definition := pg_get_functiondef('public.forum_author_write_v1(jsonb)'::regprocedure);
  definition := replace(definition, 'octet_length(p_data::text)>2000000', 'octet_length(p_data::text)>67108864');
  definition := replace(definition, 'length(content) not between 0 and 20000', 'char_length(content) not between 0 and 5000000');
  definition := replace(definition, 'length(content) not between 1 and 20000', 'char_length(content) not between 1 and 5000000');
  execute definition;

  -- The home feed deliberately returns an excerpt only. Full text continues
  -- to be fetched by detail(), so a five-million-character post cannot make
  -- the two-column feed download or render the entire article.
  definition := pg_get_functiondef('public.forum_feed_v2(text,text,text,integer)'::regprocedure);
  if position('char_length(p.body)>4000' in definition) = 0 then
    definition := replace(
      definition,
      'p.title,p.body,p.tags',
      'p.title,case when char_length(p.body)>4000 then left(p.body,4000) else p.body end as body,p.tags'
    );
  end if;
  execute definition;
end $$;

comment on column public.forum_posts.body is
  'Body content shares the Notes 5,000,000-character limit; list APIs return an excerpt.';
notify pgrst, 'reload schema';
commit;
