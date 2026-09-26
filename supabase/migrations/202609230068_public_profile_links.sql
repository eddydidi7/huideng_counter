-- Stable UUID, never derived from reusable personal_number.
alter table public.community_profiles add column if not exists public_id uuid not null default gen_random_uuid();
create unique index if not exists community_profiles_public_id_key on public.community_profiles(public_id);

create or replace function public.community_public_profile_v1(p_public_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare p public.community_profiles; c public.chat_profiles; base text;
begin
 select * into p from public.community_profiles where public_id=p_public_id;
 if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
 select * into c from public.chat_profiles where user_id=p.user_id;
 select rtrim(public_base_url,'/') into base from public.community_config where id;
 return jsonb_build_object('id',p.public_id,'nickname',c.nickname,'avatar_path',c.avatar_path,
   'personal_number',case when p.show_account then c.personal_number else null end,
   'bio',p.bio,'profile_url',case when base<>'' then base||'/u/'||p.public_id::text else null end);
end $$;
revoke all on function public.community_public_profile_v1(uuid) from public;
grant execute on function public.community_public_profile_v1(uuid) to anon,authenticated;

-- Include the stable id in the existing in-app profile payload.
create or replace function public.community_profile_public_id_v1(p_user uuid)
returns uuid language sql stable security definer set search_path=pg_catalog,public as $$
 select public_id from public.community_profiles where user_id=p_user
$$;
revoke all on function public.community_profile_public_id_v1(uuid) from public;
grant execute on function public.community_profile_public_id_v1(uuid) to anon,authenticated;
