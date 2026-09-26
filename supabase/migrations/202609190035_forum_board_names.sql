-- Rename display labels only. Preserve IDs, posts, permissions and enabled flags.
-- feedback is the legacy persisted ID used by the General board.
begin;
update public.forum_categories set name_zh='综合',name_en='General',position=1 where id='feedback';
update public.forum_categories set name_zh='活动',name_en='Activities',position=2 where id='practice';
update public.forum_categories set name_zh='学修',name_en='Study',position=3 where id='study';
update public.forum_categories set position=4 where id='resources';
commit;
