-- Content sharing is additive. Moderation visibility remains separate from audience.
begin;
alter table public.forum_posts add column if not exists access_level text not null default 'public' check(access_level in ('public','link_only','private'));
alter table public.forum_posts add column if not exists post_kind text not null default 'image_text' check(post_kind in ('status','image_text','article'));
alter table public.forum_posts add column if not exists rich_body jsonb;
alter table public.forum_posts add column if not exists source_note_id uuid;
create table if not exists public.shared_pages (
 id uuid primary key default gen_random_uuid(), owner_user_id uuid not null references auth.users(id),
 source_type text not null default 'redbook_post' check(source_type='redbook_post'),
 source_id uuid not null unique references public.forum_posts(id),
 slug text not null unique default replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),
 created_at timestamptz not null default now(), expires_at timestamptz, revoked_at timestamptz
);
insert into public.shared_pages(owner_user_id,source_id) select author_user_id,id from public.forum_posts where author_user_id is not null on conflict(source_id) do nothing;
alter table public.shared_pages enable row level security;
revoke all on public.shared_pages from public,anon,authenticated;
create table if not exists public.community_profiles (
 user_id uuid primary key references auth.users(id), bio text not null default '' check(length(bio)<=500),
 show_account boolean not null default false, updated_at timestamptz not null default now()
);
alter table public.community_profiles enable row level security;
revoke all on public.community_profiles from public,anon,authenticated;
create table if not exists public.community_config (
 id boolean primary key default true check(id), public_base_url text not null default '', download_url text not null default '',
 check(public_base_url='' or public_base_url ~ '^https://[^[:space:]]+$'),
 check(download_url='' or download_url ~ '^https://[^[:space:]]+$')
);
insert into public.community_config(id) values(true) on conflict do nothing;
alter table public.community_config enable row level security;
revoke all on public.community_config from public,anon,authenticated;
grant select on public.community_config to anon,authenticated;
drop policy if exists community_config_read on public.community_config;
create policy community_config_read on public.community_config for select to anon,authenticated using(true);
-- Old API versions must not become a visibility bypass.
do $patch$
declare f text; signature text;
begin
 foreach signature in array array['public.forum_action_v1(text,jsonb)','public.forum_action_v2(text,jsonb)'] loop
  select pg_get_functiondef(signature::regprocedure) into f;
  if position('access_level' in f)=0 then
   f:=replace(f, 'visibility=''published'' and deleted_at is null', 'visibility=''published'' and deleted_at is null and (access_level=''public'' or author_user_id=auth.uid())');
   f:=replace(f, 'p.visibility=''published'' and p.deleted_at is null', 'p.visibility=''published'' and p.deleted_at is null and (p.access_level=''public'' or p.author_user_id=auth.uid())');
   execute f;
  end if;
 end loop;
end $patch$;
drop policy if exists forum_post_read on public.forum_posts;
create policy forum_post_read on public.forum_posts for select to anon,authenticated using(
 access_level='public' and visibility='published' and deleted_at is null and exists(select 1 from public.forum_categories c where c.id=category_id and c.enabled));
drop policy if exists forum_attachment_read on public.forum_attachments;
create policy forum_attachment_read on public.forum_attachments for select to anon,authenticated using(
 owner_id=auth.uid() or exists(select 1 from public.forum_posts p where p.id=post_id and p.access_level='public' and p.visibility='published' and p.deleted_at is null));

create or replace function public.community_can_read(p_id uuid,p_slug text default null) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.forum_posts p where p.id=p_id and p.deleted_at is null and p.visibility='published'
 and exists(select 1 from public.forum_categories c where c.id=p.category_id and c.enabled)
 and (p.author_user_id=auth.uid() or p.access_level='public' or (p.access_level='link_only' and exists(
 select 1 from public.shared_pages s where s.source_id=p.id and s.slug=p_slug and s.revoked_at is null and (s.expires_at is null or s.expires_at>now())))))
$$;
revoke all on function public.community_can_read(uuid,text) from public,anon,authenticated;

create or replace function public.community_post(p_id uuid,p_slug text default null) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare p public.forum_posts; result jsonb;
begin
 if not public.community_can_read(p_id,p_slug) then raise exception 'post_unavailable'; end if;
 select * into p from public.forum_posts where id=p_id;
 result:=to_jsonb(p)-'source_note_id';
 return result || jsonb_build_object('attachments',coalesce((select jsonb_agg(to_jsonb(a)-'owner_id') from public.forum_attachments a where a.post_id=p_id),'[]'),
 'share_slug',(select slug from public.shared_pages where source_id=p_id and revoked_at is null and (expires_at is null or expires_at>now()) and p.access_level<>'private'),
 'owned',p.author_user_id=auth.uid());
end $$;
revoke all on function public.community_post(uuid,text) from public,anon,authenticated;

create or replace function public.forum_action_v3(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid(); target uuid; result jsonb; p public.forum_posts; access text; post_type text; rich jsonb; reply_id uuid; reply_name text; reply_body text;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>2000000 then raise exception 'invalid_input'; end if;
 target:=nullif(p_data->>'post_id','')::uuid;
 if p_action='detail' then
  result:=public.community_post(target,p_data->>'slug');
  return jsonb_build_object('post',result,'replies',coalesce((select jsonb_agg(to_jsonb(t)) from (
   select id,author_name,body,created_at from public.forum_replies where post_id=target and deleted_at is null order by created_at desc limit 100)t),'[]'),
   'liked',exists(select 1 from public.forum_reactions where user_id=actor and post_id=target and kind='like'),
   'bookmarked',exists(select 1 from public.forum_reactions where user_id=actor and post_id=target and kind='bookmark'));
 end if;
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'login_required'; end if;
 if p_action='create' then
  access:=coalesce(p_data->>'access_level','public'); post_type:=coalesce(p_data->>'post_kind','image_text'); rich:=p_data->'rich_body';
  if access not in ('public','link_only','private') or post_type not in ('status','image_text','article') or (rich is not null and rich<>'null'::jsonb and jsonb_typeof(rich)<>'array') then raise exception 'invalid_input'; end if;
  -- Legacy creation retains all moderation, rate-limit and attachment ownership checks.
  result:=public.forum_action_v2('create',p_data-'rich_body'); target:=(result->>'id')::uuid;
  if coalesce((result->>'duplicate')::boolean,false) then
   if not exists(select 1 from public.forum_posts where id=target and access_level=access and post_kind=post_type and rich_body is not distinct from nullif(rich,'null')) then raise exception 'request_conflict'; end if;
  else
   update public.forum_posts set access_level=access,post_kind=post_type,rich_body=nullif(rich,'null'),source_note_id=nullif(p_data->>'source_note_id','')::uuid where id=target and author_user_id=actor;
  end if;
  insert into public.shared_pages(owner_user_id,source_id) values(actor,target) on conflict(source_id) do nothing;
  return result;
 end if;
 if p_action in ('visibility','share','revoke_share') then
  select * into p from public.forum_posts where id=target and author_user_id=actor and deleted_at is null for update;
  if not found then raise exception 'post_unavailable'; end if;
  if p_action='visibility' then
   access:=p_data->>'access_level'; if access is null or access not in ('public','link_only','private') then raise exception 'invalid_input'; end if;
   update public.forum_posts set access_level=access,updated_at=now(),version=version+1 where id=target;
  end if;
  insert into public.shared_pages(owner_user_id,source_id) values(actor,target) on conflict(source_id) do nothing;
  if p_action='revoke_share' then update public.shared_pages set revoked_at=now() where source_id=target; end if;
  if p_action='share' then
   if p.access_level='private' then raise exception 'private_content'; end if;
   update public.shared_pages set slug=case when revoked_at is not null then replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','') else slug end,revoked_at=null,expires_at=nullif(p_data->>'expires_at','')::timestamptz where source_id=target;
  end if;
  return jsonb_build_object('slug',(select slug from public.shared_pages where source_id=target));
 end if;
 if p_action in ('reply','like','bookmark') and exists(select 1 from public.forum_posts where id=target and access_level='link_only') then
  perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
  if exists(select 1 from public.forum_restrictions where user_id=actor and (blocked or (muted and p_action='reply'))) then raise exception 'account_restricted';end if;
  if not public.community_can_read(target,p_data->>'slug') then raise exception 'post_unavailable';end if;
  select * into p from public.forum_posts where id=target for update;
  if p_action='reply' then
   reply_id:=(p_data->>'id')::uuid;reply_body:=btrim(p_data->>'body');
   select nickname into reply_name from public.chat_profiles where user_id=actor;
   if reply_id is null or reply_name is null or reply_body is null or length(reply_body) not between 1 and 5000 then raise exception 'invalid_input';end if;
   if exists(select 1 from public.forum_replies where id=reply_id) then
    if exists(select 1 from public.forum_replies where id=reply_id and user_id=actor and post_id=target and body=reply_body and deleted_at is null) then return jsonb_build_object('id',reply_id,'duplicate',true);end if;
    raise exception 'request_conflict';
   end if;
   if p.is_locked or p.comments_closed then raise exception 'replies_closed';end if;
   if exists(select 1 from public.forum_replies where user_id=actor and created_at>now()-interval '10 seconds') then raise exception 'rate_limited';end if;
   insert into public.forum_replies(id,post_id,user_id,author_name,body) values(reply_id,target,actor,reply_name,reply_body);
   update public.forum_posts set reply_count=reply_count+1,updated_at=now(),version=version+1 where id=target;
   return jsonb_build_object('id',reply_id);
  end if;
  if jsonb_typeof(p_data->'enabled') is distinct from 'boolean' then raise exception 'invalid_input';end if;
  if (p_data->>'enabled')::boolean then insert into public.forum_reactions(user_id,post_id,kind) values(actor,target,p_action) on conflict do nothing;
  else delete from public.forum_reactions where user_id=actor and post_id=target and kind=p_action;end if;
  update public.forum_posts set like_count=(select count(*) from public.forum_reactions where post_id=target and kind='like') where id=target;
  return jsonb_build_object('enabled',(p_data->>'enabled')::boolean);
 end if;

 return public.forum_action_v2(p_action,p_data);
end $$;
revoke all on function public.forum_action_v3(text,jsonb) from public;
grant execute on function public.forum_action_v3(text,jsonb) to anon,authenticated;

create or replace function public.shared_page_v1(p_slug text) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare s public.shared_pages; p public.forum_posts;
begin
 if p_slug is null or length(p_slug)<>64 then raise exception 'post_unavailable'; end if;
 select * into s from public.shared_pages where slug=p_slug and revoked_at is null and (expires_at is null or expires_at>now());
 if not found then raise exception 'post_unavailable'; end if;
 select * into p from public.forum_posts where id=s.source_id and access_level in ('public','link_only');
 if not found then raise exception 'post_unavailable'; end if;
 return jsonb_build_object('post',public.community_post(p.id,p_slug),'related',coalesce((select jsonb_agg(to_jsonb(t)) from (
 select f.id,f.title,f.body,f.author_name,sp.slug from public.forum_posts f join public.shared_pages sp on sp.source_id=f.id
 where f.id<>p.id and f.access_level='public' and f.visibility='published' and f.deleted_at is null and f.category_id=p.category_id
 and sp.revoked_at is null and (sp.expires_at is null or sp.expires_at>now()) order by f.created_at desc limit 4)t),'[]'));
end $$;
revoke all on function public.shared_page_v1(text) from public;
grant execute on function public.shared_page_v1(text) to anon,authenticated;

create or replace function public.community_profile_v1(p_user uuid,p_data jsonb default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare profile jsonb; posts jsonb;
begin
 if p_data is not null then
  if auth.uid() is null or auth.uid()<>p_user then raise exception 'denied'; end if;
  insert into public.community_profiles(user_id,bio,show_account) values(p_user,coalesce(p_data->>'bio',''),coalesce((p_data->>'show_account')::boolean,false))
  on conflict(user_id) do update set bio=excluded.bio,show_account=excluded.show_account,updated_at=now();
 end if;
 select jsonb_build_object('user_id',c.user_id,'nickname',c.nickname,'avatar_path',c.avatar_path,'bio',coalesce(x.bio,''),'show_account',coalesce(x.show_account,false),'personal_number',case when coalesce(x.show_account,false) or c.user_id=auth.uid() then to_jsonb(c)->'personal_number' else null end)
 into profile from public.chat_profiles c left join public.community_profiles x on x.user_id=c.user_id where c.user_id=p_user;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') into posts from (
 select id,title,body,post_kind,category_id,image_urls,tags,created_at,like_count,reply_count,exists(select 1 from public.forum_attachments a where a.post_id=f.id and a.kind='image') has_image from public.forum_posts f
 where author_user_id=p_user and access_level='public' and visibility='published' and deleted_at is null
 and exists(select 1 from public.forum_categories c where c.id=f.category_id and c.enabled) order by created_at desc limit 200)t;
 return jsonb_build_object('profile',profile,'posts',posts);
end $$;
revoke all on function public.community_profile_v1(uuid,jsonb) from public;
grant execute on function public.community_profile_v1(uuid,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
commit;
