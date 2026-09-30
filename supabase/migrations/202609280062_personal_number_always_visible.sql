-- 202609220063 tried to make community_profile_v1 always expose
-- personal_number (dropping the show_account/self-only gate) via textual
-- find/replace against pg_get_functiondef(). That anchor never matched this
-- deployment's stored function text (same root cause discovered while
-- debugging 202609280061: pg_get_functiondef() does not reproduce a
-- migration file's original formatting byte for byte), so the guard raised
-- and the whole migration rolled back silently at some point, leaving the
-- old gate in place. This redoes the same intent with a rename+wrapper
-- instead, so it does not depend on the existing function's exact text.
begin;

do $$
begin
  if to_regprocedure('public.community_profile_v1(uuid,jsonb)') is null then
    raise exception 'Missing prerequisite: community_profile_v1';
  end if;
end $$;

do $$
begin
  if to_regprocedure('public.community_profile_before_number_visibility(uuid,jsonb)') is null then
    alter function public.community_profile_v1(uuid,jsonb) rename to community_profile_before_number_visibility;
  end if;
end $$;
revoke all on function public.community_profile_before_number_visibility(uuid,jsonb) from public,anon,authenticated;

-- Personal numbers are the public-facing account identifier (same as
-- search, contacts, group members and public_profile_link_page already show
-- to anyone), not a secret gated by the profile's own show_account toggle.
create or replace function public.community_profile_v1(p_user uuid, p_data jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result := public.community_profile_before_number_visibility(p_user, p_data);
  -- personal_number lives at result.profile.personal_number, not the top
  -- level, and the original function nulls it out unless show_account is
  -- set or the viewer is the profile owner. Always show the real value.
  if result is not null and (result ? 'profile') then
    result := jsonb_set(result, '{profile,personal_number}',
      coalesce((select to_jsonb(c.personal_number) from public.chat_profiles c where c.user_id = p_user), 'null'::jsonb),
      true);
  end if;
  return result;
end $$;
revoke all on function public.community_profile_v1(uuid,jsonb) from public;
grant execute on function public.community_profile_v1(uuid,jsonb) to anon,authenticated;

notify pgrst, 'reload schema';
commit;
