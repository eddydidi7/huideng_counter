begin;
-- Pro-plan capacity alignment (2026-09-26): public drive pool -> 100GB,
-- per-user total quota -> 5GB. Only overwrite rows still on the original
-- 049 defaults so any limits an admin already customized by hand survive.

update public.public_resource_settings set
 total_bytes=107374182400,
 daily_upload_bytes=5368709120,
 daily_download_bytes=10737418240,
 version=version+1
where id=true;

alter table public.resource_user_limits alter column quota_bytes set default 5368709120;
alter table public.resource_user_limits alter column daily_bytes set default 2147483648;
alter table public.resource_user_limits alter column monthly_bytes set default 21474836480;

update public.resource_user_limits set
 quota_bytes=5368709120,
 daily_bytes=2147483648,
 monthly_bytes=21474836480,
 version=version+1
where quota_bytes=1073741824 and daily_bytes=1073741824 and monthly_bytes=10737418240;

-- forum-files was left at its original 10MB bucket cap while chat-files/group-files
-- were bumped to 500MB in 202609200042; align it so forum uploads match other buckets.
update storage.buckets set file_size_limit=104857600
where id='forum-files' and coalesce(file_size_limit,0)<104857600;

notify pgrst,'reload schema';
commit;
