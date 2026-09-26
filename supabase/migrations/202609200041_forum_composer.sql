-- Non-destructive: preserve posts, media and all associations.
begin;
alter table public.forum_attachments add column if not exists sort_order integer not null default 0;
create or replace function public.forum_action_v2(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid(); result jsonb; row_data jsonb; target uuid; f jsonb; n bigint; file_path text; file_position integer:=0; tag_values text[];
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>2000000 then raise exception 'invalid_input'; end if;
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
  if jsonb_typeof(coalesce(p_data->'attachments','[]'))<>'array' or jsonb_array_length(coalesce(p_data->'attachments','[]'))>512 then raise exception 'invalid_attachments'; end if;
 end if;
 if p_action='create' then
  if jsonb_typeof(coalesce(p_data->'tags','[]'))<>'array' or jsonb_array_length(coalesce(p_data->'tags','[]'))>10 then raise exception 'invalid_tags'; end if;
  select coalesce(array_agg(value),'{}') into tag_values from jsonb_array_elements_text(coalesce(p_data->'tags','[]'));
  if exists(select 1 from unnest(tag_values) t where length(t)>50) then raise exception 'invalid_tags'; end if;
 end if;
 result:=public.forum_action_v1(p_action,p_data-'attachments'-'tags');
 if p_action='create' then
  target:=(result->>'id')::uuid;
  if coalesce((result->>'duplicate')::boolean,false) then
   if not exists(select 1 from public.forum_posts where id=target and tags=tag_values) then raise exception 'request_conflict';end if;
   if coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'path',a.path,'name',a.name,'kind',a.kind) order by a.sort_order,a.created_at,a.id) from public.forum_attachments a where a.post_id=target),'[]') <> coalesce(p_data->'attachments','[]') then raise exception 'request_conflict';end if;
   return result;
  end if;
  update public.forum_posts set tags=tag_values where id=target and author_user_id=actor;
  for f in select value from jsonb_array_elements(coalesce(p_data->'attachments','[]')) loop
   file_path:=f->>'path';
   if split_part(file_path,'/',1) is distinct from actor::text or split_part(file_path,'/',2) is distinct from target::text then raise exception 'invalid_attachment_owner'; end if;
   select (to_jsonb(o)->'metadata'->>'size')::bigint into n from storage.objects o where o.bucket_id='forum-files' and o.name=file_path;
   if n is null or n not between 1 and 10485760 then raise exception 'attachment_missing'; end if;
   insert into public.forum_attachments(id,post_id,owner_id,path,name,kind,size,sort_order)
   values((f->>'id')::uuid,target,actor,file_path,f->>'name',f->>'kind',n,file_position);
   file_position:=file_position+1;
  end loop;
 elsif p_action='detail' then
  target:=(p_data->>'post_id')::uuid;
  select coalesce(jsonb_agg(to_jsonb(a)-'owner_id' order by a.sort_order,a.created_at,a.id),'[]') into row_data from public.forum_attachments a where a.post_id=target;
  result:=jsonb_set(result,'{post,attachments}',row_data);
 end if;
 return result;
end $$;
revoke all on function public.forum_action_v2(text,jsonb) from public;
grant execute on function public.forum_action_v2(text,jsonb) to anon,authenticated;

create or replace function public.community_post(p_id uuid,p_slug text default null) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare p public.forum_posts; result jsonb;
begin
 if not public.community_can_read(p_id,p_slug) then raise exception 'post_unavailable'; end if;
 select * into p from public.forum_posts where id=p_id;
 result:=to_jsonb(p)-'source_note_id';
 return result || jsonb_build_object('attachments',coalesce((select jsonb_agg(to_jsonb(a)-'owner_id' order by a.sort_order,a.created_at,a.id) from public.forum_attachments a where a.post_id=p_id),'[]'),
 'share_slug',(select slug from public.shared_pages where source_id=p_id and revoked_at is null and (expires_at is null or expires_at>now()) and p.access_level<>'private'),
 'owned',p.author_user_id=auth.uid());
end $$;
revoke all on function public.community_post(uuid,text) from public,anon,authenticated;


notify pgrst,'reload schema';
commit;
