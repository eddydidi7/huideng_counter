-- Group avatars have been unreadable via signed URL since day one: the
-- storage.objects RLS policy chat_group_avatar_read (202609250072) checks
--   exists(select 1 from chat_group_settings s
--          where s.avatar_path=objects.name and chat_member(s.group_id))
-- but chat_group_settings itself has zero grants to authenticated (by
-- design, so regular clients can't read admin-only fields like muted_until
-- directly). A policy's USING clause still needs the querying role to have
-- its own privileges on any table it references in a sub-select, so that
-- exists(...) check itself was failing with "permission denied for table
-- chat_group_settings" for every authenticated (including guest) caller --
-- this is why chat_avatar.dart's fallback to group_admin_v1('overview') for
-- the *path* never mattered: createSignedUrl() itself was the blocked step.
--
-- Fix: grant SELECT on only the two columns this policy actually reads.
-- This does not expose join_mode, mute state, admin_remark or any other
-- column still locked behind group_admin_v1's role-filtered projections.
begin;
grant select (group_id, avatar_path) on public.chat_group_settings to authenticated;
commit;
