-- Read-only: run before migration 202609170009. Does not access user content.
select n.nspname as schema_name, c.relname as object_name, c.relkind,
       c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('forum_categories','forum_posts');

select table_name,column_name,data_type,is_nullable
from information_schema.columns
where table_schema='public' and table_name in ('forum_categories','forum_posts')
order by table_name,ordinal_position;

select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='forum_feed_v1';

-- Only if all three result sets are empty, use the new-table migration.
-- If any object exists, inspect and adapt incrementally; never drop it to retry.
