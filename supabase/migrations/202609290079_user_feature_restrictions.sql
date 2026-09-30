-- Additive permission layer. No grant here replaces existing ownership/RLS rules.
begin;
create schema if not exists feature_private;
revoke all on schema feature_private from public,anon,authenticated;

create table if not exists public.app_feature_permissions (
  feature text not null check(feature ~ '^[a-z][a-z0-9_]*$'),
  permission text not null check(permission ~ '^[a-z][a-z0-9_]*$'),
  feature_label text not null, label text not null,
  enforcement text not null default 'server' check(enforcement in ('server','local_and_server')),
  primary key(feature,permission)
);
insert into public.app_feature_permissions(feature,permission,feature_label,label,enforcement)
select feature,permission,feature_label,label,enforcement from (values
 ('chat','browse','聊天','查看聊天','server'),('chat','send','聊天','发送消息','server'),
 ('group_chat','browse','群聊','查看群聊','server'),('group_chat','send','群聊','发送群消息','server'),
 ('group_chat','manage','群聊','创建及管理群聊','server'),('friends','add','加好友','添加好友','server'),
 ('forum','browse','红书','浏览','server'),('forum','publish','红书','发帖及编辑','server'),
 ('forum','comment','红书','评论','server'),('forum','interact','红书','点赞及互动','server'),
 ('notes','use','笔记','使用笔记','local_and_server'),
 ('public_drive','browse','公共网盘','浏览','server'),('public_drive','download','公共网盘','下载','server'),
 ('public_drive','upload','公共网盘','上传','server'),('public_drive','delete_own','公共网盘','删除自己的文件','server'),
 ('public_drive','transfer','公共网盘','转存到群文件','server'),
 ('group_files','browse','群文件','浏览','server'),('group_files','download','群文件','下载','server'),
 ('group_files','upload','群文件','上传','server'),('group_files','delete','群文件','删除','server'),
 ('group_files','transfer','群文件','转存到公共网盘','server'),
 ('file_assistant','use','文件传输助手','文件直传及信令','server'),
 ('profile_articles','browse','个人主页文章','浏览','server'),
 ('profile_articles','publish','个人主页文章','发布及编辑','server'),
 ('cloud_sync','use','云同步','云同步','server')
) v(feature,permission,feature_label,label,enforcement) on conflict do nothing;

create table if not exists feature_private.user_versions (
 user_id uuid primary key references auth.users(id) on delete cascade,
 revision bigint not null default 0
);
create table if not exists feature_private.restrictions (
 user_id uuid not null references auth.users(id) on delete cascade,
 feature text not null, permission text not null,
 frozen boolean not null default true,
 frozen_at timestamptz not null default statement_timestamp(),
 expires_at timestamptz, permanent boolean not null,
 reason text not null default '' check(length(reason)<=1000),
 operator_id uuid not null references auth.users(id),
 created_at timestamptz not null default statement_timestamp(),
 updated_at timestamptz not null default statement_timestamp(),
 primary key(user_id,feature,permission),
 foreign key(feature,permission) references public.app_feature_permissions(feature,permission),
 check((permanent and expires_at is null) or (not permanent and expires_at>frozen_at))
);
create index if not exists feature_restrictions_expiry on feature_private.restrictions(user_id,expires_at) where frozen;
create table if not exists feature_private.audit (
 id bigint generated always as identity primary key,
 user_id uuid not null, operator_id uuid not null, request_id uuid not null,
 operation text not null, before_data jsonb not null, after_data jsonb not null,
 reason text not null, created_at timestamptz not null default statement_timestamp()
);
create table if not exists feature_private.requests (
 operator_id uuid not null, request_id uuid not null, payload jsonb not null, result jsonb not null,
 primary key(operator_id,request_id)
);
alter table public.app_feature_permissions enable row level security;
revoke all on public.app_feature_permissions from public,anon,authenticated;
grant select on public.app_feature_permissions to anon,authenticated;
drop policy if exists feature_catalog_read on public.app_feature_permissions;
create policy feature_catalog_read on public.app_feature_permissions for select to anon,authenticated using(true);
revoke all on all tables in schema feature_private from public,anon,authenticated;
revoke all on all sequences in schema feature_private from public,anon,authenticated;

create or replace function feature_private.block(p_user uuid,p_feature text,p_permission text)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('feature',r.feature,'permission',r.permission,
   'name',c.feature_label||' · '||c.label,'reason',r.reason,'frozen_at',r.frozen_at,
   'expires_at',r.expires_at,'permanent',r.permanent,'server_time',statement_timestamp())
 from feature_private.restrictions r join public.app_feature_permissions c using(feature,permission)
 where r.user_id=p_user and r.feature=p_feature and r.permission=p_permission and r.frozen
   and r.frozen_at<=statement_timestamp() and (r.permanent or r.expires_at>statement_timestamp())
$$;
create or replace function feature_private.assert_allowed(p_user uuid,p_feature text,p_permission text)
returns void language plpgsql stable security definer set search_path='' as $$
declare restriction jsonb;
begin
 restriction:=feature_private.block(p_user,p_feature,p_permission);
 if restriction is not null then
  raise exception 'FEATURE_FROZEN' using errcode='42501',detail=restriction::text;
 end if;
end $$;
create or replace function public.feature_allowed(p_feature text,p_permission text)
returns boolean language sql stable security definer set search_path='' as $$
 select feature_private.block(auth.uid(),p_feature,p_permission) is null
$$;
create or replace function public.my_feature_permissions()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('server_time',statement_timestamp(),'permissions',coalesce(jsonb_agg(
  jsonb_build_object('feature',c.feature,'permission',c.permission,'feature_label',c.feature_label,
   'label',c.label,'enforcement',c.enforcement,'restriction',feature_private.block(auth.uid(),c.feature,c.permission))
  order by c.feature,c.permission),'[]'::jsonb)) from public.app_feature_permissions c
$$;
revoke all on function public.feature_allowed(text,text),public.my_feature_permissions() from public;
grant execute on function public.feature_allowed(text,text),public.my_feature_permissions() to anon,authenticated;

create or replace function feature_private.user_state(p_user uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('user_id',p_user,'revision',coalesce((select revision from feature_private.user_versions where user_id=p_user),0),
 'status',case when count(*) filter(where b.value is not null)=0 then 'normal'
  when count(*) filter(where b.value is not null)=count(*) then 'all_frozen' else 'partially_frozen' end,
 'server_time',statement_timestamp(),'permissions',jsonb_agg(jsonb_build_object(
   'feature',c.feature,'permission',c.permission,'feature_label',c.feature_label,'label',c.label,
   'restriction',b.value,'operator_id',r.operator_id,
   'remaining_seconds',case when b.value is not null and not r.permanent then greatest(0,extract(epoch from r.expires_at-statement_timestamp())) end)
 order by c.feature,c.permission))
 from public.app_feature_permissions c
 left join feature_private.restrictions r on r.user_id=p_user and r.feature=c.feature and r.permission=c.permission
 cross join lateral (select feature_private.block(p_user,c.feature,c.permission) value) b
$$;

-- Service-only API: the Edge handler must obtain p_actor from a verified JWT,
-- never from the request body. The administrator is rechecked on every call.
create or replace function public.admin_feature_permissions(p_actor uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid; version bigint; entry record; until_at timestamptz; forever boolean;
 request uuid; previous feature_private.requests; old_data jsonb; result jsonb; reason text;
 selected jsonb; request_payload jsonb;
begin
 if not exists(select 1 from admin_private.members where user_id=p_actor and enabled and role in ('super_admin','admin'))
 then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 if p_action='catalog' then
  return jsonb_build_object('permissions',(select jsonb_agg(to_jsonb(c) order by feature,permission) from public.app_feature_permissions c),
   'durations',jsonb_build_array('3d','7d','14d','21d','30d','1y','permanent','custom'),
   'reasons',jsonb_build_array('违反社区规则','重复发布或骚扰','异常上传或滥用资源','账号安全风险','其他'));
 end if;
 if p_action='states' then
  if jsonb_typeof(p_data->'user_ids') is distinct from 'array'
    or jsonb_array_length(p_data->'user_ids')>51 then raise exception 'INVALID_USERS'; end if;
  return jsonb_build_object('items',coalesce((select jsonb_agg(
   jsonb_build_object('user_id',u.id,'status',feature_private.user_state(u.id)->>'status'))
   from auth.users u where u.id in (select value::uuid from jsonb_array_elements_text(p_data->'user_ids'))),'[]'::jsonb),
   'server_time',statement_timestamp());
 end if;
 if p_action='list' then
  return jsonb_build_object('server_time',statement_timestamp(),'users',coalesce((select jsonb_agg(feature_private.user_state(u.id)) from (
   select id from auth.users order by id limit 50 offset greatest(0,least(coalesce((p_data->>'offset')::int,0),1000000))
  ) u),'[]'::jsonb));
 end if;
 target:=(p_data->>'user_id')::uuid;
 if target is null or not exists(select 1 from auth.users where id=target) then raise exception 'USER_NOT_FOUND'; end if;
 if p_action='get' then return feature_private.user_state(target); end if;
 if p_action='audit' then
  return coalesce((select jsonb_agg(to_jsonb(a)) from (
   select * from feature_private.audit where user_id=target order by id desc
   limit 100 offset greatest(0,least(coalesce((p_data->>'offset')::int,0),1000000))) a),'[]'::jsonb);
 end if;
 if p_action not in ('freeze','restore') then raise exception 'INVALID_ACTION'; end if;
 request:=(p_data->>'request_id')::uuid;
 if request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 request_payload:=jsonb_build_object('action',p_action,'data',p_data);
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||request::text,79));
 select * into previous from feature_private.requests where operator_id=p_actor and request_id=request;
 if found then
  if previous.payload<>request_payload then raise exception 'REQUEST_CONFLICT'; end if;
  return previous.result;
 end if;
 insert into feature_private.user_versions(user_id) values(target) on conflict do nothing;
 select revision into version from feature_private.user_versions where user_id=target for update;
 if (p_data->>'revision')::bigint is distinct from version then raise exception 'VERSION_CONFLICT'; end if;
 selected:=p_data->'permissions';
 if p_data->>'all'='true' then
  select jsonb_agg(jsonb_build_object('feature',feature,'permission',permission)) into selected from public.app_feature_permissions;
 end if;
 if jsonb_typeof(selected) is distinct from 'array' or jsonb_array_length(selected) not between 1 and 200
 then raise exception 'INVALID_PERMISSIONS'; end if;
 if exists(select 1 from jsonb_array_elements(selected) s where not exists(
  select 1 from public.app_feature_permissions c where c.feature=s->>'feature' and c.permission=s->>'permission'))
 then raise exception 'INVALID_PERMISSIONS'; end if;
 reason:=btrim(coalesce(p_data->>'reason',''));
 if length(reason)>1000 then raise exception 'INVALID_REASON'; end if;
 forever:=p_data->>'duration'='permanent';
 if p_action='freeze' then
  until_at:=case p_data->>'duration'
   when '3d' then statement_timestamp()+interval '3 days' when '7d' then statement_timestamp()+interval '7 days'
   when '14d' then statement_timestamp()+interval '14 days' when '21d' then statement_timestamp()+interval '21 days'
   when '30d' then statement_timestamp()+interval '30 days' when '1y' then statement_timestamp()+interval '1 year'
   when 'custom' then (p_data->>'expires_at')::timestamptz when 'permanent' then null
   else null end;
  if not coalesce(forever,false) and (until_at is null or until_at<=statement_timestamp()) then raise exception 'INVALID_EXPIRY'; end if;
 end if;
 old_data:=feature_private.user_state(target);
 for entry in select distinct s->>'feature' feature,s->>'permission' permission from jsonb_array_elements(selected) s loop
  if p_action='restore' then
   update feature_private.restrictions set frozen=false,updated_at=statement_timestamp(),operator_id=p_actor
    where user_id=target and feature=entry.feature and permission=entry.permission;
  else
   insert into feature_private.restrictions(user_id,feature,permission,permanent,expires_at,reason,operator_id)
    values(target,entry.feature,entry.permission,forever,until_at,reason,p_actor)
    on conflict(user_id,feature,permission) do update set frozen=true,frozen_at=statement_timestamp(),
     permanent=excluded.permanent,expires_at=excluded.expires_at,reason=excluded.reason,
     operator_id=p_actor,updated_at=statement_timestamp();
  end if;
 end loop;
 update feature_private.user_versions set revision=revision+1 where user_id=target;
 result:=feature_private.user_state(target);
 insert into feature_private.audit(user_id,operator_id,request_id,operation,before_data,after_data,reason)
 values(target,p_actor,request,p_action,old_data,result,reason);
 insert into feature_private.requests values(p_actor,request,request_payload,result);
 return result;
end $$;
revoke all on function public.admin_feature_permissions(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.admin_feature_permissions(uuid,text,jsonb) to service_role;
revoke all on all functions in schema feature_private from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
