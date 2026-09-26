begin;
-- Retain schema/history for compatibility. Future writes normalize old clients
-- into the existing favorite state; no note body or history is changed here.
create or replace function public.preserve_note_favorite2() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.data->>'isFavorite2'='1' then
  new.data:=new.data||jsonb_build_object('isFavorite',1);
 end if;
 new.data:=new.data||jsonb_build_object('isFavorite2',0);
 return new;
end $$;
revoke all on function public.preserve_note_favorite2() from public,anon,authenticated;
commit;
