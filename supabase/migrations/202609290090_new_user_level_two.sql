-- Preserve existing effective levels. Only new registrations default to level 2.
begin;
insert into public.app_user_levels(user_id,level)
 select id,1 from auth.users where not coalesce(is_anonymous,false)
 on conflict(user_id) do nothing;
alter table public.app_user_levels alter column level set default 2;
create or replace function public.assign_registered_user_level()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(new.is_anonymous,false) then
  insert into public.app_user_levels(user_id,level) values(new.id,2)
   on conflict(user_id) do nothing;
 end if;
 return new;
end $$;
revoke all on function public.assign_registered_user_level() from public,anon,authenticated;
create or replace trigger registered_user_level
 after insert or update of is_anonymous on auth.users
 for each row execute function public.assign_registered_user_level();
commit;
