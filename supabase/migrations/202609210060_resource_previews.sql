begin;
-- Read-only authorization for bounded image transforms. Original objects stay private.
create or replace function public.public_resource_preview(p_actor uuid,p_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare f public.public_resources; cfg public.public_resource_settings;
begin
 if not exists(select 1 from auth.users where id=p_actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'LOGIN_REQUIRED'; end if;
 if exists(select 1 from public.forum_restrictions where user_id=p_actor and blocked) then raise exception 'LOGIN_REQUIRED'; end if;
 select * into cfg from public.public_resource_settings where id=true;
 if not coalesce(cfg.enabled,false) then raise exception 'RESOURCE_DISABLED'; end if;
 if not cfg.download_enabled then raise exception 'DOWNLOAD_DISABLED'; end if;
 select * into f from public.public_resources where id=p_id and status='published' and verified;
 if not found or lower(f.file_name) !~ '\.(jpg|jpeg|png|webp|gif|avif)$' then raise exception 'FILE_UNAVAILABLE'; end if;
 return jsonb_build_object('file',to_jsonb(f));
end $$;
revoke all on function public.public_resource_preview(uuid,uuid) from public,anon,authenticated;
grant execute on function public.public_resource_preview(uuid,uuid) to service_role;
commit;
