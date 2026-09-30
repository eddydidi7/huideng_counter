-- Keep deletion authorization in 077; consistently expose its result to clients.
begin;
do $$ begin
 if to_regprocedure('public.public_resources_before_capabilities(uuid,text,jsonb)') is null then
  alter function public.public_resources_service_v1(uuid,text,jsonb)
   rename to public_resources_before_capabilities;
 end if;
end $$;
revoke all on function public.public_resources_before_capabilities(uuid,text,jsonb) from public,anon,authenticated;

create or replace function public.public_resources_service_v1(p_actor uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; allowed boolean; administrator boolean;
begin
 result:=public.public_resources_before_capabilities(p_actor,p_action,p_data);
 if p_action not in ('list','begin','complete') then return result; end if;
 select uploader_delete_enabled into allowed from public.public_resource_settings where id;
 administrator:=exists(select 1 from admin_private.members
  where user_id=p_actor and enabled and role in ('admin','super_admin'));
 if p_action='list' then
  select jsonb_set(result,'{files}',coalesce(jsonb_agg(
   x.item||jsonb_build_object('can_delete',administrator or
    (allowed and exists(select 1 from public.public_resources r
     where r.id=(x.item->>'id')::uuid and r.user_id=p_actor))) order by x.position),'[]'))
  into result from jsonb_array_elements(result->'files') with ordinality x(item,position);
 elsif jsonb_typeof(result->'file')='object' then
  result:=jsonb_set(result,'{file,can_delete}',to_jsonb(administrator or
   (allowed and exists(select 1 from public.public_resources r
    where r.id=(result->'file'->>'id')::uuid and r.user_id=p_actor))));
 end if;
 return result;
end $$;
revoke all on function public.public_resources_service_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.public_resources_service_v1(uuid,text,jsonb) to service_role;
commit;
