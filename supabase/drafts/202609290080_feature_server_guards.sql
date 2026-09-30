-- DRAFT: NOT DEPLOYABLE. RPC coverage and direct-write/storage guards still
-- require integration tests. Keep outside migrations until that audit passes.
-- Intended to run after 079, preserving original signatures and business checks.
begin;
create or replace function feature_private.guard_rpc(route text,args jsonb)
returns void language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); action text:=coalesce(args->>'p_action','');
 data jsonb:=coalesce(args->'p_data','{}'); feature text; permission text; room uuid;
begin
 if route like 'public_resources_%' or route='shared_file_service_v1' or route='public_resource_preview'
    or route='public_resource_share_create' or route='drive_service_v1' then
  actor:=coalesce((args->>'p_actor')::uuid,(args->>'p_user')::uuid);
 end if;
 -- Unidentified public readers retain existing access. A freeze never grants
 -- access: original auth, guest, membership, ownership and role checks still run.
 if actor is null then return; end if;
 if route like 'public_resources_%' or route in ('public_resource_preview','public_resource_share_create') then
  if action like 'admin.%' then return; end if;
  feature:='public_drive';
  permission:=case when action='delete' then 'delete_own'
   when action in ('begin','complete') or action like 'upload.%' then 'upload'
   when action in ('download','preview','share') or route in ('public_resource_preview','public_resource_share_create') then 'download'
   else 'browse' end;
 elsif route='shared_file_service_v1' then
  feature:='group_files';permission:=case when action='group.download' then 'download' else 'upload' end;
 elsif route='group_resource_v1' then
  feature:='group_files';
  permission:=case when action='publish' then 'transfer' when action in ('reuse','save','save_many') then 'upload' else 'browse' end;
  if action in ('save','save_many') then
   perform feature_private.assert_allowed(actor,'public_drive','transfer');
   perform feature_private.assert_allowed(actor,'public_drive','download');
  elsif action='publish' then
   perform feature_private.assert_allowed(actor,'public_drive','upload');
   perform feature_private.assert_allowed(actor,'group_files','download');
  end if;
 elsif route like 'group_learning%' then
  if action in ('file_get','more_files','overview','search') then feature:='group_files';permission:='browse';
  elsif action in ('file_reserve','file_add','file_move','folder') then feature:='group_files';permission:='upload';
  elsif action='file_remove' then feature:='group_files';permission:='delete';
  else feature:='group_chat';permission:='manage'; end if;
 elsif route like 'group_admin%' or route like 'group_manage%' or route='group_invite_v1' then
  feature:='group_chat';permission:=case when action in ('overview','members','logs','search') then 'browse' else 'manage' end;
  if action='member_friend_add' then perform feature_private.assert_allowed(actor,'friends','add'); end if;
 elsif route like 'chat_contacts%' or route like 'chat_directory%' then
  if action in ('request','accept','friend','add','respond') then
   feature:='friends';permission:='add';
  else return; end if;
 elsif route like 'device_transfer%' or route='chat_transfer_v2' then
  feature:='file_assistant';permission:='use';
 elsif route='chat_live_v1' then
  if action not in ('heartbeat','status','offline') then feature:='file_assistant';permission:='use'; else return; end if;
 elsif route like 'chat_api%' or route like 'chat_call%' or route like 'chat_voice%' or route='chat_qr_v1' then
  if action in ('rooms','directory','profile','block') then return; end if;
  room:=nullif(data->>'room_id','')::uuid;
  select case when kind='group' then 'group_chat' else 'chat' end into feature from public.chat_rooms where id=room;
  feature:=coalesce(feature,case when action in ('create_group','join','invite','rename') then 'group_chat' else 'chat' end);
  permission:=case when action in ('messages','members','read','preferences') then 'browse'
    when feature='group_chat' and action in ('create_group','join','invite','rename','leave') then 'manage' else 'send' end;
 elsif route like 'forum_action%' or route like 'forum_author%' or route='forum_edit_attachments_v1' or route='community_social_v1' then
  feature:='forum';permission:=case
   when action in ('create','edit','delete','visibility','share','revoke_share') or route like 'forum_author%' or route='forum_edit_attachments_v1' then 'publish'
   when action in ('reply','comment','comment_delete','reply_delete') then 'comment'
   when action in ('like','bookmark','comment_like','follow','report') then 'interact' else 'browse' end;
 elsif route like 'forum_feed%' or route='community_post' or route like 'jieyuan_%' then
  feature:='forum';permission:='browse';
 elsif route like 'community_profile%' or route like 'community_public_profile%' or route='community_collection_v1' then
  feature:='profile_articles';permission:=case when args->'p_data' is not null and args->'p_data'<>'null'::jsonb then 'publish' else 'browse' end;
 elsif route like 'personal_library%' then feature:='profile_articles';permission:='publish';
 elsif route like 'counter_%' or route like 'pull_note%' or route like 'sync_note%' or route='note_transfer_v2' or route='note_web_link_v1' then
  if route not like 'counter_%' then perform feature_private.assert_allowed(actor,'notes','use'); end if;
  feature:='cloud_sync';permission:='use';
 elsif route='drive_service_v1' then feature:='cloud_sync';permission:='use';
 else return;
 end if;
 perform feature_private.assert_allowed(actor,feature,permission);
end $$;

create or replace function feature_private.filter_rooms(result jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(r order by n),'[]'::jsonb) from jsonb_array_elements(result) with ordinality t(r,n)
 where public.feature_allowed(case when r->>'kind'='group' then 'group_chat' else 'chat' end,'browse')
$$;

-- Use pg_proc metadata, not source-text replacements. Original SECURITY
-- DEFINER bodies move into a non-exposed schema; callers cannot bypass guards
-- through the renamed implementation or any previously public legacy alias.
do $$
declare p record; grant_row record; identity_args text; call_args text; named_args text;
 definition_args text; return_type text; body text; volatility text;
begin
 for p in select p.*,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef and p.prokind='f' and not p.proretset
 and (p.proname ~ '^(chat_api|chat_contacts|chat_directory|group_admin|group_manage|group_learning|forum_action|forum_author|forum_feed|public_resources_|device_transfer|counter_(push|put|pull)|pull_note|sync_note|personal_library_upload)'
 or p.proname in ('chat_live_v1','chat_transfer_v2','chat_voice_v1','chat_call_v1','chat_qr_v1','group_invite_v1',
 'group_resource_v1','shared_file_service_v1','public_resource_preview','public_resource_share_create',
 'community_social_v1','community_post','community_profile_v1','community_public_profile_v1','community_collection_v1',
 'forum_edit_attachments_v1','note_transfer_v2','note_web_link_v1','drive_service_v1'))
 loop
  identity_args:=pg_get_function_identity_arguments(p.oid);
  if to_regprocedure(format('feature_private.%I(%s)',p.proname,oidvectortypes(p.proargtypes))) is not null then continue; end if;
  if p.proargnames is null or cardinality(p.proargnames)<>p.pronargs then raise exception 'UNNAMED_FEATURE_RPC: %',p.proname; end if;
  definition_args:=pg_get_function_arguments(p.oid);return_type:=pg_get_function_result(p.oid);
  select string_agg(format('%I',a),','),string_agg(format('%L,to_jsonb(%I)',a,a),',') into call_args,named_args from unnest(p.proargnames) a;
  execute format('alter function public.%I(%s) set schema feature_private',p.proname,identity_args);
  execute format('revoke all on function feature_private.%I(%s) from public,anon,authenticated,service_role',p.proname,identity_args);
  body:=format('begin perform feature_private.guard_rpc(%L,jsonb_build_object(%s)); ',p.proname,named_args);
  if return_type='void' then body:=body||format('perform feature_private.%I(%s); return; end',p.proname,call_args);
  elsif p.proname like 'chat_api%' then
   body:=body||format('if p_action=''rooms'' then return feature_private.filter_rooms(feature_private.%I(%s)); end if; return feature_private.%I(%s); end',p.proname,call_args,p.proname,call_args);
  else body:=body||format('return feature_private.%I(%s); end',p.proname,call_args); end if;
  volatility:=case p.provolatile when 's' then 'stable' when 'i' then 'stable' else 'volatile' end;
  execute format('create function public.%I(%s) returns %s language plpgsql %s security definer set search_path='''' as %L',p.proname,definition_args,return_type,volatility,body);
  execute format('revoke all on function public.%I(%s) from public,anon,authenticated,service_role',p.proname,identity_args);
  for grant_row in select * from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) loop
   execute format('grant execute on function public.%I(%s) to %s',p.proname,identity_args,
     case when grant_row.grantee=0 then 'public' else quote_ident(pg_get_userbyid(grant_row.grantee)) end);
  end loop;
 end loop;
end $$;

-- Restrictive policies are ANDed with existing access policies. They grant no
-- new visibility, including for guest accounts and anonymous public readers.
do $$
declare r record; expression text;
begin
 for r in select * from (values
 ('forum_posts','forum','browse','publish'),('forum_attachments','forum','browse','publish'),
 ('forum_replies','forum','browse','comment'),('forum_reactions','forum','browse','interact'),
 ('forum_bookmarks','forum','browse','interact'),('community_follows','forum','browse','interact'),
 ('user_notes','notes','use','use'),('note_sync_heads','cloud_sync','use','use'),
 ('note_sync_receipts','cloud_sync','use','use'),('counter_projects','cloud_sync','use','use'),
 ('counter_events','cloud_sync','use','use'),('counter_documents','cloud_sync','use','use'),
 ('counter_change_feed','cloud_sync','use','use'),('counter_sync_heads','cloud_sync','use','use'),
 ('public_resources','public_drive','browse','upload'),
 ('community_files','group_files','browse','upload'),('chat_group_files','group_files','browse','upload'),
 ('group_file_reservations','group_files','browse','upload'),
 ('personal_library_entries','profile_articles','browse','publish'),('personal_library_assets','profile_articles','browse','publish')
 ) v(tab,feature,read_permission,write_permission) loop
  if to_regclass('public.'||r.tab) is null then continue; end if;
  execute format('drop policy if exists feature_read_guard on public.%I',r.tab);
  expression:=format('public.feature_allowed(%L,%L)',r.feature,r.read_permission);
  if r.tab='user_notes' then expression:=expression||' and public.feature_allowed(''cloud_sync'',''use'')'; end if;
  execute format('create policy feature_read_guard on public.%I as restrictive for select to anon,authenticated using(%s)',r.tab,expression);
  execute format('drop policy if exists feature_insert_guard on public.%I',r.tab);
  execute format('drop policy if exists feature_update_guard on public.%I',r.tab);
  expression:=format('public.feature_allowed(%L,%L)',r.feature,r.write_permission);
  execute format('create policy feature_insert_guard on public.%I as restrictive for insert to authenticated with check(%s)',r.tab,expression);
  execute format('create policy feature_update_guard on public.%I as restrictive for update to authenticated using(%s) with check(%s)',r.tab,expression,expression);
 end loop;
end $$;

create or replace function public.feature_room_allowed(p_room uuid,p_permission text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.feature_allowed(case when kind='group' then 'group_chat' else 'chat' end,p_permission)
 from public.chat_rooms where id=p_room
$$;
do $$
declare t text; column_name text;
begin
 foreach t in array array['chat_rooms','chat_messages','chat_members'] loop
  column_name:=case when t='chat_rooms' then 'id' else 'room_id' end;
  execute format('drop policy if exists feature_room_guard on public.%I',t);
  execute format('create policy feature_room_guard on public.%I as restrictive for select to authenticated using(public.feature_room_allowed(%I,''browse''))',t,column_name);
 end loop;
end $$;
revoke all on function public.feature_room_allowed(uuid,text) from public;
grant execute on function public.feature_room_allowed(uuid,text) to authenticated;

create or replace function public.feature_storage_allowed(p_bucket text,p_write boolean)
returns boolean language sql stable security definer set search_path='' as $$
 select case p_bucket
 when 'public-resources' then public.feature_allowed('public_drive',case when p_write then 'upload' else 'download' end)
 when 'group-files' then public.feature_allowed('group_files',case when p_write then 'upload' else 'download' end)
 when 'forum-images' then public.feature_allowed('forum',case when p_write then 'publish' else 'browse' end)
 when 'personal-library' then public.feature_allowed('profile_articles',case when p_write then 'publish' else 'browse' end)
 when 'counter-images' then public.feature_allowed('cloud_sync','use') else true end
$$;
revoke all on function public.feature_storage_allowed(text,boolean) from public;
grant execute on function public.feature_storage_allowed(text,boolean) to anon,authenticated;
drop policy if exists feature_storage_read on storage.objects;
create policy feature_storage_read on storage.objects as restrictive for select to anon,authenticated using(public.feature_storage_allowed(bucket_id,false));
drop policy if exists feature_storage_insert on storage.objects;
create policy feature_storage_insert on storage.objects as restrictive for insert to authenticated with check(public.feature_storage_allowed(bucket_id,true));
drop policy if exists feature_storage_update on storage.objects;
create policy feature_storage_update on storage.objects as restrictive for update to authenticated using(public.feature_storage_allowed(bucket_id,true)) with check(public.feature_storage_allowed(bucket_id,true));
revoke all on all functions in schema feature_private from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
