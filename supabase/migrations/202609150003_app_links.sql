-- Public navigation only; no changes to private user tables or policies.
begin;
create table public.app_links (
  id text primary key default 'global' check (id = 'global'),
  calendar_url text not null check (calendar_url ~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' and length(calendar_url) <= 2048),
  forum_url text not null check (forum_url ~ '^https://[^/@[:space:]]+([/?#][^[:space:]]*)?$' and length(forum_url) <= 2048),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.app_links enable row level security;
revoke all on public.app_links from anon, authenticated;
grant select on public.app_links to anon, authenticated;
grant all on public.app_links to service_role;
create policy app_links_public_read on public.app_links
  for select to anon, authenticated using (true);
create function public.touch_app_links() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function public.touch_app_links() from public;
create trigger app_links_updated before update on public.app_links
  for each row execute function public.touch_app_links();
insert into public.app_links (id, calendar_url, forum_url)
values ('global', 'https://zangli.org/', 'https://bodhi-culture.com/Article/question');
comment on table public.app_links is '三端共用网页入口；仅控制台管理员可修改';
comment on column public.app_links.calendar_url is '藏历完整 HTTPS 网址';
comment on column public.app_links.forum_url is '论坛完整 HTTPS 网址';
commit;
