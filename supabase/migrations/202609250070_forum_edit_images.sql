-- Published posts: the author may keep, remove, reorder and add images/files
-- while editing. Non-destructive: this migration drops no post, reply,
-- reaction or attachment.
--
-- Safe order used by the app:
--   1. upload new files to forum-files/<author>/<post>/<id>
--   2. forum_author_write_v2 atomically updates text + attachment rows
--   3. the app removes the returned removed_paths from Storage; the delete
--      policy only allows the author's own files that nothing references.
begin;

do $$
begin
  if to_regprocedure('public.forum_author_write_v1(jsonb)') is null then
    raise exception 'Missing prerequisite: forum_author_write_v1 (202609190038)';
  end if;
  if to_regprocedure('public.chat_object_referenced(text,text)') is null then
    raise exception 'Missing prerequisite: chat_object_referenced (202609210057)';
  end if;
end $$;

-- Image order. 202609200041 was never deployed and must NOT be re-run: its
-- full function bodies predate 0044/0045/0065/0069. Only its sort_order part
-- is applied here, patching the live functions in place.
do $$
declare definition text;
begin
  if not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='forum_attachments' and column_name='sort_order') then
    alter table public.forum_attachments add column sort_order integer not null default 0;
    -- Freeze today's visible order (created_at, id) so nothing moves.
    update public.forum_attachments a set sort_order=r.n
      from (select id, (row_number() over (partition by post_id order by created_at,id))::integer-1 as n
            from public.forum_attachments) r
      where a.id=r.id and r.n<>0;
  end if;

  definition := pg_get_functiondef('public.forum_action_v2(text,jsonb)'::regprocedure);
  if position('sort_order' in definition) = 0 then
    if position('insert into public.forum_attachments(id,post_id,owner_id,path,name,kind,size)' in definition) = 0
      or position('f->>''kind'',n);' in definition) = 0 then
      raise exception 'Could not locate forum_action_v2 attachment insert';
    end if;
    -- New posts store the order in which the author added the files.
    definition := replace(definition,
      'insert into public.forum_attachments(id,post_id,owner_id,path,name,kind,size)',
      'insert into public.forum_attachments(id,post_id,owner_id,path,name,kind,size,sort_order)');
    definition := replace(definition,
      'f->>''kind'',n);',
      'f->>''kind'',n,(select count(*)::integer from public.forum_attachments where post_id=target));');
    definition := replace(definition, 'order by a.created_at,a.id', 'order by a.sort_order,a.created_at,a.id');
    execute definition;
  end if;

  definition := pg_get_functiondef('public.community_post(uuid,text)'::regprocedure);
  if position('sort_order' in definition) = 0
    and position('jsonb_agg(to_jsonb(a)-''owner_id'') from public.forum_attachments a where a.post_id=p_id' in definition) > 0 then
    definition := replace(definition,
      'jsonb_agg(to_jsonb(a)-''owner_id'') from public.forum_attachments a where a.post_id=p_id',
      'jsonb_agg(to_jsonb(a)-''owner_id'' order by a.sort_order,a.created_at,a.id) from public.forum_attachments a where a.post_id=p_id');
    execute definition;
  end if;
end $$;

-- Caller (forum_author_write_v2) holds the post row lock and has verified
-- authorship. Returns the storage paths whose attachment rows were removed.
create or replace function public.forum_edit_attachments_v1(
  p_post uuid, p_actor uuid, p_items jsonb, p_images jsonb
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  f jsonb; n bigint; file_path text; pos integer := 0;
  ids uuid[] := '{}'; removed text[] := '{}'; existing public.forum_attachments;
  legacy text[];
begin
  if not exists(select 1 from public.forum_posts where id=p_post and author_user_id=p_actor) then
    raise exception 'post_unavailable';
  end if;
  if p_items is not null then
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>512 then
      raise exception 'invalid_attachments';
    end if;
    for f in select value from jsonb_array_elements(p_items) loop
      if jsonb_typeof(f)<>'object' or (f->>'id') is null then raise exception 'invalid_attachments'; end if;
      ids := ids || (f->>'id')::uuid;
    end loop;
    if cardinality(ids) <> (select count(distinct x) from unnest(ids) x) then
      raise exception 'invalid_attachments';
    end if;
    -- Only rows the author dropped; their files are cleaned up after commit.
    select coalesce(array_agg(path), '{}') into removed
      from public.forum_attachments where post_id=p_post and not (id = any(ids));
    delete from public.forum_attachments where post_id=p_post and not (id = any(ids));
    for f in select value from jsonb_array_elements(p_items) loop
      select * into existing from public.forum_attachments where id=(f->>'id')::uuid;
      if found then
        if existing.post_id <> p_post then raise exception 'invalid_attachment_owner'; end if;
        update public.forum_attachments set sort_order=pos where id=existing.id and sort_order<>pos;
      else
        file_path := f->>'path';
        if coalesce(f->>'kind','') not in ('image','file')
          or coalesce(length(f->>'name'),0) not between 1 and 200 then
          raise exception 'invalid_attachments';
        end if;
        if split_part(file_path,'/',1) is distinct from p_actor::text
          or split_part(file_path,'/',2) is distinct from p_post::text then
          raise exception 'invalid_attachment_owner';
        end if;
        select (to_jsonb(o)->'metadata'->>'size')::bigint into n
          from storage.objects o where o.bucket_id='forum-files' and o.name=file_path;
        if n is null or n not between 1 and 10485760 then raise exception 'attachment_missing'; end if;
        insert into public.forum_attachments(id,post_id,owner_id,path,name,kind,size,sort_order)
          values((f->>'id')::uuid,p_post,p_actor,file_path,f->>'name',f->>'kind',n,pos);
      end if;
      pos := pos + 1;
    end loop;
  end if;
  -- Legacy image_urls may only shrink (keep a subset, in the given order).
  if p_images is not null then
    if jsonb_typeof(p_images)<>'array' or jsonb_array_length(p_images)>9 then
      raise exception 'invalid_images';
    end if;
    select image_urls into legacy from public.forum_posts where id=p_post;
    if exists(select 1 from jsonb_array_elements_text(p_images) u where not (u.value = any(legacy))) then
      raise exception 'invalid_images';
    end if;
    update public.forum_posts
      set image_urls=array(select value from jsonb_array_elements_text(p_images) with ordinality order by ordinality)
      where id=p_post;
  end if;
  return to_jsonb(removed);
end $$;
revoke all on function public.forum_edit_attachments_v1(uuid,uuid,jsonb,jsonb) from public,anon,authenticated;

-- v2 is cloned from the live v1 so every earlier patch (length limits, guest
-- writes, empty-post rule) is kept; v1 stays unchanged for text-only edits.
do $$
declare definition text; hook text;
begin
  definition := pg_get_functiondef('public.forum_author_write_v1(jsonb)'::regprocedure);
  if position('public.forum_author_write_v1(' in definition) = 0 then
    raise exception 'Could not locate forum_author_write_v1 header';
  end if;
  definition := replace(definition, 'public.forum_author_write_v1(', 'public.forum_author_write_v2(');

  hook := 'if content='''' and cardinality(p.image_urls)=0 and not exists(select 1 from public.forum_attachments where post_id=p.id) then raise exception ''empty_post''; end if;';
  if position(hook in definition) = 0 then
    raise exception 'Could not locate empty_post rule in forum_author_write_v1';
  end if;
  definition := replace(definition, hook,
    'if p_data ? ''attachments'' or p_data ? ''image_urls'' then
    removed_paths := public.forum_edit_attachments_v1(p.id, actor, p_data->''attachments'', p_data->''image_urls'');
  end if;
  if content='''' and cardinality(coalesce((select image_urls from public.forum_posts where id=p.id),''{}''))=0 and not exists(select 1 from public.forum_attachments where post_id=p.id) then raise exception ''empty_post''; end if;');

  if position('declare actor uuid:=auth.uid();' in definition) = 0 then
    raise exception 'Could not locate forum_author_write_v1 declarations';
  end if;
  definition := replace(definition, 'declare actor uuid:=auth.uid();',
    'declare removed_paths jsonb:=''[]''::jsonb; actor uuid:=auth.uid();');

  if position('''deleted'',operation=''delete'');' in definition) = 0 then
    raise exception 'Could not locate forum_author_write_v1 result';
  end if;
  definition := replace(definition, '''deleted'',operation=''delete'');',
    '''deleted'',operation=''delete'',''removed_paths'',removed_paths);');
  execute definition;
end $$;
revoke all on function public.forum_author_write_v2(jsonb) from public,anon;
grant execute on function public.forum_author_write_v2(jsonb) to authenticated;

-- Storage cleanup: own folder only, and only when no post, note, save,
-- library entry or group content still references the file.
create or replace function public.forum_file_removable(p_name text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select auth.uid() is not null
    and split_part(p_name,'/',1) = auth.uid()::text
    and not public.chat_object_referenced('forum-files', p_name)
$$;
revoke all on function public.forum_file_removable(text) from public,anon;
grant execute on function public.forum_file_removable(text) to authenticated;
drop policy if exists forum_file_delete_unreferenced on storage.objects;
create policy forum_file_delete_unreferenced on storage.objects for delete to authenticated
  using (bucket_id='forum-files' and public.forum_file_removable(name));

-- Feeds show images in the author's chosen order.
do $$
declare definition text;
begin
  definition := pg_get_functiondef('public.forum_feed_v2(text,text,text,integer)'::regprocedure);
  if position('order by a.sort_order' in definition) = 0 then
    if position('order by a.created_at,a.id) from public.forum_attachments a where a.post_id=p.id' in definition) = 0 then
      raise exception 'Could not locate forum_feed_v2 attachment order';
    end if;
    definition := replace(definition,
      'order by a.created_at,a.id) from public.forum_attachments a where a.post_id=p.id',
      'order by a.sort_order,a.created_at,a.id) from public.forum_attachments a where a.post_id=p.id');
    execute definition;
  end if;
  if to_regprocedure('public.jieyuan_feed(text,integer)') is not null then
    definition := pg_get_functiondef('public.jieyuan_feed(text,integer)'::regprocedure);
    if position('jsonb_agg(to_jsonb(a)-''owner_id'') from public.forum_attachments a where a.post_id=f.id' in definition) > 0 then
      definition := replace(definition,
        'jsonb_agg(to_jsonb(a)-''owner_id'') from public.forum_attachments a where a.post_id=f.id',
        'jsonb_agg(to_jsonb(a)-''owner_id'' order by a.sort_order,a.created_at,a.id) from public.forum_attachments a where a.post_id=f.id');
      execute definition;
    end if;
  end if;
end $$;

notify pgrst, 'reload schema';
commit;
