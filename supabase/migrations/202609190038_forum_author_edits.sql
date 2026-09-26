begin;
alter table public.forum_posts add column if not exists content_revision integer not null default 0;
create table if not exists public.forum_author_requests (
 user_id uuid not null references auth.users(id), request_id uuid not null,
 payload jsonb not null, result jsonb not null, created_at timestamptz not null default now(),
 primary key(user_id,request_id)
);
alter table public.forum_author_requests enable row level security;
revoke all on public.forum_author_requests from public,anon,authenticated;

create or replace function public.forum_author_write_v1(p_data jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor uuid:=auth.uid(); p public.forum_posts; previous public.forum_author_requests;
 target uuid; request uuid; operation text; result jsonb; heading text; content text; rich jsonb;
begin
 if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false) and (banned_until is null or banned_until<now())) then raise exception 'login_required'; end if;
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>2000000 then raise exception 'invalid_input'; end if;
 target:=(p_data->>'post_id')::uuid; request:=(p_data->>'request_id')::uuid; operation:=p_data->>'operation';
 if target is null or request is null or operation is null or operation not in ('edit','delete') then raise exception 'invalid_input'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into previous from public.forum_author_requests where user_id=actor and request_id=request;
 if found then
  if previous.payload<>p_data then raise exception 'request_conflict'; end if;
  return previous.result;
 end if;
 select * into p from public.forum_posts where id=target and author_user_id=actor for update;
 if not found or p.deleted_at is not null then raise exception 'post_unavailable'; end if;
 if (p_data->>'content_revision')::integer is distinct from p.content_revision then raise exception 'content_conflict'; end if;
 if p_data->'base_content' is distinct from jsonb_build_object('title',p.title,'body',p.body,'rich_body',p.rich_body) then raise exception 'content_conflict'; end if;
 if operation='edit' then
  if p.visibility<>'published' or exists(select 1 from public.forum_restrictions where user_id=actor and (blocked or muted)) then raise exception 'account_restricted'; end if;
  heading:=btrim(p_data->>'title'); content:=btrim(p_data->>'body'); rich:=nullif(p_data->'rich_body','null'::jsonb);
  if heading is null or length(heading) not between 1 and 160 or content is null or length(content) not between 1 and 20000 or (rich is not null and jsonb_typeof(rich)<>'array') then raise exception 'invalid_input'; end if;
  update public.forum_posts set title=heading,body=content,rich_body=rich,
   updated_at=now(),version=version+1,content_revision=content_revision+1 where id=target;
 else
  update public.forum_posts set deleted_at=now(),updated_at=now(),version=version+1,content_revision=content_revision+1 where id=target;
 end if;
 -- Deliberately do not replace the post, attachments, reactions, replies or share slug.
 result:=jsonb_build_object('id',target,'content_revision',p.content_revision+1,'deleted',operation='delete');
 insert into public.forum_author_requests(user_id,request_id,payload,result) values(actor,request,p_data,result);
 return result;
end $$;
revoke all on function public.forum_author_write_v1(jsonb) from public,anon;
grant execute on function public.forum_author_write_v1(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
