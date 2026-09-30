-- Run after deploying shared-file-cleanup. Enable pg_cron and pg_net first.
-- In Supabase Vault create shared_file_project_url and shared_file_service_key.
-- Never put the service-role key into an app, checked-in SQL, or client logs.
do $$ begin
  if not exists(select 1 from vault.decrypted_secrets where name='shared_file_project_url')
    or not exists(select 1 from vault.decrypted_secrets where name='shared_file_service_key') then
    raise exception 'Configure the two shared_file_* secrets in Supabase Vault first';
  end if;
end $$;
select cron.schedule('shared-file-cleanup','*/5 * * * *',$job$
  select net.http_post(
    url:=(select decrypted_secret from vault.decrypted_secrets where name='shared_file_project_url')||'/functions/v1/shared-file-cleanup',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||
      (select decrypted_secret from vault.decrypted_secrets where name='shared_file_service_key')),
    body:='{}'::jsonb,
    timeout_milliseconds:=120000
  );
$job$);
