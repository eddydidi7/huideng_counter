begin;
-- Explicitly published snapshots only. Private user_notes remains inaccessible.
create table if not exists public.note_web_snapshots (
 owner_id uuid not null references auth.users(id), note_id uuid not null,
 slug text not null unique default replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),
 title text not null default '' check(length(title)<=500),
 body text not null check(length(body)<=5000000),
 created_at timestamptz not null default now(), revoked_at timestamptz,
 primary key(owner_id,note_id)
);
alter table public.note_web_snapshots enable row level security;
revoke all on public.note_web_snapshots from public,anon,authenticated;
create or replace function public.note_web_link_v1(p_note uuid,p_action text,p_title text default '',p_body text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); item public.note_web_snapshots; base text;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_action='publish' then
   insert into public.note_web_snapshots(owner_id,note_id,title,body) values(actor,p_note,p_title,p_body)
   on conflict(owner_id,note_id) do update set title=excluded.title,body=excluded.body,
     slug=case when note_web_snapshots.revoked_at is null then note_web_snapshots.slug else excluded.slug end,revoked_at=null;
 elsif p_action='revoke' then
   update public.note_web_snapshots set revoked_at=now() where owner_id=actor and note_id=p_note;
 elsif p_action<>'get' then raise exception 'INVALID_REQUEST'; end if;
 select * into item from public.note_web_snapshots where owner_id=actor and note_id=p_note and revoked_at is null;
 if not found then return jsonb_build_object('url',null); end if;
 select rtrim(public_base_url,'/') into base from public.community_config where id;
 if base is null or base !~ '^https://' then raise exception 'RESOURCE_NOT_CONFIGURED'; end if;
 return jsonb_build_object('url',base||'/p/'||item.slug);
end $$;
revoke all on function public.note_web_link_v1(uuid,text,text,text) from public,anon;
grant execute on function public.note_web_link_v1(uuid,text,text,text) to authenticated;
do $$ begin
 if to_regprocedure('public.shared_page_before_note_links(text)') is null then
   alter function public.shared_page_v1(text) rename to shared_page_before_note_links;
 end if;
end $$;
create or replace function public.shared_page_v1(p_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare item public.note_web_snapshots; author text;
begin
 select * into item from public.note_web_snapshots where slug=p_slug and revoked_at is null;
 if not found then return public.shared_page_before_note_links(p_slug); end if;
 if exists(select 1 from auth.users where id=item.owner_id and banned_until>now())
 or exists(select 1 from public.forum_restrictions where user_id=item.owner_id and blocked) then raise exception 'post_unavailable'; end if;
 select nickname into author from public.chat_profiles where user_id=item.owner_id;
 return jsonb_build_object('post',jsonb_build_object('id',item.note_id,'title',item.title,'body',item.body,
  'author_user_id',item.owner_id,'author_name',coalesce(author,'学友'),'created_at',item.created_at,
  'post_kind','article','source_type','note','access_level','link_only','tags','[]'::jsonb,'image_urls','[]'::jsonb,
  'attachments','[]'::jsonb,'like_count',0,'reply_count',0),'related','[]'::jsonb);
end $$;
revoke all on function public.shared_page_v1(text) from public;
grant execute on function public.shared_page_v1(text) to anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
