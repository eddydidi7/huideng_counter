begin;
-- Storage authorizes an INSERT before final metadata is necessarily available.
-- Keep the reserved path, owner, membership and expiry checks at that stage.
create or replace function public.group_reserved_upload(p_key text,p_size bigint)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select exists(select 1 from public.group_file_reservations r
 where (r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text=p_key
   or r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text||'.apk'=p_key)
 and (p_size is null or p_size=0 or r.size=p_size) and r.owner_id=auth.uid() and not r.committed
 and r.created_at>now()-interval '1 day' and public.group_upload_allowed(r.group_id))
$$;

-- Final size validation applies even when Storage completes the write as its
-- service role. No object becomes readable as a group file until file_add.
create or replace function public.validate_group_storage_reservation()
returns trigger language plpgsql security definer set search_path='' as $$
declare reservation public.group_file_reservations; actual_size bigint;
begin
 if new.bucket_id<>'group-files' then return new; end if;
 if tg_op='UPDATE' and (old.name<>new.name or old.bucket_id<>new.bucket_id) then raise exception 'GROUP_FILE_PATH_IMMUTABLE'; end if;
 actual_size:=(new.metadata->>'size')::bigint;
 if actual_size is null or actual_size=0 then return new; end if;
 select * into reservation from public.group_file_reservations r
 where new.name in (r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text,
                   r.group_id::text||'/'||r.owner_id::text||'/'||r.id::text||'.apk');
 if not found or actual_size<>reservation.size then raise exception 'GROUP_FILE_SIZE_MISMATCH' using errcode='23514'; end if;
 return new;
end $$;
revoke all on function public.validate_group_storage_reservation() from public,anon,authenticated;
create or replace trigger validate_group_storage_reservation before insert or update of metadata,name,bucket_id
 on storage.objects for each row execute function public.validate_group_storage_reservation();

-- Allow an uploader to inspect its own unfinished reservation for retry checks.
drop policy if exists group_file_reserved_read on storage.objects;
create policy group_file_reserved_read on storage.objects for select to authenticated
 using(bucket_id='group-files' and public.group_reserved_upload(name,(metadata->>'size')::bigint));
-- Existing group_file_read, INSERT checks, immutable upload behavior and RPC
-- deletion permissions are retained. No public write or blanket UPDATE grant.
notify pgrst,'reload schema';
commit;
