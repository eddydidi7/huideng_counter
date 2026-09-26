-- Additive forum layout and attachments. Old categories/posts remain unchanged.
begin;
create function public.forum_section(text) returns text language sql immutable as $$
 select case when $1 in ('questions','experience') then 'study' else $1 end
$$;
create table public.forum_attachments (
 id uuid primary key, post_id uuid not null references public.forum_posts(id),
 owner_id uuid not null references auth.users(id), path text not null unique,
 name text not null check(length(name) between 1 and 200),
 kind text not null check(kind in ('image','file')), size bigint not null check(size between 1 and 10485760),
 created_at timestamptz not null default now()
);
alter table public.forum_attachments enable row level security;
revoke all on public.forum_attachments from anon,authenticated;
grant select on public.forum_attachments to anon,authenticated;
create policy forum_attachment_read on public.forum_attachments for select to anon,authenticated using(
 exists(select 1 from public.forum_posts p where p.id=post_id and p.visibility='published' and p.deleted_at is null));
insert into storage.buckets(id,name,public,file_size_limit) values('forum-files','forum-files',false,10485760) on conflict(id) do nothing;
create policy forum_file_upload on storage.objects for insert to authenticated with check(
 bucket_id='forum-files' and (storage.foldername(name))[1]=auth.uid()::text
 and not coalesce((auth.jwt()->>'is_anonymous')::boolean,false)
 and not exists(select 1 from public.forum_attachments a where a.path=storage.objects.name));
create policy forum_file_read on storage.objects for select to anon,authenticated using(
 bucket_id='forum-files' and ((storage.foldername(name))[1]=auth.uid()::text
 or exists(select 1 from public.forum_attachments a where a.path=storage.objects.name)));

create function public.forum_feed_v2(p_search text default '',p_category text default '',p_sort text default 'latest',p_offset integer default 0)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if p_search is null or length(p_search)>200 or p_category is null or p_sort not in ('latest','hot','recommended') or p_sort is null
 or p_offset is null or p_offset<0 or p_offset>10000 then raise exception 'invalid_query'; end if;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') into result from (
 select p.id,p.author_name,p.author_avatar_url,public.forum_section(p.category_id) category_id,p.title,p.body,p.tags,p.image_urls,
 p.is_pinned,p.is_recommended,p.is_locked,p.comments_closed,p.like_count,p.reply_count,p.created_at,p.updated_at,
 coalesce((select jsonb_agg(to_jsonb(a)-'owner_id' order by a.created_at,a.id) from public.forum_attachments a where a.post_id=p.id),'[]') attachments
 from public.forum_posts p where (p_category='' or public.forum_section(p.category_id)=p_category)
 and (p_search='' or strpos(lower(p.title||' '||p.body||' '||p.author_name),lower(p_search))>0
 or exists(select 1 from public.forum_attachments a where a.post_id=p.id and strpos(lower(a.name),lower(p_search))>0))
 order by p.is_pinned desc,
 case when p_sort in ('hot','recommended') then (p.like_count*3.0+p.reply_count*5.0)/power(1+greatest(0,extract(epoch from (now()-p.updated_at)))/86400,0.5) else 0 end desc,
 p.created_at desc,p.id desc limit 21 offset p_offset
 ) t;
 return jsonb_build_object('items',result);
end $$;
revoke all on function public.forum_feed_v2(text,text,text,integer) from public;
grant execute on function public.forum_feed_v2(text,text,text,integer) to anon,authenticated;

create function public.forum_sections_v1() returns jsonb language sql stable security invoker set search_path=pg_catalog,public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'count',
 (select count(*) from public.forum_posts p where public.forum_section(p.category_id)=s.id),
 'latest_title',(select title from public.forum_posts p where public.forum_section(p.category_id)=s.id order by created_at desc,id desc limit 1)) order by s.n),'[]')
 from (values('study',1),('practice',2),('resources',3),('feedback',4)) s(id,n)
$$;
revoke all on function public.forum_sections_v1() from public;
grant execute on function public.forum_sections_v1() to anon,authenticated;

create function public.forum_action_v2(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid(); result jsonb; row_data jsonb; target uuid; f jsonb; n bigint; file_path text;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then raise exception 'invalid_input'; end if;
 if p_action='my_replies' then
  if actor is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then raise exception 'login_required'; end if;
  select coalesce(jsonb_agg(to_jsonb(t)-'author_user_id'),'[]') into result from (
   select p.* from public.forum_posts p where p.visibility='published' and p.deleted_at is null
    and exists(select 1 from public.forum_categories c where c.id=p.category_id and c.enabled)
    and exists(select 1 from public.forum_replies r where r.user_id=actor and r.post_id=p.id and r.deleted_at is null)
   order by (select max(created_at) from public.forum_replies r where r.post_id=p.id and r.user_id=actor and r.deleted_at is null) desc,p.id limit 100
  ) t;
  return jsonb_build_object('items',result);
 end if;
 if p_action='create' then
  if p_data->>'category_id' not in ('study','practice','resources','feedback') then raise exception 'invalid_category'; end if;
  if jsonb_typeof(coalesce(p_data->'attachments','[]'))<>'array' or jsonb_array_length(coalesce(p_data->'attachments','[]'))>9 then raise exception 'invalid_attachments'; end if;
 end if;
 result:=public.forum_action_v1(p_action,p_data);
 if p_action='create' then
  target:=(result->>'id')::uuid;
  if coalesce((result->>'duplicate')::boolean,false) then return result; end if;
  for f in select value from jsonb_array_elements(coalesce(p_data->'attachments','[]')) loop
   file_path:=f->>'path';
   if split_part(file_path,'/',1) is distinct from actor::text or split_part(file_path,'/',2) is distinct from target::text then raise exception 'invalid_attachment_owner'; end if;
   select (to_jsonb(o)->'metadata'->>'size')::bigint into n from storage.objects o where o.bucket_id='forum-files' and o.name=file_path;
   if n is null or n not between 1 and 10485760 then raise exception 'attachment_missing'; end if;
   insert into public.forum_attachments(id,post_id,owner_id,path,name,kind,size)
   values((f->>'id')::uuid,target,actor,file_path,f->>'name',f->>'kind',n);
  end loop;
 elsif p_action='detail' then
  target:=(p_data->>'post_id')::uuid;
  select coalesce(jsonb_agg(to_jsonb(a)-'owner_id' order by a.created_at,a.id),'[]') into row_data from public.forum_attachments a where a.post_id=target;
  result:=jsonb_set(result,'{post,attachments}',row_data);
 end if;
 return result;
end $$;
revoke all on function public.forum_action_v2(text,jsonb) from public;
grant execute on function public.forum_action_v2(text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
commit;
