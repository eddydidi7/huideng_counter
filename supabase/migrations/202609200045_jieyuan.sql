begin;
alter table public.forum_posts add column if not exists jieyuan jsonb;
insert into public.forum_categories(id,name_zh,name_en,position,enabled) values('jieyuan','结缘','Sharing',7,true) on conflict(id) do nothing;
create table if not exists public.jieyuan_config(id boolean primary key default true check(id), value jsonb not null);
insert into public.jieyuan_config values(true,'{"enabled":true,"free":true,"paid":true,"wanted":true,"images":true,"resource_images":true,"rules":"禁止违法、危险、武器、毒品、处方药、侵权和诈骗内容。仅分享有权公开传播的资料；内部、限制传阅及需灌顶传承资料不得擅自公开。","currencies":["CNY","NZD","AUD","USD"]}') on conflict do nothing;
create table if not exists public.jieyuan_levels(level integer primary key check(level between 1 and 5), permissions jsonb not null);
insert into public.jieyuan_levels select n,jsonb_build_object('enter',true,'publish',true,'free',true,'paid',true,'wanted',true,'images',n>1,'max_images',case when n=1 then 0 else least(9,n*2) end,'daily_posts',n*3) from generate_series(1,5) n on conflict do nothing;
create table if not exists public.app_user_levels(user_id uuid primary key references auth.users(id),level integer not null default 1 references public.jieyuan_levels(level));
create table if not exists public.jieyuan_reports(id uuid primary key default gen_random_uuid(),user_id uuid references auth.users(id),post_id uuid references public.forum_posts(id),reason text not null check(length(reason) between 1 and 1000),created_at timestamptz default now());
create table if not exists public.jieyuan_warnings(id uuid primary key default gen_random_uuid(),user_id uuid references auth.users(id),message text not null,created_at timestamptz default now());
alter table public.jieyuan_config enable row level security;
alter table public.jieyuan_levels enable row level security;
alter table public.app_user_levels enable row level security;
alter table public.jieyuan_reports enable row level security;
alter table public.jieyuan_warnings enable row level security;
revoke all on public.jieyuan_config,public.jieyuan_levels,public.app_user_levels,public.jieyuan_reports,public.jieyuan_warnings from anon,authenticated;
create or replace function public.jieyuan_permissions() returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select c.value || jsonb_build_object('level',l.level,'permissions',l.permissions,'warnings',(select coalesce(jsonb_agg(message),'[]') from public.jieyuan_warnings where user_id=auth.uid())) from public.jieyuan_config c cross join public.jieyuan_levels l where l.level=coalesce((select level from public.app_user_levels where user_id=auth.uid()),1)
$$;
create or replace function public.jieyuan_visible(j jsonb) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select j is null or coalesce((public.jieyuan_permissions()->>'enabled')::boolean and (public.jieyuan_permissions()->'permissions'->>'enter')::boolean and (public.jieyuan_permissions()->>(j->>'type'))::boolean and (public.jieyuan_permissions()->'permissions'->>(j->>'type'))::boolean,false)
$$;
create or replace function public.jieyuan_validate(j jsonb) returns void language plpgsql immutable as $$
begin
 if j is null or jsonb_typeof(j)<>'object' or octet_length(j::text)>8000 or j->>'type' is null or j->>'type' not in ('free','paid','wanted') or j->>'status' is null or j->>'status' not in ('available','reserved','completed')
 or coalesce((j->>'quantity')::integer,0) not between 1 and 99999 or coalesce(j->>'condition','') not in ('new','like_new','used') or coalesce(j->>'delivery','') not in ('meet','post','both') or coalesce(j->>'postage','') not in ('included','extra','discuss')
 or length(coalesce(j->>'country',''))>80 or length(coalesce(j->>'region',''))>80 then raise exception 'invalid_jieyuan'; end if;
 if j->>'type'='paid' and (coalesce((j->>'price')::numeric,-1) not between 0.01 and 99999999 or round((j->>'price')::numeric,2)<>(j->>'price')::numeric or coalesce(j->>'currency','') !~ '^[A-Z]{3}$') then raise exception 'invalid_price'; end if;
end $$;
create or replace function public.jieyuan_guard() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare cfg jsonb; lim jsonb; n integer;
begin
 if new.category_id<>'jieyuan' then if new.jieyuan is not null then raise exception 'invalid_jieyuan_category'; end if; return new; end if;
 perform public.jieyuan_validate(new.jieyuan);
 if length(btrim(new.title))=0 then raise exception 'item_name_required'; end if;
 if tg_op='UPDATE' and new.jieyuan is not distinct from old.jieyuan and new.title=old.title and new.body=old.body then return new; end if;
 if auth.uid() is null then return new; end if;
 cfg:=public.jieyuan_permissions();lim:=cfg->'permissions';
 if not public.jieyuan_visible(new.jieyuan) or not coalesce((lim->>'publish')::boolean,false) then raise exception 'jieyuan_disabled'; end if;
 if new.jieyuan->>'type'='paid' and not (cfg->'currencies' ? (new.jieyuan->>'currency')) then raise exception 'invalid_currency'; end if;
 if tg_op='INSERT' then
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,45));
 select count(*) into n from public.forum_posts where author_user_id=auth.uid() and category_id='jieyuan' and created_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
 if n>=coalesce((lim->>'daily_posts')::integer,0) then raise exception 'jieyuan_daily_limit'; end if;
 end if;
 return new;
end $$;
create or replace trigger jieyuan_post_guard before insert or update on public.forum_posts for each row execute function public.jieyuan_guard();
create or replace function public.jieyuan_attachment_guard() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare cfg jsonb;begin
 if exists(select 1 from public.forum_posts where id=new.post_id and category_id='jieyuan') then
 cfg:=public.jieyuan_permissions();
 if new.kind<>'image' or not coalesce((cfg->>'images')::boolean and (cfg->>'resource_images')::boolean and (cfg->'permissions'->>'images')::boolean,false) or (select count(*) from public.forum_attachments where post_id=new.post_id)>=coalesce((cfg->'permissions'->>'max_images')::integer,0) then raise exception 'jieyuan_image_limit'; end if;
 end if;return new;end $$;
create or replace trigger jieyuan_attachment_limit before insert on public.forum_attachments for each row execute function public.jieyuan_attachment_guard();
do $$ begin
 if not exists(select 1 from pg_policies where policyname='jieyuan_read_gate' and tablename='forum_posts') then
 create policy jieyuan_read_gate on public.forum_posts as restrictive for select to anon,authenticated using(public.jieyuan_visible(jieyuan));
 end if;
end $$;
-- Extend existing pipelines without replacing records or changing their identifiers.
do $$ declare d text; begin
 d:=pg_get_functiondef('public.forum_action_v1(text,jsonb)'::regprocedure);
 d:=replace(d,'category_id,title,body,visibility)','category_id,title,body,visibility,jieyuan)');
 d:=replace(d,'heading,content,''published'');','heading,content,''published'',case when category=''jieyuan'' then p_data->''jieyuan'' else null end);');
 d:=replace(d,'where id=target and visibility=', 'where public.jieyuan_visible(jieyuan) and id=target and visibility=');
 d:=replace(d,'from public.forum_posts f where visibility=', 'from public.forum_posts f where public.jieyuan_visible(f.jieyuan) and visibility=');
 d:=replace(d,'p.category_id=category and p.deleted_at is null', 'p.category_id=category and p.deleted_at is null and (category<>''jieyuan'' or p.jieyuan is not distinct from p_data->''jieyuan'')');
 d:=replace(d,'select id,author_user_id,author_name','select id,jieyuan,author_user_id,author_name');execute d;
 d:=pg_get_functiondef('public.forum_action_v2(text,jsonb)'::regprocedure);
 d:=replace(d,'''study'',''practice'',''resources'',''feedback''','''study'',''practice'',''resources'',''feedback'',''jieyuan''');execute d;
 d:=pg_get_functiondef('public.forum_feed_v2(text,text,text,integer)'::regprocedure);
 d:=replace(d,'select p.id,p.author_user_id','select p.id,p.jieyuan,p.author_user_id');execute d;
 d:=pg_get_functiondef('public.forum_author_write_v1(jsonb)'::regprocedure);
 if position('jieyuan=case' in d)=0 then d:=replace(d,'set title=heading,body=content,rich_body=rich,','set title=heading,body=content,rich_body=rich,jieyuan=case when category_id=''jieyuan'' then coalesce(p_data->''jieyuan'',jieyuan) else null end,');end if;execute d;
 d:=pg_get_functiondef('public.community_can_read(uuid,text)'::regprocedure);
 d:=replace(d,'where p.id=p_id and','where public.jieyuan_visible(p.jieyuan) and p.id=p_id and');execute d;
 d:=pg_get_functiondef('public.community_profile_v1(uuid,jsonb)'::regprocedure);
 d:=replace(d,'where author_user_id=p_user','where public.jieyuan_visible(f.jieyuan) and author_user_id=p_user');
 d:=replace(d,'select id,title,body,post_kind','select id,jieyuan,title,body,post_kind');execute d;
 d:=pg_get_functiondef('public.shared_page_v1(text)'::regprocedure);
 d:=replace(d,'where f.id<>p.id','where public.jieyuan_visible(f.jieyuan) and f.id<>p.id');execute d;
 if to_regprocedure('public.community_collection_v1(uuid,text)') is not null then
 d:=pg_get_functiondef('public.community_collection_v1(uuid,text)'::regprocedure);
 d:=replace(d,'where r.user_id=p_user','where public.jieyuan_visible(f.jieyuan) and r.user_id=p_user');execute d;
 end if;
 d:=pg_get_functiondef('public.forum_sections_v1()'::regprocedure);
 if position('''jieyuan''' in d)=0 then d:=replace(d,'''feedback'',4)','''feedback'',4),(''jieyuan'',5)');end if;execute d;
end $$;
create or replace function public.jieyuan_feed(p_type text default '',p_offset integer default 0) returns jsonb language sql stable security invoker set search_path=pg_catalog,public as $$
 select jsonb_build_object('items',coalesce(jsonb_agg(to_jsonb(p)),'[]')) from (
 select f.*,coalesce((select jsonb_agg(to_jsonb(a)-'owner_id') from public.forum_attachments a where a.post_id=f.id),'[]') attachments from public.forum_posts f where category_id='jieyuan' and (p_type='' or jieyuan->>'type'=p_type) order by created_at desc,id desc limit 21 offset least(greatest(p_offset,0),10000)) p
$$;
create or replace function public.jieyuan_inquire(p_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare p public.forum_posts;begin
 if auth.uid() is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then raise exception 'login_required'; end if;
 select * into p from public.forum_posts where id=p_id and category_id='jieyuan';
 if not found or not public.community_can_read(p_id) or p.jieyuan->>'status'='completed' then raise exception 'jieyuan_unavailable';end if;
 return jsonb_build_object('author_user_id',p.author_user_id,'title',p.title,'jieyuan',p.jieyuan);end $$;
create or replace function public.jieyuan_report(p_id uuid,p_reason text) returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if auth.uid() is null or not public.community_can_read(p_id) then raise exception 'post_unavailable'; end if;
 if (select count(*) from public.jieyuan_reports where user_id=auth.uid() and created_at>now()-interval '1 day')>=20 then raise exception 'rate_limited'; end if;
 insert into public.jieyuan_reports(user_id,post_id,reason) values(auth.uid(),p_id,p_reason);end $$;
revoke all on function public.jieyuan_permissions(),public.jieyuan_visible(jsonb),public.jieyuan_feed(text,integer),public.jieyuan_inquire(uuid),public.jieyuan_report(uuid,text),public.jieyuan_validate(jsonb),public.jieyuan_guard(),public.jieyuan_attachment_guard() from public;
grant execute on function public.jieyuan_permissions(),public.jieyuan_visible(jsonb),public.jieyuan_feed(text,integer) to anon,authenticated;
grant execute on function public.jieyuan_inquire(uuid),public.jieyuan_report(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
