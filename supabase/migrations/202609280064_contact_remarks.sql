-- Private per-viewer remarks (a WeChat-style "备注名/备注") about any other
-- user, stranger or friend. Visible only to the viewer who set it, and only
-- ever surfaced on that person's own profile page (not their real nickname
-- everywhere else, which is unchanged).
begin;

create table if not exists public.chat_contact_remarks(
  owner_id uuid not null references auth.users(id),
  target_id uuid not null references auth.users(id),
  remark_name text not null default '' check(length(remark_name)<=40),
  remark_note text not null default '' check(length(remark_note)<=500),
  updated_at timestamptz not null default now(),
  primary key(owner_id,target_id),
  check(owner_id<>target_id)
);
alter table public.chat_contact_remarks enable row level security;
revoke all on public.chat_contact_remarks from public,anon,authenticated;

create or replace function public.chat_contacts_v1(p_action text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); gid uuid; target uuid; my_role text; rec public.chat_contact_remarks;
begin
  if p_action = 'remark_get' then
    if actor is null then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
    target := nullif(p_data->>'user_id','')::uuid;
    select * into rec from public.chat_contact_remarks where owner_id=actor and target_id=target;
    return jsonb_build_object(
      'remark_name', coalesce(rec.remark_name,''),
      'remark_note', coalesce(rec.remark_note,''));
  end if;

  if p_action = 'remark_set' then
    if actor is null then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
    target := nullif(p_data->>'user_id','')::uuid;
    if target is null or target = actor or not exists(select 1 from auth.users where id=target) then
      raise exception 'CHAT_INVALID_USER';
    end if;
    insert into public.chat_contact_remarks(owner_id,target_id,remark_name,remark_note)
      values(actor,target,left(coalesce(p_data->>'remark_name',''),40),left(coalesce(p_data->>'remark_note',''),500))
      on conflict(owner_id,target_id) do update set
        remark_name=excluded.remark_name, remark_note=excluded.remark_note, updated_at=now();
    return jsonb_build_object('done', true);
  end if;

  if p_action <> 'request' or not (p_data ? 'group_id') then
    return public.chat_contacts_before_group_gate(p_action, p_data);
  end if;
  if actor is null then raise exception 'CHAT_LOGIN_REQUIRED' using errcode='42501'; end if;
  gid := nullif(p_data->>'group_id','')::uuid;
  target := nullif(p_data->>'user_id','')::uuid;
  my_role := public.group_role_of(gid, actor);
  if my_role is null or public.group_role_of(gid, target) is null then
    raise exception 'CHAT_NOT_MEMBER' using errcode='42501';
  end if;
  if my_role not in ('owner','admin')
     and not coalesce((select allow_member_friend_add from public.chat_group_settings where group_id=gid), true)
  then raise exception 'GROUP_FRIEND_ADD_DISABLED'; end if;
  return public.chat_contacts_before_group_gate('request', p_data);
end $$;
revoke all on function public.chat_contacts_v1(text,jsonb) from public,anon;
grant execute on function public.chat_contacts_v1(text,jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
