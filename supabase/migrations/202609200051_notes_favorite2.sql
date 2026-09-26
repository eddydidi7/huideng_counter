begin;
create or replace function public.preserve_note_favorite2() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare previous jsonb;
begin
 if not (new.data ? 'isFavorite2') then
  if tg_op='UPDATE' then previous:=old.data->'isFavorite2';
  else select data->'isFavorite2' into previous from public.user_notes where user_id=new.user_id and id=new.id;end if;
  new.data:=new.data||jsonb_build_object('isFavorite2',coalesce(previous,'0'::jsonb));
 end if;
 if jsonb_typeof(new.data->'isFavorite2') is distinct from 'number' or (new.data->>'isFavorite2') not in ('0','1') then raise exception 'Invalid Favorites 2 flag';end if;
 return new;
end $$;
revoke all on function public.preserve_note_favorite2() from public,anon,authenticated;
drop trigger if exists preserve_note_favorite2 on public.user_notes;
create trigger preserve_note_favorite2 before insert or update on public.user_notes for each row execute function public.preserve_note_favorite2();
commit;
