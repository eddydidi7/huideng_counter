-- Public editorial content only. Does not modify any private user data tables.
begin;
create table public.home_messages (
  id text primary key default 'home' check (id = 'home'),
  body_zh text not null default '' check (char_length(body_zh) <= 2000),
  body_en text not null default '' check (char_length(body_en) <= 4000),
  source_zh text not null default '' check (char_length(source_zh) <= 200),
  source_en text not null default '' check (char_length(source_en) <= 400),
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not is_published or (length(trim(body_zh)) > 0 and length(trim(body_en)) > 0))
);
alter table public.home_messages enable row level security;
revoke all on public.home_messages from anon, authenticated;
grant select on public.home_messages to anon, authenticated;
grant all on public.home_messages to service_role;
create policy home_messages_public_read on public.home_messages
  for select to anon, authenticated using (is_published = true);
-- Only trusted dashboard administrators/server credentials may write.
create function public.touch_home_message() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function public.touch_home_message() from public;
create trigger home_message_updated before update on public.home_messages
  for each row execute function public.touch_home_message();
insert into public.home_messages (id) values ('home');
commit;
