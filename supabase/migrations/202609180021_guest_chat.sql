begin;
-- Extends authenticated chat to Supabase guest identities. No unauthenticated
-- anon-role access is granted. Existing membership/block/ban/rate checks remain.
alter table public.chat_qr_invites alter column expires_at drop not null;
alter table public.chat_qr_invites alter column expires_at drop default;
update public.chat_qr_invites set expires_at=null where expires_at is not null;

do $$
declare signature text; definition text; revised text;
begin
 foreach signature in array array[
  'public.chat_api_v1(text,jsonb)', 'public.chat_contacts_v1(text,jsonb)',
  'public.chat_live_v1(text,jsonb)', 'public.chat_directory_v2(text,jsonb)',
  'public.chat_avatar_v1(text)', 'public.chat_voice_user_active()',
  'public.chat_voice_v1(jsonb)', 'public.chat_call_v1(text,jsonb)',
  'public.chat_qr_v1(text,jsonb)'
 ] loop
  if to_regprocedure(signature) is null then raise exception 'Missing prerequisite: %',signature; end if;
  definition := pg_get_functiondef(to_regprocedure(signature));
  revised := replace(replace(definition,'not coalesce(is_anonymous,false)','true'),'not coalesce(u.is_anonymous,false)','true');
  if signature='public.chat_qr_v1(text,jsonb)' then
   revised := replace(revised, 'expires_at=now()+interval ''7 days''', 'expires_at=null');
  end if;
  execute revised;
 end loop;
end $$;

create or replace function public.chat_register_profile() returns trigger
language plpgsql security definer set search_path='' as $$
declare label text;
begin
 label := case when coalesce(new.is_anonymous,false) then
  left(nullif(trim(regexp_replace(coalesce(new.raw_user_meta_data->>'chat_device_nickname',''),'[[:cntrl:]]','','g')),''),40)
  else null end;
 insert into public.chat_profiles(user_id,nickname)
 values(new.id,coalesce(label,case when coalesce(new.is_anonymous,false) then '手机学友' else '学友 '||left(new.id::text,8) end)) on conflict do nothing;
 return new;
end $$;
-- Existing guest identities get a profile too; never overwrite chosen names.
insert into public.chat_profiles(user_id,nickname)
 select id,coalesce(left(nullif(trim(regexp_replace(coalesce(raw_user_meta_data->>'chat_device_nickname',''),'[[:cntrl:]]','','g')),''),40),'手机学友')
 from auth.users where coalesce(is_anonymous,false) on conflict do nothing;

drop policy if exists chat_avatar_upload on storage.objects;
create policy chat_avatar_upload on storage.objects for insert to authenticated with check(
 bucket_id='chat-avatars' and (storage.foldername(name))[1]=auth.uid()::text
 and public.chat_voice_user_active());
notify pgrst,'reload schema';
commit;
