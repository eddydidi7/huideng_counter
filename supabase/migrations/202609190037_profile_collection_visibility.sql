begin;
alter table public.community_profiles add column if not exists public_resources boolean not null default false;
alter table public.community_profiles add column if not exists public_bookmarks boolean not null default false;
create or replace function public.community_profile_v1(p_user uuid,p_data jsonb default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare profile jsonb; posts jsonb;
begin
 if p_data is not null then
  if auth.uid() is null or auth.uid()<>p_user then raise exception 'denied'; end if;
  if jsonb_typeof(p_data)<>'object' or (p_data ? 'public_resources' and jsonb_typeof(p_data->'public_resources')<>'boolean') or (p_data ? 'public_bookmarks' and jsonb_typeof(p_data->'public_bookmarks')<>'boolean') then raise exception 'invalid_input'; end if;
  insert into public.community_profiles(user_id,bio,show_account,public_resources,public_bookmarks) values(p_user,coalesce(p_data->>'bio',''),coalesce((p_data->>'show_account')::boolean,false),coalesce((p_data->>'public_resources')::boolean,false),coalesce((p_data->>'public_bookmarks')::boolean,false))
  on conflict(user_id) do update set bio=case when p_data ? 'bio' then excluded.bio else community_profiles.bio end,show_account=case when p_data ? 'show_account' then excluded.show_account else community_profiles.show_account end,public_resources=case when p_data ? 'public_resources' then excluded.public_resources else community_profiles.public_resources end,public_bookmarks=case when p_data ? 'public_bookmarks' then excluded.public_bookmarks else community_profiles.public_bookmarks end,updated_at=now();
 end if;
 select jsonb_build_object('user_id',c.user_id,'nickname',c.nickname,'avatar_path',c.avatar_path,'bio',coalesce(x.bio,''),'show_account',coalesce(x.show_account,false),'public_resources',coalesce(x.public_resources,false),'public_bookmarks',coalesce(x.public_bookmarks,false),'personal_number',case when coalesce(x.show_account,false) or c.user_id=auth.uid() then to_jsonb(c)->'personal_number' else null end)
 into profile from public.chat_profiles c left join public.community_profiles x on x.user_id=c.user_id where c.user_id=p_user;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') into posts from (
 select id,title,body,post_kind,category_id,image_urls,tags,created_at,like_count,reply_count,exists(select 1 from public.forum_attachments a where a.post_id=f.id and a.kind='image') has_image from public.forum_posts f
 where author_user_id=p_user and access_level='public' and visibility='published' and deleted_at is null
 and exists(select 1 from public.forum_categories c where c.id=f.category_id and c.enabled) order by created_at desc limit 200)t;
 return jsonb_build_object('profile',profile,'posts',posts);
end $$;
revoke all on function public.community_profile_v1(uuid,jsonb) from public;
grant execute on function public.community_profile_v1(uuid,jsonb) to anon,authenticated;

create or replace function public.community_collection_v1(p_user uuid,p_kind text) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare permitted boolean;
begin
 if p_kind not in ('resources','bookmarks') or p_kind is null then raise exception 'invalid_input';end if;
 select case when p_kind='resources' then public_resources else public_bookmarks end into permitted
 from public.community_profiles where user_id=p_user;
 if auth.uid() is distinct from p_user and not coalesce(permitted,false) then raise exception 'denied' using errcode='42501';end if;
 if p_kind='bookmarks' then
  return coalesce((select jsonb_agg(to_jsonb(t)) from (
   select f.id,f.title,f.body,f.post_kind,f.category_id,f.image_urls,f.author_name,f.created_at
   from public.forum_reactions r join public.forum_posts f on f.id=r.post_id
   where r.user_id=p_user and r.kind='bookmark' and f.access_level='public' and f.visibility='published' and f.deleted_at is null
   and exists(select 1 from public.forum_categories c where c.id=f.category_id and c.enabled)
   order by f.created_at desc limit 500)t),'[]'::jsonb);
 end if;
 return coalesce((select jsonb_agg(to_jsonb(t)) from (
  select s.kind,s.source_id,s.title,
    case when s.kind='group_file' then jsonb_build_object('group_id',g.group_id) else '{}'::jsonb end metadata
  from public.saved_content s
  left join public.chat_group_files g on s.kind='group_file' and g.file_id::text=s.source_id and g.deleted_at is null
  where s.user_id=p_user and (s.kind='resource' or (g.file_id is not null and public.group_file_readable(g.file_id)))
  order by s.created_at desc limit 500)t),'[]'::jsonb);
end $$;
revoke all on function public.community_collection_v1(uuid,text) from public;
grant execute on function public.community_collection_v1(uuid,text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
