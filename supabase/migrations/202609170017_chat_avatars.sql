begin;
alter table public.chat_profiles add column avatar_path text;
insert into storage.buckets(id,name,public,file_size_limit) values('chat-avatars','chat-avatars',false,2097152) on conflict(id) do nothing;
create policy chat_avatar_upload on storage.objects for insert to authenticated with check(
 bucket_id='chat-avatars' and (storage.foldername(name))[1]=auth.uid()::text
 and not coalesce((auth.jwt()->>'is_anonymous')::boolean,false));
create policy chat_avatar_read on storage.objects for select to authenticated using(
 bucket_id='chat-avatars' and ((storage.foldername(name))[1]=auth.uid()::text
 or exists(select 1 from public.chat_profiles p where p.avatar_path=storage.objects.name)));
create function public.chat_avatar_v1(p_path text default null) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)
 and (banned_until is null or banned_until<now())) then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_path is not null and (split_part(p_path,'/',1) is distinct from actor::text or not exists(
 select 1 from storage.objects o where o.bucket_id='chat-avatars' and o.name=p_path
 and (to_jsonb(o)->'metadata'->>'size')::bigint between 1 and 2097152)) then
 raise exception 'CHAT_INVALID_AVATAR' using errcode='42501'; end if;
 update public.chat_profiles set avatar_path=p_path,updated_at=now() where user_id=actor;
 if not found then raise exception 'CHAT_INVALID_USER'; end if;
end $$;
revoke all on function public.chat_avatar_v1(text) from public,anon;
grant execute on function public.chat_avatar_v1(text) to authenticated;
notify pgrst,'reload schema';
commit;
