-- Hongshu social layer: follow authors, follow feed, read counts, bookmark
-- counts, threaded comments with likes and deletion.
-- Additive: no existing post, reply, reaction or profile row is removed.
-- All writes go through community_social_v1 (security definer, auth.uid(),
-- uniqueness, rate limits). Guests use their anonymous Auth user, so they can
-- follow, comment and like without registering an email.
begin;

do $$
begin
  if to_regprocedure('public.community_can_read(uuid,text)') is null then
    raise exception 'Missing prerequisite: community_can_read (202609180030)';
  end if;
  if to_regprocedure('public.jieyuan_visible(jsonb)') is null then
    raise exception 'Missing prerequisite: jieyuan_visible (202609200045)';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='forum_attachments' and column_name='sort_order') then
    raise exception 'Missing prerequisite: forum_attachments.sort_order (202609250070)';
  end if;
end $$;

-- Follows: one row per (follower, followee); never yourself.
create table if not exists public.community_follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  followee_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  constraint community_follows_not_self check (follower_id <> followee_id)
);
create index if not exists community_follows_followee
  on public.community_follows(followee_id, created_at desc);
alter table public.community_follows enable row level security;
revoke all on public.community_follows from public, anon, authenticated;
-- Read-only, own rows only: forum_feed_v2 (security invoker) uses it to rank
-- followed authors. anon gets the grant but no policy, i.e. zero rows.
grant select on public.community_follows to anon, authenticated;
drop policy if exists community_follows_own_read on public.community_follows;
create policy community_follows_own_read on public.community_follows
  for select to authenticated using (follower_id = auth.uid());

-- Reads: at most one counted view per user, post and UTC day.
create table if not exists public.forum_post_views (
  post_id uuid not null references public.forum_posts(id) on delete cascade,
  viewer_id uuid not null references auth.users(id) on delete cascade,
  view_day date not null default ((now() at time zone 'utc')::date),
  primary key (post_id, viewer_id, view_day)
);
alter table public.forum_post_views enable row level security;
revoke all on public.forum_post_views from public, anon, authenticated;

alter table public.forum_posts add column if not exists view_count bigint not null default 0;
alter table public.forum_posts add column if not exists bookmark_count integer not null default 0;
update public.forum_posts p set bookmark_count = b.n
  from (select post_id, count(*)::integer n from public.forum_reactions
        where kind='bookmark' group by post_id) b
  where p.id = b.post_id and p.bookmark_count <> b.n;

-- Keep bookmark_count exact whichever function toggles the bookmark.
create or replace function public.forum_bookmark_count_sync() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare target uuid := coalesce(new.post_id, old.post_id);
begin
  if coalesce(new.kind, old.kind) = 'bookmark' then
    update public.forum_posts set bookmark_count =
      (select count(*) from public.forum_reactions where post_id=target and kind='bookmark')
      where id = target;
  end if;
  return null;
end $$;
revoke all on function public.forum_bookmark_count_sync() from public, anon, authenticated;
drop trigger if exists forum_bookmark_count_sync on public.forum_reactions;
create trigger forum_bookmark_count_sync after insert or delete on public.forum_reactions
  for each row execute function public.forum_bookmark_count_sync();

-- Threaded comments: two levels. A reply to a reply keeps the top-level
-- comment as parent and records who was answered.
alter table public.forum_replies add column if not exists parent_id uuid references public.forum_replies(id);
alter table public.forum_replies add column if not exists reply_to_user_id uuid references auth.users(id);
alter table public.forum_replies add column if not exists reply_to_name text;
alter table public.forum_replies add column if not exists like_count integer not null default 0;
create index if not exists forum_replies_thread
  on public.forum_replies(post_id, parent_id, created_at desc, id desc);
create index if not exists forum_replies_children
  on public.forum_replies(parent_id, created_at, id) where parent_id is not null;

create table if not exists public.forum_reply_likes (
  reply_id uuid not null references public.forum_replies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (reply_id, user_id)
);
alter table public.forum_reply_likes enable row level security;
revoke all on public.forum_reply_likes from public, anon, authenticated;

create or replace function public.forum_comment_view(r public.forum_replies, viewer uuid, post_author uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object(
    'id', r.id, 'post_id', r.post_id, 'parent_id', r.parent_id, 'user_id', r.user_id,
    'author_name', r.author_name,
    'body', case when r.deleted_at is null then r.body else '' end,
    'deleted', r.deleted_at is not null, 'created_at', r.created_at,
    'like_count', r.like_count,
    'liked', exists(select 1 from public.forum_reply_likes l where l.reply_id=r.id and l.user_id=viewer),
    'reply_to_user_id', r.reply_to_user_id, 'reply_to_name', r.reply_to_name,
    'can_delete', r.deleted_at is null and viewer is not null and (viewer=r.user_id or viewer=post_author))
$$;
revoke all on function public.forum_comment_view(public.forum_replies,uuid,uuid) from public, anon, authenticated;

create or replace function public.forum_post_stats(p_post uuid, viewer uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object(
    'post_id', p.id, 'like_count', p.like_count, 'bookmark_count', p.bookmark_count,
    'reply_count', p.reply_count, 'view_count', p.view_count,
    'liked', exists(select 1 from public.forum_reactions r where r.user_id=viewer and r.post_id=p.id and r.kind='like'),
    'bookmarked', exists(select 1 from public.forum_reactions r where r.user_id=viewer and r.post_id=p.id and r.kind='bookmark'),
    'author_user_id', p.author_user_id,
    'following_author', exists(select 1 from public.community_follows f where f.follower_id=viewer and f.followee_id=p.author_user_id))
  from public.forum_posts p where p.id = p_post
$$;
revoke all on function public.forum_post_stats(uuid,uuid) from public, anon, authenticated;

create or replace function public.community_social_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  actor uuid := auth.uid(); other uuid; target uuid; item uuid; ref uuid;
  p public.forum_posts; r public.forum_replies;
  lim integer; before_at timestamptz; before_id uuid; after_at timestamptz; after_id uuid;
  content text; nickname text; parent_ref uuid; to_user uuid; to_name text; changed integer;
begin
  if p_action is null or p_data is null or jsonb_typeof(p_data) <> 'object'
    or octet_length(p_data::text) > 20000 then
    raise exception 'invalid_input' using errcode='22023';
  end if;
  if actor is null or not exists(select 1 from auth.users where id=actor
      and (banned_until is null or banned_until < now())) then
    raise exception 'login_required' using errcode='28000';
  end if;
  lim := least(greatest(coalesce((p_data->>'limit')::integer, 20), 1), 50);
  before_at := nullif(p_data->>'before_at','')::timestamptz;
  before_id := coalesce(nullif(p_data->>'before_id','')::uuid, 'ffffffff-ffff-ffff-ffff-ffffffffffff');
  after_at := nullif(p_data->>'after_at','')::timestamptz;
  after_id := coalesce(nullif(p_data->>'after_id','')::uuid, '00000000-0000-0000-0000-000000000000');

  -- ---------- follows ----------
  if p_action in ('follow','follow_state','followers','following') then
    other := nullif(p_data->>'user_id','')::uuid;
    if other is null then raise exception 'invalid_input' using errcode='22023'; end if;
  end if;
  if p_action = 'follow' then
    if jsonb_typeof(p_data->'enabled') is distinct from 'boolean' then
      raise exception 'invalid_input' using errcode='22023';
    end if;
    if other = actor then raise exception 'cannot_follow_self' using errcode='22023'; end if;
    if not exists(select 1 from public.chat_profiles where user_id=other) then
      raise exception 'user_unavailable' using errcode='P0002';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('follow:'||actor::text, 0));
    if (p_data->>'enabled')::boolean then
      if not exists(select 1 from public.community_follows where follower_id=actor and followee_id=other) then
        if (select count(*) from public.community_follows
            where follower_id=actor and created_at > now() - interval '1 minute') >= 30 then
          raise exception 'rate_limited' using errcode='P0001';
        end if;
        if (select count(*) from public.community_follows where follower_id=actor) >= 5000 then
          raise exception 'follow_limit' using errcode='P0001';
        end if;
        insert into public.community_follows(follower_id, followee_id) values(actor, other)
          on conflict do nothing;
      end if;
    else
      delete from public.community_follows where follower_id=actor and followee_id=other;
    end if;
    p_action := 'follow_state';
  end if;
  if p_action = 'follow_state' then
    return jsonb_build_object(
      'user_id', other, 'self', other = actor,
      'following', exists(select 1 from public.community_follows where follower_id=actor and followee_id=other),
      'followed_by', exists(select 1 from public.community_follows where follower_id=other and followee_id=actor),
      'followers', (select count(*) from public.community_follows where followee_id=other),
      'following_count', (select count(*) from public.community_follows where follower_id=other));
  end if;
  if p_action in ('followers','following') then
    return jsonb_build_object('items', coalesce((select jsonb_agg(to_jsonb(t) order by t.followed_at desc, t.user_id desc) from (
      select c.user_id, c.nickname, c.avatar_path, c.personal_number, f.created_at as followed_at,
        exists(select 1 from public.community_follows m where m.follower_id=actor and m.followee_id=c.user_id) as following
      from public.community_follows f
      join public.chat_profiles c on c.user_id = case when p_action='followers' then f.follower_id else f.followee_id end
      where (case when p_action='followers' then f.followee_id else f.follower_id end) = other
        and (before_at is null or (f.created_at, c.user_id) < (before_at, before_id))
      order by f.created_at desc, c.user_id desc limit lim) t), '[]'::jsonb));
  end if;

  -- ---------- follow feed: followed authors only, newest first ----------
  if p_action = 'following_feed' then
    return jsonb_build_object('items', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id desc) from (
      select p.id, p.jieyuan, p.author_user_id, p.author_name, p.author_avatar_url,
        public.forum_section(p.category_id) as category_id, p.title,
        case when char_length(p.body) > 4000 then left(p.body, 4000) else p.body end as body,
        p.tags, p.image_urls, p.is_pinned, p.is_recommended, p.is_locked, p.comments_closed,
        p.like_count, p.reply_count, p.bookmark_count, p.view_count, p.created_at, p.updated_at,
        coalesce((select jsonb_agg(to_jsonb(a) - 'owner_id' order by a.sort_order, a.created_at, a.id)
          from public.forum_attachments a where a.post_id = p.id), '[]'::jsonb) as attachments
      from public.forum_posts p
      join public.community_follows f on f.followee_id = p.author_user_id and f.follower_id = actor
      where p.visibility='published' and p.deleted_at is null and p.access_level='public'
        and exists(select 1 from public.forum_categories c where c.id=p.category_id and c.enabled)
        and public.jieyuan_visible(p.jieyuan)
        and (before_at is null or (p.created_at, p.id) < (before_at, before_id))
      order by p.created_at desc, p.id desc limit lim) t), '[]'::jsonb));
  end if;

  -- ---------- everything below is about one readable post ----------
  if p_action in ('view','post_stats','comments','comment') then
    target := nullif(p_data->>'post_id','')::uuid;
  elsif p_action in ('comment_like','comment_delete') then
    ref := nullif(p_data->>'reply_id','')::uuid;
    select * into r from public.forum_replies where id = ref;
    if not found then raise exception 'comment_unavailable' using errcode='P0002'; end if;
    target := r.post_id;
  else
    raise exception 'invalid_action' using errcode='22023';
  end if;
  if target is null or not public.community_can_read(target, p_data->>'slug') then
    raise exception 'post_unavailable' using errcode='P0002';
  end if;

  if p_action = 'view' then
    insert into public.forum_post_views(post_id, viewer_id) values(target, actor) on conflict do nothing;
    get diagnostics changed = row_count;
    if changed > 0 then
      update public.forum_posts set view_count = view_count + 1 where id = target;
    end if;
    return public.forum_post_stats(target, actor);
  end if;
  if p_action = 'post_stats' then
    return public.forum_post_stats(target, actor);
  end if;

  select * into p from public.forum_posts where id = target;

  if p_action = 'comments' then
    item := nullif(p_data->>'parent_id','')::uuid;
    if item is null then
      -- Top-level comments, newest first, each with its first 3 replies.
      return jsonb_build_object('reply_count', p.reply_count, 'items', coalesce((
        select jsonb_agg(public.forum_comment_view(x, actor, p.author_user_id) || jsonb_build_object(
          'child_count', (select count(*) from public.forum_replies c where c.parent_id=x.id and c.deleted_at is null),
          'children', coalesce((select jsonb_agg(public.forum_comment_view(c, actor, p.author_user_id) order by c.created_at, c.id)
            from public.forum_replies c where c.id in (
              select k.id from public.forum_replies k where k.parent_id=x.id and k.deleted_at is null
              order by k.created_at, k.id limit 3)), '[]'::jsonb))
          order by x.created_at desc, x.id desc)
        from public.forum_replies x where x.id in (
          select y.id from public.forum_replies y
          where y.post_id=target and y.parent_id is null
            and (y.deleted_at is null or exists(select 1 from public.forum_replies c
                 where c.parent_id=y.id and c.deleted_at is null))
            and (before_at is null or (y.created_at, y.id) < (before_at, before_id))
          order by y.created_at desc, y.id desc limit lim)), '[]'::jsonb));
    end if;
    -- More replies under one comment, oldest first.
    return jsonb_build_object('items', coalesce((
      select jsonb_agg(public.forum_comment_view(x, actor, p.author_user_id) order by x.created_at, x.id)
      from public.forum_replies x where x.id in (
        select y.id from public.forum_replies y
        where y.post_id=target and y.parent_id=item and y.deleted_at is null
          and (after_at is null or (y.created_at, y.id) > (after_at, after_id))
        order by y.created_at, y.id limit lim)), '[]'::jsonb));
  end if;

  if p_action = 'comment' then
    item := nullif(p_data->>'id','')::uuid;
    content := btrim(p_data->>'body');
    if item is null or content is null or char_length(content) not between 1 and 5000 then
      raise exception 'invalid_input' using errcode='22023';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(actor::text, 0));
    if exists(select 1 from public.forum_restrictions where user_id=actor and (blocked or muted)) then
      raise exception 'account_restricted' using errcode='42501';
    end if;
    select * into p from public.forum_posts where id = target for update;
    select * into r from public.forum_replies where id = item;
    if found then
      if r.user_id=actor and r.post_id=target and r.body=content and r.deleted_at is null then
        return jsonb_build_object('id', item, 'duplicate', true, 'reply_count', p.reply_count);
      end if;
      raise exception 'request_conflict' using errcode='23505';
    end if;
    if p.is_locked or p.comments_closed then raise exception 'replies_closed' using errcode='42501'; end if;
    if exists(select 1 from public.forum_replies where user_id=actor and created_at > now() - interval '10 seconds') then
      raise exception 'rate_limited' using errcode='P0001';
    end if;
    ref := nullif(p_data->>'reply_to','')::uuid;
    if ref is not null then
      select * into r from public.forum_replies where id=ref and post_id=target and deleted_at is null;
      if not found then raise exception 'comment_unavailable' using errcode='P0002'; end if;
      parent_ref := coalesce(r.parent_id, r.id);
      to_user := r.user_id;
      to_name := r.author_name;
    end if;
    select c.nickname into nickname from public.chat_profiles c where c.user_id = actor;
    if nickname is null then raise exception 'profile_required' using errcode='P0002'; end if;
    insert into public.forum_replies(id, post_id, user_id, author_name, body, parent_id, reply_to_user_id, reply_to_name)
      values(item, target, actor, nickname, content, parent_ref, to_user, to_name);
    update public.forum_posts set
      reply_count = (select count(*) from public.forum_replies where post_id=target and deleted_at is null),
      updated_at = now(), version = version + 1
      where id = target;
    return jsonb_build_object('id', item,
      'reply_count', (select reply_count from public.forum_posts where id=target));
  end if;

  if p_action = 'comment_like' then
    if jsonb_typeof(p_data->'enabled') is distinct from 'boolean' then
      raise exception 'invalid_input' using errcode='22023';
    end if;
    if r.deleted_at is not null then raise exception 'comment_unavailable' using errcode='P0002'; end if;
    perform pg_advisory_xact_lock(hashtextextended('reply-like:'||ref::text, 0));
    if (p_data->>'enabled')::boolean then
      insert into public.forum_reply_likes(reply_id, user_id) values(ref, actor) on conflict do nothing;
    else
      delete from public.forum_reply_likes where reply_id=ref and user_id=actor;
    end if;
    update public.forum_replies set like_count =
      (select count(*) from public.forum_reply_likes where reply_id=ref) where id=ref;
    return jsonb_build_object('enabled', (p_data->>'enabled')::boolean,
      'like_count', (select like_count from public.forum_replies where id=ref));
  end if;

  if p_action = 'comment_delete' then
    -- The commenter, or the post author for comments under their own post.
    if actor <> r.user_id and actor <> p.author_user_id then
      raise exception 'denied' using errcode='42501';
    end if;
    select * into p from public.forum_posts where id = target for update;
    update public.forum_replies set deleted_at = now() where id=ref and deleted_at is null;
    update public.forum_posts set
      reply_count = (select count(*) from public.forum_replies where post_id=target and deleted_at is null)
      where id = target;
    return jsonb_build_object('id', ref, 'deleted', true,
      'reply_count', (select reply_count from public.forum_posts where id=target));
  end if;
  raise exception 'invalid_action' using errcode='22023';
end $$;
revoke all on function public.community_social_v1(text,jsonb) from public, anon;
grant execute on function public.community_social_v1(text,jsonb) to authenticated;

-- Popular ranking gives followed authors a moderate boost; the Latest
-- timeline stays purely chronological.
do $$
declare definition text; old_score text; new_score text;
begin
  definition := pg_get_functiondef('public.forum_feed_v2(text,text,text,integer)'::regprocedure);
  old_score := 'case when p_sort in (''hot'',''recommended'') then (p.like_count*3.0+p.reply_count*5.0)/';
  new_score := 'case when p_sort in (''hot'',''recommended'') then (p.like_count*3.0+p.reply_count*5.0+case when exists(select 1 from public.community_follows ff where ff.follower_id=auth.uid() and ff.followee_id=p.author_user_id) then 6.0 else 0 end)/';
  if position('community_follows' in definition) = 0 then
    if position(old_score in definition) > 0 then
      execute replace(definition, old_score, new_score);
    else
      raise notice 'forum_feed_v2 score expression not found; follow boost skipped';
    end if;
  end if;
end $$;

notify pgrst, 'reload schema';
commit;
