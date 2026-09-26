begin;
create table public.app_notices (
 id uuid primary key default gen_random_uuid(),
 title_zh text not null default '' check(length(title_zh)<=200),
 title_en text not null default '' check(length(title_en)<=400),
 body_zh text not null default '' check(length(body_zh)<=20000),
 body_en text not null default '' check(length(body_en)<=40000),
 is_pinned boolean not null default false,
 is_published boolean not null default false,
 published_at timestamptz not null default now(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(not is_published or (length(trim(title_zh))>0 and length(trim(title_en))>0 and length(trim(body_zh))>0 and length(trim(body_en))>0))
);
alter table public.app_notices enable row level security;
revoke all on public.app_notices from anon, authenticated;
grant select on public.app_notices to anon, authenticated;
grant all on public.app_notices to service_role;
create policy notices_public_read on public.app_notices for select to anon, authenticated using (is_published = true);
create function public.touch_app_notices() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end;
$$;
revoke all on function public.touch_app_notices() from public;
create trigger notices_updated before update on public.app_notices for each row execute function public.touch_app_notices();
create index notices_listing on public.app_notices (is_pinned desc, published_at desc, id) where is_published = true;
comment on table public.app_notices is '通知与法语句子：填写中英文，is_published 发布，is_pinned 置顶';
commit;
