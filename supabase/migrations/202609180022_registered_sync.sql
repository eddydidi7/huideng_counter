begin;
-- Registration is required for cloud counter/notes sync; guest chat is unchanged.
-- No user data is updated or deleted.
create or replace function public.sync_registered_user() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=auth.uid()
  and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<=now()))
$$;
revoke all on function public.sync_registered_user() from public,anon;
grant execute on function public.sync_registered_user() to authenticated;

do $$
declare tab text; signature text; definition text;
begin
 foreach tab in array array['counter_sync_heads','counter_projects','counter_events','counter_documents','counter_change_feed','counter_mutation_receipts','user_notes','note_sync_heads','note_sync_receipts'] loop
  if not exists(select 1 from pg_policies where schemaname='public' and tablename=tab and policyname='registered_sync_only') then
   execute format('create policy registered_sync_only on public.%I as restrictive for all to authenticated using (public.sync_registered_user()) with check (public.sync_registered_user())',tab);
  end if;
 end loop;
 -- Security-definer writes bypass RLS, so check registration inside each RPC too.
 foreach signature in array array['public.counter_push_event(jsonb)','public.counter_put_document(text,text,bigint,jsonb,uuid)','public.sync_note_v1(uuid,uuid,bigint,jsonb,jsonb)'] loop
  if to_regprocedure(signature) is null then raise exception 'Missing prerequisite: %', signature; end if;
  definition:=pg_get_functiondef(to_regprocedure(signature));
  if position('public.sync_registered_user()' in definition)=0 then
   if position('if u is null then' in definition)=0 then raise exception 'Unexpected function body: %',signature; end if;
   definition:=replace(definition,'if u is null then','if u is null or not public.sync_registered_user() then');
   execute definition;
  end if;
 end loop;
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='registered_counter_images_only') then
  execute 'create policy registered_counter_images_only on storage.objects as restrictive for all to authenticated using (bucket_id<>''counter-images'' or public.sync_registered_user()) with check (bucket_id<>''counter-images'' or public.sync_registered_user())';
 end if;
end $$;
notify pgrst,'reload schema';
commit;
