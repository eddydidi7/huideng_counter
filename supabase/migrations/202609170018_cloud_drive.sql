begin;

create table public.user_storage_quota (
  user_id uuid primary key references auth.users(id),
  quota_bytes bigint not null default 1073741824 check (quota_bytes >= 0),
  used_bytes bigint not null default 0 check (used_bytes >= 0),
  reserved_bytes bigint not null default 0 check (reserved_bytes >= 0),
  request_window timestamptz not null default now(),
  request_count integer not null default 0,
  updated_at timestamptz not null default now()
);
create table public.user_files (
  id uuid primary key,
  user_id uuid not null references auth.users(id),
  storage_provider text not null check (storage_provider = 'aliyun_oss'),
  bucket_name text not null,
  object_key text not null unique,
  file_name text not null check (length(file_name) between 1 and 240),
  mime_type text not null default 'application/octet-stream',
  file_size bigint not null check (file_size between 0 and 1073741824),
  checksum text not null check (checksum ~ '^[a-f0-9]{64}$'),
  category text not null default 'cloud' check (category = 'cloud'),
  folder_path text not null default '',
  upload_state text not null default 'reserved' check (upload_state in ('reserved','ready')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (object_key = 'users/' || user_id::text || '/cloud/' || id::text)
);
create index user_files_owner_date on public.user_files(user_id,created_at desc,id);
alter table public.user_files enable row level security;
alter table public.user_storage_quota enable row level security;

create function public.drive_user_active() returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users where id=auth.uid() and not coalesce(is_anonymous,false)
    and (banned_until is null or banned_until < now()));
$$;
revoke all on function public.drive_user_active() from public,anon;
grant execute on function public.drive_user_active() to authenticated;
create policy user_files_read on public.user_files for select to authenticated
  using (auth.uid()=user_id and public.drive_user_active());
create policy user_quota_read on public.user_storage_quota for select to authenticated
  using (auth.uid()=user_id and public.drive_user_active());
revoke all on public.user_files,public.user_storage_quota from anon,authenticated;
grant select on public.user_files,public.user_storage_quota to authenticated;
grant all on public.user_files,public.user_storage_quota to service_role;

-- Writes only through a verified Edge Function: direct writes would allow
-- falsifying object ownership, completed upload sizes or capacity usage.
create function public.drive_service_v1(p_user uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  q public.user_storage_quota;
  f public.user_files;
  size_bytes bigint;
  file_id uuid;
begin
  if not exists(select 1 from auth.users where id=p_user and not coalesce(is_anonymous,false)
    and (banned_until is null or banned_until<now())) then
    raise exception 'DRIVE_ACCOUNT_UNAVAILABLE' using errcode='42501';
  end if;
  insert into public.user_storage_quota(user_id) values(p_user) on conflict do nothing;
  -- Serialize every quota/file transition for one owner, including retries.
  select * into q from public.user_storage_quota where user_id=p_user for update;
  if p_action='quota' then
    if q.request_window > now()-interval '1 minute' and q.request_count>=60 then
      raise exception 'DRIVE_RATE_LIMIT';
    end if;
    update public.user_storage_quota set request_count=case when request_window<=now()-interval '1 minute' then 1 else request_count+1 end,
      request_window=case when request_window<=now()-interval '1 minute' then now() else request_window end where user_id=p_user;
    return to_jsonb(q);
  end if;
  if p_action='begin' then
    file_id:=(p_data->>'id')::uuid;
    size_bytes:=(p_data->>'file_size')::bigint;
    if size_bytes is null or size_bytes<0 or size_bytes>1073741824
      or coalesce(p_data->>'checksum','') !~ '^[a-f0-9]{64}$'
      or coalesce(length(p_data->>'file_name'),0) not between 1 and 240
      or coalesce(p_data->>'bucket_name','')='' then
      raise exception 'DRIVE_INVALID_FILE' using errcode='22023';
    end if;
    select * into f from public.user_files where id=file_id;
    if found then
      if f.user_id<>p_user or f.file_size<>size_bytes or f.checksum<>p_data->>'checksum'
        or f.file_name<>p_data->>'file_name' or f.deleted_at is not null then
        raise exception 'DRIVE_RETRY_MISMATCH' using errcode='42501';
      end if;
      return to_jsonb(f);
    end if;
    if q.used_bytes+q.reserved_bytes+size_bytes>q.quota_bytes then
      raise exception 'DRIVE_QUOTA_EXCEEDED' using errcode='P0001';
    end if;
    if (select count(*) from public.user_files where user_id=p_user and upload_state='reserved')>=100 then
      raise exception 'DRIVE_PENDING_LIMIT';
    end if;
    insert into public.user_files(id,user_id,storage_provider,bucket_name,object_key,file_name,mime_type,file_size,checksum)
      values(file_id,p_user,'aliyun_oss',p_data->>'bucket_name','users/'||p_user::text||'/cloud/'||file_id::text,
        p_data->>'file_name',coalesce(p_data->>'mime_type','application/octet-stream'),size_bytes,p_data->>'checksum')
      returning * into f;
    update public.user_storage_quota set reserved_bytes=reserved_bytes+size_bytes,updated_at=now() where user_id=p_user;
    return to_jsonb(f);
  end if;
  select * into f from public.user_files where id=(p_data->>'id')::uuid and user_id=p_user for update;
  if not found then raise exception 'DRIVE_NOT_FOUND' using errcode='42501'; end if;
  if p_action='get' then return to_jsonb(f);
  elsif p_action='complete' then
    if f.deleted_at is not null then raise exception 'DRIVE_DELETED' using errcode='42501'; end if;
    if (p_data->>'verified_size')::bigint is distinct from f.file_size then
      raise exception 'DRIVE_SIZE_MISMATCH' using errcode='22023';
    end if;
    if f.upload_state='reserved' then
      update public.user_files set upload_state='ready',updated_at=now() where id=f.id returning * into f;
      update public.user_storage_quota set reserved_bytes=reserved_bytes-f.file_size,
        used_bytes=used_bytes+f.file_size,updated_at=now() where user_id=p_user;
    end if;
  elsif p_action='trash' then
    update public.user_files set deleted_at=coalesce(deleted_at,now()),updated_at=now() where id=f.id returning * into f;
  elsif p_action='restore' then
    update public.user_files set deleted_at=null,updated_at=now() where id=f.id returning * into f;
  else raise exception 'DRIVE_INVALID_ACTION' using errcode='22023';
  end if;
  -- Trash still consumes space while its actual object is retained.
  return to_jsonb(f);
end $$;
revoke all on function public.drive_service_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.drive_service_v1(uuid,text,jsonb) to service_role;
comment on table public.user_files is '个人网盘；服务端核验上传后提交，删除进入回收站，不自动销毁对象';
notify pgrst,'reload schema';
commit;
