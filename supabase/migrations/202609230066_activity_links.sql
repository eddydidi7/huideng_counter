-- Dynamic registration/activity links. Apply through Supabase SQL editor.
create table if not exists public.activity_links (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  summary text not null default '' check (char_length(summary) <= 1000),
  cover_url text,
  status text not null default 'open' check (status in ('open','upcoming','ended')),
  link_url text not null check (link_url ~ '^https://'),
  sort_order integer not null default 0,
  visible boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.activity_links enable row level security;
revoke all on public.activity_links from public;
grant select on public.activity_links to anon, authenticated;
drop policy if exists activity_links_public_read on public.activity_links;
create policy activity_links_public_read on public.activity_links for select to anon, authenticated using (visible);
-- Writes remain service-role/admin-api only; no client insert/update/delete policy.
