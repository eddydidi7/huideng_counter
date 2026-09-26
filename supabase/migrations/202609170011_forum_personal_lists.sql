-- If 010 was already applied, this adds personal post and bookmark lists.
begin;
create or replace function public.forum_action_v1(p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
 actor uuid:=auth.uid(); target uuid; item uuid; p public.forum_posts; r public.forum_replies;
 nickname text; heading text; content text; category text; result jsonb; desired boolean; reaction text;
begin
 if p_action is null or p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then
  raise exception 'invalid_input' using errcode='22023';
 end if;
 if p_action='detail' then
  target:=(p_data->>'post_id')::uuid;
  select * into p from public.forum_posts where id=target and visibility='published' and deleted_at is null
   and exists(select 1 from public.forum_categories c where c.id=category_id and c.enabled);
  if not found then raise exception 'post_unavailable' using errcode='P0002'; end if;
  select coalesce(jsonb_agg(x),'[]') into result from (
   select id,author_name,body,created_at from public.forum_replies where post_id=target and deleted_at is null
   order by created_at desc,id desc limit 100) x;
  return jsonb_build_object('post',to_jsonb(p)-'author_user_id','replies',result,
   'liked',exists(select 1 from public.forum_reactions where user_id=actor and post_id=target and kind='like'),
   'bookmarked',exists(select 1 from public.forum_reactions where user_id=actor and post_id=target and kind='bookmark'));
 end if;
 if actor is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
  raise exception 'login_required' using errcode='28000';
 end if;
 if p_action in ('mine','bookmarks') then
  select coalesce(jsonb_agg(x),'[]') into result from (
   select id,author_name,author_avatar_url,category_id,title,body,tags,image_urls,is_pinned,is_recommended,is_locked,comments_closed,like_count,reply_count,created_at,updated_at
   from public.forum_posts f where visibility='published' and deleted_at is null
    and exists(select 1 from public.forum_categories c where c.id=f.category_id and c.enabled)
    and ((p_action='mine' and author_user_id=actor) or (p_action='bookmarks' and exists(select 1 from public.forum_reactions reaction_row where reaction_row.user_id=actor and reaction_row.post_id=f.id and reaction_row.kind='bookmark')))
   order by created_at desc,id desc limit 100
  ) x;
  return jsonb_build_object('items',result);
 end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 if exists(select 1 from public.forum_restrictions where user_id=actor and (blocked or (muted and p_action in ('create','reply')))) then
  raise exception 'account_restricted' using errcode='42501';
 end if;
 if p_action in ('create','reply') then
  item:=(p_data->>'id')::uuid; content:=btrim(p_data->>'body'); nickname:=coalesce(nullif(btrim(p_data->>'nickname'),''),'学友');
  if item is null or content is null or length(content)<1 or length(nickname)>80 then
   raise exception 'invalid_input' using errcode='22023';
  end if;
 end if;
 if p_action='create' then
  heading:=btrim(p_data->>'title');category:=p_data->>'category_id';
  if heading is null or length(heading) not between 1 and 160 or length(content)>20000 then
   raise exception 'invalid_input' using errcode='22023';
  end if;
  select * into p from public.forum_posts where id=item;
  if found then
   if p.author_user_id=actor and p.title=heading and p.body=content and p.category_id=category and p.deleted_at is null then
    return jsonb_build_object('id',item,'duplicate',true);
   end if;
   raise exception 'request_conflict' using errcode='23505';
  end if;
  if not exists(select 1 from public.forum_categories where id=category and enabled) then
   raise exception 'invalid_category' using errcode='22023';
  end if;
  if exists(select 1 from public.forum_posts where author_user_id=actor and created_at>now()-interval '30 seconds') then
   raise exception 'rate_limited' using errcode='P0001';
  end if;
  insert into public.forum_posts(id,author_user_id,author_name,category_id,title,body,visibility)
   values(item,actor,nickname,category,heading,content,'published');
  return jsonb_build_object('id',item);
 end if;
 if p_action not in ('reply','like','bookmark') then raise exception 'invalid_action' using errcode='22023';end if;
 target:=(p_data->>'post_id')::uuid;
 select * into p from public.forum_posts where id=target and visibility='published' and deleted_at is null
  and exists(select 1 from public.forum_categories c where c.id=category_id and c.enabled) for update;
 if not found then raise exception 'post_unavailable' using errcode='P0002';end if;
 if p_action='reply' then
  if length(content)>5000 then raise exception 'invalid_input' using errcode='22023';end if;
  select * into r from public.forum_replies where id=item;
  if found then
   if r.user_id=actor and r.post_id=target and r.body=content and r.deleted_at is null then
    return jsonb_build_object('id',item,'duplicate',true);
   end if;
   raise exception 'request_conflict' using errcode='23505';
  end if;
  if p.is_locked or p.comments_closed then raise exception 'replies_closed' using errcode='42501';end if;
  if exists(select 1 from public.forum_replies where user_id=actor and created_at>now()-interval '10 seconds') then
   raise exception 'rate_limited' using errcode='P0001';end if;
  insert into public.forum_replies(id,post_id,user_id,author_name,body) values(item,target,actor,nickname,content);
  update public.forum_posts set reply_count=reply_count+1,updated_at=now(),version=version+1 where id=target;
  return jsonb_build_object('id',item);
 end if;
 if jsonb_typeof(p_data->'enabled') is distinct from 'boolean' then raise exception 'invalid_input' using errcode='22023';end if;
 desired:=(p_data->>'enabled')::boolean;reaction:=p_action;
 if desired then
  insert into public.forum_reactions(user_id,post_id,kind) values(actor,target,reaction) on conflict do nothing;
 else
  delete from public.forum_reactions where user_id=actor and post_id=target and kind=reaction;
 end if;
 if reaction='like' then
  update public.forum_posts set like_count=(select count(*) from public.forum_reactions where post_id=target and kind='like') where id=target;
 end if;
 return jsonb_build_object('enabled',desired);
end $$;
notify pgrst,'reload schema';
commit;
