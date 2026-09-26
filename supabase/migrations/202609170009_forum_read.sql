-- Native community phase 1: public browsing only. Existing website and private data are untouched.
begin;
create table public.forum_categories (
 id text primary key, name_zh text not null, name_en text not null,
 position integer not null, enabled boolean not null default true
);
insert into public.forum_categories values
 ('study','学修交流','Study',1,true),('questions','佛法问答','Questions',2,true),
 ('practice','共修活动','Group practice',3,true),('experience','修行心得','Reflections',4,true),
 ('resources','资料分享','Resources',5,true),('feedback','建议反馈','Feedback',6,true);
create table public.forum_posts (
 id uuid primary key default gen_random_uuid(),
 author_user_id uuid references auth.users(id),
 author_name text not null default '游客' check(length(author_name) between 1 and 80),
 author_avatar_url text,
 category_id text not null references public.forum_categories(id),
 title text not null check(length(title) between 1 and 160),
 body text not null check(length(body) between 1 and 20000),
 tags text[] not null default '{}' check(cardinality(tags)<=10),
 image_urls text[] not null default '{}' check(cardinality(image_urls)<=9),
 visibility text not null default 'draft' check(visibility in ('draft','published','hidden')),
 is_pinned boolean not null default false, is_recommended boolean not null default false,
 is_locked boolean not null default false, comments_closed boolean not null default false,
 like_count integer not null default 0 check(like_count>=0),
 reply_count integer not null default 0 check(reply_count>=0),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 deleted_at timestamptz, version bigint not null default 1
);
create index forum_posts_feed on public.forum_posts (created_at desc,id desc) where visibility='published' and deleted_at is null;
alter table public.forum_categories enable row level security;
alter table public.forum_posts enable row level security;
create policy forum_category_read on public.forum_categories for select to anon,authenticated using(enabled);
create policy forum_post_read on public.forum_posts for select to anon,authenticated using (
 visibility='published' and deleted_at is null and exists (
 select 1 from public.forum_categories c where c.id=category_id and c.enabled));
revoke all on public.forum_categories,public.forum_posts from anon,authenticated;
grant select on public.forum_categories,public.forum_posts to anon,authenticated;

create function public.forum_feed_v1(p_search text default '',p_category text default '',p_sort text default 'latest',p_offset integer default 0)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if p_search is null or p_category is null or p_sort is null or p_offset is null
    or length(p_search)>200 or length(p_category)>80
    or p_sort not in ('latest','recommended') or p_offset<0 or p_offset>10000 then
   raise exception 'invalid query' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into result from (
   select id,author_name,author_avatar_url,category_id,title,body,tags,image_urls,
          is_pinned,is_recommended,is_locked,comments_closed,like_count,reply_count,created_at,updated_at
   from public.forum_posts
   where (p_category='' or category_id=p_category)
     and (p_search='' or strpos(lower(title||' '||body||' '||author_name||' '||array_to_string(tags,' ')),lower(p_search))>0)
   order by case when p_sort='recommended' then is_pinned else false end desc,
     case when p_sort='recommended' then is_recommended else false end desc,
     created_at desc,id desc limit 21 offset p_offset
 ) r;
 return jsonb_build_object('items',result);
end $$;
revoke all on function public.forum_feed_v1(text,text,text,integer) from public;
grant execute on function public.forum_feed_v1(text,text,text,integer) to anon,authenticated;
comment on table public.forum_posts is '论坛内容。浏览阶段没有客户端写权限；发布与治理必须后续增加经验证的事务接口。';
commit;
