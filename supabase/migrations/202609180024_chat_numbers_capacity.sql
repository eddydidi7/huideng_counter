begin;
alter table public.chat_profiles add column if not exists personal_number bigint generated always as identity (start with 10000001);
create unique index if not exists chat_personal_number_unique on public.chat_profiles(personal_number);
create or replace function public.chat_number_immutable() returns trigger language plpgsql set search_path='' as $$
begin
 if new.personal_number is distinct from old.personal_number then raise exception 'CHAT_NUMBER_IMMUTABLE'; end if;
 return new;
end $$;
drop trigger if exists chat_number_immutable on public.chat_profiles;
create trigger chat_number_immutable before update on public.chat_profiles for each row execute function public.chat_number_immutable();
alter table public.chat_rooms add column if not exists member_limit integer not null default 0 check(member_limit>=0);
create or replace function public.chat_capacity_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare r public.chat_rooms;
begin
 if new.left_at is not null then return new; end if;
 if tg_op='UPDATE' and old.left_at is null then return new; end if;
 select * into r from public.chat_rooms where id=new.room_id for update;
 if r.kind='group' and r.member_limit>0 and (select count(*) from public.chat_members where room_id=new.room_id and left_at is null and user_id<>new.user_id)>=r.member_limit then raise exception 'CHAT_GROUP_SIZE'; end if;
 return new;
end $$;
drop trigger if exists chat_capacity_guard on public.chat_members;
create trigger chat_capacity_guard before insert or update on public.chat_members for each row execute function public.chat_capacity_guard();
do $$
declare def text; name text;
begin
 foreach name in array array['public.chat_api_v1(text,jsonb)','public.chat_qr_v1(text,jsonb)','public.chat_contacts_v1(text,jsonb)'] loop
  def:=pg_get_functiondef(name::regprocedure);
  def:=replace(def,'coalesce(cardinality(member_ids),0) not between 1 and 99','coalesce(cardinality(member_ids),0)<1');
  def:=replace(def,'if (select count(*) from public.chat_members where room_id=room and left_at is null)>=100 then raise exception ''CHAT_GROUP_SIZE''; end if;','-- Capacity is enforced atomically by chat_capacity_guard.');
  def:=replace(def,'if (select count(*) from public.chat_members where room_id=rid and left_at is null)>=100 then raise exception ''GROUP_FULL''; end if;','-- Capacity is enforced atomically by chat_capacity_guard.');
  def:=replace(def,'or p.user_id::text=q end','or p.user_id::text=q or p.personal_number::text=q end');
  execute def;
 end loop;
end $$;
commit;
