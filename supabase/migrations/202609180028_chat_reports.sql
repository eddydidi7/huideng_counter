begin;
create table if not exists public.chat_reports (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.chat_rooms(id),
 reporter_id uuid not null references auth.users(id),
 reason text not null check(length(btrim(reason)) between 1 and 2000),
 status text not null default 'pending' check(status in ('pending','reviewed','closed')),
 created_at timestamptz not null default now()
);
alter table public.chat_reports enable row level security;
revoke all on public.chat_reports from anon,authenticated;
grant insert(room_id,reporter_id,reason) on public.chat_reports to authenticated;
grant select,update on public.chat_reports to service_role;
drop policy if exists chat_reports_submit on public.chat_reports;
create policy chat_reports_submit on public.chat_reports for insert to authenticated
with check (reporter_id=auth.uid() and public.chat_member(room_id));
commit;
