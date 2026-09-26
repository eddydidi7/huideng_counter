-- Edge shared-page uses the server service_role to invoke the guarded RPC.
begin;
grant execute on function public.shared_page_v1(text) to service_role;
notify pgrst, 'reload schema';
commit;
