-- Guests are authenticated Supabase users. Permit their public/social writes
-- while retaining auth.uid ownership, bans, membership checks and rate limits.
-- Registered-only private cloud sync functions are intentionally untouched.
begin;

do $$
declare signature text; definition text; revised text;
begin
 foreach signature in array array[
  'public.forum_action_v1(text,jsonb)',
  'public.forum_action_v2(text,jsonb)',
  'public.forum_action_v3(text,jsonb)',
  'public.forum_author_write_v1(jsonb)',
  'public.chat_api_v1(text,jsonb)',
  'public.chat_contacts_v1(text,jsonb)',
  'public.chat_live_v1(text,jsonb)',
  'public.chat_directory_v2(text,jsonb)',
  'public.chat_avatar_v1(text)',
  'public.chat_voice_user_active()',
  'public.chat_voice_v1(jsonb)',
  'public.chat_call_v1(text,jsonb)',
  'public.chat_qr_v1(text,jsonb)',
  'public.group_invite_v1(uuid,uuid[])',
  'public.group_file_readable(uuid)',
  'public.group_upload_allowed(uuid)'
 ] loop
  if to_regprocedure(signature) is not null then
   definition := pg_get_functiondef(to_regprocedure(signature));
   revised := replace(definition,
    'not coalesce(is_anonymous,false) and ', '');
   revised := replace(revised,
    'not coalesce(u.is_anonymous,false) and ', '');
   revised := replace(revised,
    'and not coalesce(is_anonymous,false)', '');
   revised := replace(revised,
    'and not coalesce(u.is_anonymous,false)', '');
   revised := replace(revised,
    'if actor is null or coalesce((auth.jwt()->>''is_anonymous'')::boolean,false) then',
    'if actor is null then');
   execute revised;
  end if;
 end loop;
end $$;

notify pgrst, 'reload schema';
commit;
