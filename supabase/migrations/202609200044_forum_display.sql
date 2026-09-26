begin;
-- Atomically relax length checks, preserving all posts and associations.
alter table public.forum_posts drop constraint if exists forum_posts_title_check;
alter table public.forum_posts add constraint forum_posts_title_check check(length(title) between 0 and 160);
alter table public.forum_posts drop constraint if exists forum_posts_body_check;
alter table public.forum_posts add constraint forum_posts_body_check check(length(body) between 0 and 20000);
do $$ declare definition text; begin
 definition:=pg_get_functiondef('public.forum_action_v1(text,jsonb)'::regprocedure);
 definition:=replace(definition,'select id,author_name,author_avatar_url','select id,author_user_id,author_name,author_avatar_url');
 definition:=replace(definition,'length(heading) not between 1 and 160','length(heading) not between 0 and 160');
 definition:=replace(definition,'or length(content)<1 or','or (length(content)<1 and p_action<>''create'') or');
 execute definition;
 definition:=pg_get_functiondef('public.forum_feed_v2(text,text,text,integer)'::regprocedure);
 definition:=replace(definition,'select p.id,p.author_name,','select p.id,p.author_user_id,p.author_name,');
 execute definition;
 definition:=pg_get_functiondef('public.forum_action_v2(text,jsonb)'::regprocedure);
 if position('empty_post' in definition)=0 then
  definition:=replace(definition,'if p_action=''create'' then','if p_action=''create'' then
  if coalesce(btrim(p_data->>''body''),'''')='''' and jsonb_array_length(coalesce(p_data->''attachments'',''[]''))=0 then raise exception ''empty_post''; end if;');
 end if;
 definition:=replace(definition,'to_jsonb(t)-''author_user_id''','to_jsonb(t)');
 execute definition;
 definition:=pg_get_functiondef('public.forum_author_write_v1(jsonb)'::regprocedure);
 definition:=replace(definition,'length(heading) not between 1 and 160','length(heading) not between 0 and 160');
 definition:=replace(definition,'length(content) not between 1 and 20000','length(content) not between 0 and 20000');
 if position('empty_post' in definition)=0 then
  definition:=replace(definition,'update public.forum_posts set title=heading','if content='''' and cardinality(p.image_urls)=0 and not exists(select 1 from public.forum_attachments where post_id=p.id) then raise exception ''empty_post''; end if;
  update public.forum_posts set title=heading');
 end if;
 execute definition;
 definition:=pg_get_functiondef('public.forum_action_v3(text,jsonb)'::regprocedure);
 definition:=replace(definition,'select id,author_name,body,created_at from public.forum_replies','select id,user_id,author_name,body,created_at from public.forum_replies');
 execute definition;
end $$;
-- Guests may see only the current avatar of an author with public posts.
create or replace function public.public_forum_avatar(p_user_id uuid) returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select avatar_path from public.chat_profiles c where c.user_id=p_user_id and exists(select 1 from public.forum_posts f join public.forum_categories cat on cat.id=f.category_id and cat.enabled where f.author_user_id=c.user_id and f.visibility='published' and f.access_level='public' and f.deleted_at is null)
$$;
create or replace function public.public_forum_avatar_visible(p_path text) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.chat_profiles c where c.avatar_path=p_path and public.public_forum_avatar(c.user_id)=p_path)
$$;
revoke all on function public.public_forum_avatar(uuid),public.public_forum_avatar_visible(text) from public;
grant execute on function public.public_forum_avatar(uuid),public.public_forum_avatar_visible(text) to anon,authenticated;
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='public_forum_current_avatar') then
 create policy public_forum_current_avatar on storage.objects for select to anon using(bucket_id='chat-avatars' and public.public_forum_avatar_visible(name));
 end if;
end $$;
notify pgrst,'reload schema';
commit;
