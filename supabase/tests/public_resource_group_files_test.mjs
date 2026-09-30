import fs from 'node:fs';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE ??
  new URL('../../.dart_tool/group_resource_sql/node_modules/@electric-sql/pglite/dist/index.js', import.meta.url).href);
const db = new PGlite();
const user = '00000000-0000-4000-8000-000000000001';
const outsider = '00000000-0000-4000-8000-000000000002';
const group = '10000000-0000-4000-8000-000000000001';
const otherGroup = '10000000-0000-4000-8000-000000000002';
const resource = '20000000-0000-4000-8000-000000000001';
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users(id uuid primary key,is_anonymous boolean default false,banned_until timestamptz);
create function auth.uid() returns uuid language sql stable as
  $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table public.forum_restrictions(user_id uuid,blocked boolean);
create table public.chat_rooms(id uuid primary key,title text,kind text);
create table public.chat_members(room_id uuid,user_id uuid,left_at timestamptz);
create table public.chat_group_settings(group_id uuid,allow_upload boolean default true);
create function public.group_upload_allowed(g uuid) returns boolean language sql security definer as $$
 select exists(select 1 from public.chat_members where room_id=g and user_id=auth.uid() and left_at is null)
 and coalesce((select allow_upload from public.chat_group_settings where group_id=g),true) $$;
create table public.public_resource_settings(id boolean,enabled boolean,download_enabled boolean);
create table public.public_resources(id uuid primary key,user_id uuid,file_name text,file_size bigint,
 checksum text,status text,verified boolean,object_key text);
create table public.community_files(id uuid primary key,owner_user_id uuid,bucket text default 'group-files'
 constraint community_files_bucket_check check(bucket='group-files'),object_key text unique,file_name text,
 file_size bigint constraint community_files_file_size_check check(file_size between 1 and 524288000),checksum text);
create table public.chat_group_files(id uuid primary key,group_id uuid,uploader_id uuid,
 file_id uuid references public.community_files(id),deleted_at timestamptz);
create function public.group_file_readable(f uuid) returns boolean language sql security definer as $$
 select exists(select 1 from public.chat_group_files gf join public.chat_members m on m.room_id=gf.group_id
 where gf.file_id=f and gf.deleted_at is null and m.user_id=auth.uid() and m.left_at is null) $$;
create function public.group_learning_v1(p_action text,p_data jsonb) returns jsonb language plpgsql as $$
declare gid uuid:=(p_data->>'group_id')::uuid; n bigint;
begin
 n:=coalesce((select sum(a.file_size) from public.chat_group_files f join public.community_files a
 on a.id=f.file_id where group_id=gid and f.deleted_at is null),0);
 return to_jsonb(n);
end $$;
insert into auth.users(id) values('${user}'),('${outsider}');
insert into public.chat_rooms values('${group}','Group 1','group'),('${otherGroup}','Group 2','group');
insert into public.chat_members values('${group}','${user}',null),('${otherGroup}','${user}',null);
insert into public.public_resource_settings values(true,true,true);
insert into public.public_resources values('${resource}','${user}','video.mp4',536870912,
 '${'a'.repeat(64)}','published',true,'resources/original/video.mp4');
`);
const migration = fs.readFileSync(new URL('../migrations/202609290076_public_resource_group_files.sql', import.meta.url),'utf8');
await db.exec(migration);
await db.exec(migration); // Reapplying must preserve references and permissions.
async function asUser(id) {
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
  await db.exec('set role authenticated');
}
async function call(action,data={}) {
  return (await db.query('select public.group_resource_v1($1,$2) r',[action,data])).rows[0].r;
}
await asUser(user);
assert.equal((await call('groups')).length,2);
const first=await call('save',{group_id:group,resource_id:resource});
assert.equal(first.already_saved,false);
assert.deepEqual(await call('save',{group_id:group,resource_id:resource}),{...first,already_saved:true});
await call('save',{group_id:otherGroup,resource_id:resource});
await db.exec('reset role');
const files=(await db.query('select * from public.community_files')).rows;
assert.equal(files.length,1);
assert.equal(files[0].object_key,'resources/original/video.mp4');
assert.equal(files[0].bucket,'public-resources');
assert.equal((await db.query('select count(*) n from public.chat_group_files')).rows[0].n,2);
assert.equal((await db.query("select public.group_learning_v1('quota',$1) n",[{group_id:group}])).rows[0].n,0);
await asUser(user);
assert.equal((await call('get',{file_id:files[0].id})).id,resource);
await asUser(outsider);
assert.equal((await call('groups')).length,0);
await assert.rejects(()=>call('save',{group_id:group,resource_id:resource}),/UPLOAD_DISABLED/);
await assert.rejects(()=>call('get',{file_id:files[0].id}),/denied/);
await db.exec('reset role');
await db.exec(`insert into public.chat_group_settings values('${group}',false)`);
await asUser(user);
assert.equal((await call('groups')).length,1);
await assert.rejects(()=>call('save',{group_id:group,resource_id:resource}),/UPLOAD_DISABLED/);
await db.exec('reset role');
await db.exec("update public.public_resources set status='hidden'");
await asUser(user);
await assert.rejects(()=>call('get',{file_id:files[0].id}),/FILE_UNAVAILABLE/);
await assert.rejects(()=>call('save',{group_id:otherGroup,resource_id:resource}),/FILE_UNAVAILABLE/);
await db.exec('reset role');
await db.exec("update public.public_resources set status='published'; update public.chat_group_files set deleted_at=now()");
await asUser(user);
await assert.rejects(()=>call('get',{file_id:files[0].id}),/denied/);
assert.equal((await call('save',{group_id:otherGroup,resource_id:resource})).already_saved,false);
await db.exec('reset role');
assert.equal((await db.query('select count(*) n from public.community_files')).rows[0].n,1);
await db.exec('set role anon');
await assert.rejects(()=>call('groups'),/permission denied/);
await db.close();
console.log('PASS: reference reuse, idempotency, quota, membership, disabled upload, takedown, deletion, anonymous access');
