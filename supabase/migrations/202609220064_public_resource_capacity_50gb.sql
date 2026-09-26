-- Global public-resource capacity is server configuration, not an APK value.
-- It counts only public_resources rows that have not been deleted.
begin;
update public.public_resource_settings
set total_bytes = 53687091200, version = version + 1
where id = true and total_bytes = 1073741824;
commit;
