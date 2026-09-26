begin;
create or replace function public.huideng_admin_jieyuan(actor uuid,action text,payload jsonb,request_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,admin_private as $$
declare role_name text; result jsonb; row_data jsonb; item jsonb; previous admin_private.requests; target uuid;
begin
 select role into role_name from admin_private.members where user_id=actor and enabled;
 if role_name is null or role_name not in ('super_admin','admin','moderator') then raise exception 'forbidden'; end if;
 if action='jieyuan.get' then
 return jsonb_build_object('config',(select value from public.jieyuan_config where id),'levels',(select jsonb_agg(to_jsonb(l) order by level) from public.jieyuan_levels l),'reports',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from (select * from public.jieyuan_reports order by created_at desc limit 100) r));
 end if;
 if role_name<>'super_admin' and action<>'jieyuan.moderate' then raise exception 'forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,46));
 select * into previous from admin_private.requests where requests.actor=huideng_admin_jieyuan.actor and requests.request_id=huideng_admin_jieyuan.request_id;
 if found then if previous.action<>action or previous.payload<>payload then raise exception 'request_conflict'; end if;return previous.result; end if;
 if action='jieyuan.save' then
 row_data:=payload->'config';
 if jsonb_typeof(row_data)<>'object' or octet_length(row_data::text)>10000 then raise exception 'invalid_config';end if;
 foreach role_name in array array['enabled','free','paid','wanted','images','resource_images'] loop
 if jsonb_typeof(row_data->role_name) is distinct from 'boolean' then raise exception 'invalid_config';end if;end loop;
 if jsonb_typeof(row_data->'currencies') is distinct from 'array' or jsonb_array_length(row_data->'currencies') not between 1 and 30 or exists(select 1 from jsonb_array_elements_text(row_data->'currencies') c where c !~ '^[A-Z]{3}$') then raise exception 'invalid_currency';end if;
 if jsonb_typeof(payload->'levels') is distinct from 'array' or jsonb_array_length(payload->'levels')<>5 or (select count(distinct v->>'level') from jsonb_array_elements(payload->'levels') v)<>5 then raise exception 'invalid_levels';end if;
 for item in select value from jsonb_array_elements(payload->'levels') loop
 if coalesce((item->>'level')::integer,0) not between 1 and 5 or coalesce((item->'permissions'->>'max_images')::integer,-1) not between 0 and 30 or coalesce((item->'permissions'->>'daily_posts')::integer,-1) not between 0 and 1000 then raise exception 'invalid_levels';end if;
 foreach role_name in array array['enter','publish','free','paid','wanted','images'] loop
 if jsonb_typeof(item->'permissions'->role_name) is distinct from 'boolean' then raise exception 'invalid_levels';end if;end loop;
 update public.jieyuan_levels set permissions=item->'permissions' where level=(item->>'level')::integer;
 end loop;
 update public.jieyuan_config set value=row_data where id;
 elsif action='jieyuan.level' then
 target:=(payload->>'user_id')::uuid;
 insert into public.app_user_levels(user_id,level) values(target,(payload->>'level')::integer) on conflict(user_id) do update set level=excluded.level;
 elsif action='jieyuan.moderate' then
 target:=(payload->>'post_id')::uuid;
 if not exists(select 1 from public.forum_posts where id=target and category_id='jieyuan') then raise exception 'post_unavailable';end if;
 if payload->>'operation'='hide' then update public.forum_posts set visibility='hidden',updated_at=now() where id=target;
 elsif payload->>'operation'='delete' then update public.forum_posts set deleted_at=now(),updated_at=now() where id=target;
 elsif payload->>'operation'='warn' then
 if length(coalesce(payload->>'message','')) not between 1 and 1000 then raise exception 'invalid_warning';end if;
 insert into public.jieyuan_warnings(user_id,message) select author_user_id,payload->>'message' from public.forum_posts where id=target;
 elsif payload->>'operation' in ('restrict','ban') then
 if role_name='moderator' then raise exception 'forbidden';end if;
 insert into public.forum_restrictions(user_id,muted,blocked) select author_user_id,true,payload->>'operation'='ban' from public.forum_posts where id=target on conflict(user_id) do update set muted=true,blocked=excluded.blocked,updated_at=now();
 if payload->>'operation'='ban' then update auth.users set banned_until=now()+interval '100 years' where id=(select author_user_id from public.forum_posts where id=target);end if;
 else raise exception 'invalid_operation';end if;
 else raise exception 'invalid_action';end if;
 result:='{"saved":true}';
 insert into admin_private.audit_logs(actor,action,target,after_data) values(actor,action,target::text,payload);
 insert into admin_private.requests(actor,request_id,action,payload,result) values(actor,request_id,action,payload,result);
 return result;
end $$;
revoke all on function public.huideng_admin_jieyuan(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.huideng_admin_jieyuan(uuid,text,jsonb,uuid) to service_role;
notify pgrst,'reload schema';
commit;
