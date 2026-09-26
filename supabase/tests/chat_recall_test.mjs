import {PGlite} from '../../../../work/admin-sql-tests/package/dist/index.js';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
const a='00000000-0000-4000-8000-000000000001', b='00000000-0000-4000-8000-000000000002';
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,is_anonymous boolean default false,banned_until timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated;insert into auth.users(id) values('${a}'),('${b}');
create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint);
create table storage.objects(bucket_id text,name text);alter table storage.objects enable row level security;
create function storage.foldername(text) returns text[] language sql as $$select string_to_array($1,'/')$$;`);
const migration=n=>fs.readFileSync(new URL('../migrations/'+n,import.meta.url),'utf8');
await db.exec(migration('202609170012_chat.sql'));
await db.exec(`alter table public.chat_messages add column is_system boolean default false,
add column attachment_size bigint,add column attachment_mime_type text,add column voice_file_id uuid,
add column voice_duration_ms integer,add column voice_file_size bigint,add column voice_storage_provider text;
create table public.chat_voice_files(id uuid primary key,object_key text);
create table public.chat_group_content(group_id uuid,kind text,title text,body text,payload jsonb,deleted_at timestamptz);
create schema admin_private;create table admin_private.members(user_id uuid,enabled boolean,role text);
insert into admin_private.members values('${a}',true,'admin');
create table public.user_notes(data jsonb);`);
await db.exec(migration('202609210057_chat_recall.sql'));
await db.exec(migration('202609210057_chat_recall.sql')); // repeatable
const user=async u=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[u]);await db.exec('set role authenticated');};
const call=async(action,data={})=>(await db.query('select public.chat_api_v1($1,$2) r',[action,data])).rows[0].r;
await user(a);const room=(await call('direct',{user_id:b})).id;
const first=crypto.randomUUID();await call('send',{room_id:room,id:first,body:'previous'});
for(const kind of ['text','image','video','file','link','note','voice']) {
 await user(a);
 const id=crypto.randomUUID();await call('send',{room_id:room,id,body:kind});
 await db.exec('reset role');
 await db.query("update chat_messages set created_at=now()-interval '1 year' where id=$1",[id]);
 if(['image','video','file'].includes(kind))await db.query("update chat_messages set attachment_path=$2,attachment_name=$3,attachment_kind='file' where id=$1",[id,room+'/'+a+'/'+id,kind]);
 await user(b);await assert.rejects(()=>call('recall',{room_id:room,id}));
 await user(a);await call('recall',{room_id:room,id});await call('recall',{room_id:room,id});
 assert.equal((await call('messages',{room_id:room})).some(m=>m.id===id),false);
 assert.deepEqual(await call('message_presence',{room_id:room,ids:[id,first]}),[first]);
 await call('send',{room_id:room,id,body:'retry must not resurrect'});
 assert.equal((await call('messages',{room_id:room})).some(m=>m.id===id),false);
 await user(b);assert.equal((await call('rooms'))[0].preview,'previous');
}
await assert.rejects(()=>db.query("select public.chat_api_before_recall('rooms','{}')"));
await assert.rejects(()=>db.query('select * from public.chat_attachment_retirements'));
await user(a);const group=crypto.randomUUID();await call('create_group',{id:group,title:'test',members:[b]});
const msg=crypto.randomUUID();await call('send',{room_id:group,id:msg,body:'group'});await call('recall',{room_id:group,id:msg});
await user(b);assert.deepEqual(await call('messages',{room_id:group}),[]);
await db.exec('reset role');
await db.exec("update chat_attachment_retirements set requested_at=now()-interval '2 days'");
const key=(await db.query("select object_key from chat_attachment_retirements limit 1")).rows[0].object_key;
await db.query('insert into user_notes(data) values($1)',[{attachment:key}]);
await db.exec('set role service_role');
let gc=(await db.query("select huideng_chat_cleanup($1,'claim','{}') r",[a])).rows[0].r;
assert.equal(gc.files.some(f=>f.object_key===key),false);
assert.equal(gc.files.length,2);
await db.exec('reset role');
await assert.rejects(()=>db.query('insert into user_notes(data) values($1)',[{attachment:gc.files[0].object_key}]));
assert.equal((await db.query('select count(*) n from chat_attachment_retirements where state=\'shared\'')).rows[0].n,1);
await db.close();console.log('PASS unlimited recall: ownership, historical types, group, previews, offline retry, cleanup queue isolation');
