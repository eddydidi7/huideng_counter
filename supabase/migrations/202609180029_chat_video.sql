-- Keep existing guest, privacy, device-claim and signalling checks intact.
begin;
alter table public.chat_calls add column if not exists media_type text not null default 'audio' check (media_type in ('audio','video'));
do $patch$
declare definition text;
begin
 select pg_get_functiondef('public.chat_call_v1(text,jsonb)'::regprocedure) into definition;
 if position('CALL_MEDIA_INVALID' in definition)=0 then
  if position('insert into public.chat_calls(id,room_id,caller_id,callee_id,caller_device,state,expires_at)' in definition)=0 then
   raise exception 'Unexpected chat_call_v1 definition; migration not applied';
  end if;
  definition:=replace(definition, 'if p_action=''start'' then', 'if p_action=''start'' then
  if coalesce(p_data->>''media_type'',''audio'') not in (''audio'',''video'') then raise exception ''CALL_MEDIA_INVALID''; end if;');
  definition:=replace(definition,'c.room_id=rid then return','c.room_id=rid and c.media_type=coalesce(p_data->>''media_type'',''audio'') then return');
  definition:=replace(definition,'caller_device,state,expires_at)','caller_device,state,expires_at,media_type)');
  definition:=replace(definition,'now()+interval ''45 seconds'') returning * into c','now()+interval ''45 seconds'',coalesce(p_data->>''media_type'',''audio'')) returning * into c');
  execute definition;
 end if;
end $patch$;
notify pgrst, 'reload schema';
commit;
