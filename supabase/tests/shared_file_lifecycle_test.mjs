import fs from 'node:fs';
import assert from 'node:assert/strict';
process.on('uncaughtException',e=>{console.error(e.message,e.where??'',e.internalQuery??'');process.exit(1);});
const {PGlite}=await import(process.env.PGLITE_MODULE??new URL('../../.dart_tool/group_resource_sql/node_modules/@electric-sql/pglite/dist/index.js',import.meta.url).href);
const db=new PGlite();
const a='00000000-0000-4000-8000-000000000001', b='00000000-0000-4000-8000-000000000002', admin='00000000-0000-4000-8000-000000000003';
const g='10000000-0000-4000-8000-000000000001', g2='10000000-0000-4000-8000-000000000002';
const read=name=>fs.readFileSync(new URL(`../migrations/${name}`,import.meta.url),'utf8');
await db.exec(`
 create role anon;create role authenticated;create role service_role;
 create schema auth;create schema storage;create schema admin_private;
 create table auth.users(id uuid primary key,is_anonymous boolean default false,banned_until timestamptz);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create table public.chat_profiles(user_id uuid,nickname text);
 create table public.forum_restrictions(user_id uuid,blocked boolean);
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint);
 create table storage.objects(bucket_id text,name text);
 create table admin_private.members(user_id uuid,role text,enabled boolean);
 create table admin_private.audit_logs(actor uuid,action text,target text,before_data jsonb,after_data jsonb);
 insert into auth.users(id) values('${a}'),('${b}'),('${admin}');
 insert into admin_private.members values('${admin}','super_admin',true);
 insert into public.chat_profiles values('${a}','A'),('${b}','B');
 create table public.chat_rooms(id uuid primary key,title text,kind text);
 create table public.chat_members(room_id uuid,user_id uuid,left_at timestamptz);
 create table public.chat_group_settings(group_id uuid,allow_upload boolean default true);
 create function public.group_upload_allowed(g uuid) returns boolean language sql security definer as $$
 select exists(select 1 from public.chat_members where room_id=g and user_id=auth.uid() and left_at is null)
 and coalesce((select allow_upload from public.chat_group_settings where group_id=g),true) $$;
 create table public.community_files(id uuid primary key,owner_user_id uuid,bucket text default 'group-files'
 constraint community_files_bucket_check check(bucket='group-files'),object_key text unique,file_name text,
 file_size bigint constraint community_files_file_size_check check(file_size between 1 and 524288000),checksum text);
 create table public.chat_group_files(id uuid primary key,group_id uuid,uploader_id uuid,file_id uuid references public.community_files(id),deleted_at timestamptz,album boolean default false,folder_id uuid);
 create table public.chat_group_folders(id uuid primary key,group_id uuid,deleted_at timestamptz);
 create function public.group_file_readable(f uuid) returns boolean language sql security definer as $$
 select exists(select 1 from public.chat_group_files gf join public.chat_members m on m.room_id=gf.group_id
 where gf.file_id=f and gf.deleted_at is null and m.user_id=auth.uid() and m.left_at is null) $$;
 create function public.group_learning_v1(p_action text,p_data jsonb) returns jsonb language plpgsql as $$
 declare gid uuid:=(p_data->>'group_id')::uuid; n bigint;
 begin n:=coalesce((select sum(a.file_size) from public.chat_group_files f join public.community_files a
 on a.id=f.file_id where group_id=gid and f.deleted_at is null),0); return to_jsonb(n);end $$;
 insert into public.chat_rooms values('${g}','G1','group'),('${g2}','G2','group');
 insert into public.chat_members values('${g}','${a}',null),('${g2}','${a}',null);
`);
await db.exec(read('202609200047_public_resources.sql'));
await db.exec(read('202609200048_public_resources_large_files.sql'));
await db.exec('alter table public.public_resources add column moderated boolean not null default false');
await db.exec(read('202609210054_resource_discovery.sql'));
for(const m of ['202609290076_public_resource_group_files.sql','202609290077_shared_file_lifecycle.sql','202609290078_shared_file_transfers.sql']) await db.exec(read(m));
for(const m of ['202609290077_shared_file_lifecycle.sql','202609290078_shared_file_transfers.sql']) await db.exec(read(m));
const rpc=async(actor,action,data={})=>(await db.query('select public.public_resources_service_v1($1,$2,$3) r',[actor,action,data])).rows[0].r;
await db.exec(read('202609290082_resource_delete_capabilities.sql'));
await db.exec(read('202609290082_resource_delete_capabilities.sql'));
const group=async(actor,action,data={})=>{
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[actor]);
 return (await db.query('select public.group_resource_v1($1,$2) r',[action,data])).rows[0].r;
};
const service=async(actor,action,data)=>(await db.query('select public.shared_file_service_v1($1,$2,$3) r',[actor,action,data])).rows[0].r;
const gc=async(action,data={})=>(await db.query('select public.file_gc_v1($1,$2) r',[action,data])).rows[0].r;
const payload={upload_id:crypto.randomUUID(),file_name:'test.pdf',file_size:2,checksum:'a'.repeat(64),category:'经论'};
const initial=(await rpc(a,'begin',payload)).file;
const lease=crypto.randomUUID();
await rpc(a,'upload.start',{upload_id:payload.upload_id,lease_id:lease});
await rpc(a,'upload.verified',{upload_id:payload.upload_id,lease_id:lease,size:2,checksum:payload.checksum});
const file=(await rpc(a,'complete',{upload_id:payload.upload_id})).file;
assert.equal(file.can_delete,true);
assert.equal((await rpc(admin,'list')).files[0].can_delete,true);
assert.equal((await rpc(a,'list')).files[0].can_delete,true);
assert.equal((await rpc(b,'list')).files[0].can_delete,false);
await assert.rejects(()=>rpc(b,'delete',{id:file.id}),/FORBIDDEN/);
let cfg=(await rpc(admin,'admin.list')).config;
assert.equal(cfg.uploader_delete_enabled,true);assert.equal(cfg.group_transfer_enabled,true);
await rpc(admin,'admin.settings',{...cfg,uploader_delete_enabled:false,group_transfer_enabled:false});
await assert.rejects(()=>rpc(a,'delete',{id:file.id}),/FORBIDDEN/);
await assert.rejects(()=>group(a,'save_many',{resource_id:file.id,group_ids:[g,g2]}),/TRANSFER_DISABLED/);
cfg=(await rpc(admin,'admin.list')).config;
await rpc(admin,'admin.settings',{...cfg,uploader_delete_enabled:true,group_transfer_enabled:true});
await assert.rejects(()=>group(b,'save_many',{resource_id:file.id,group_ids:[g]}),/UPLOAD_DISABLED/);
const saved=await group(a,'save_many',{resource_id:file.id,group_ids:[g,g2,g]});
assert.equal(saved.saved.length,2);
await group(a,'save_many',{resource_id:file.id,group_ids:[g,g2]});
let obj=(await db.query('select * from public.file_objects where id=$1',[file.object_id])).rows[0];
assert.equal(obj.ref_count,3);
const c=(await db.query('select * from public.community_files where resource_id=$1',[file.id])).rows[0];
await rpc(a,'delete',{id:file.id});
assert.equal((await service(a,'group.download',{file_id:c.id})).file.object_key,file.object_key);
await assert.rejects(()=>service(b,'group.download',{file_id:c.id}),/FORBIDDEN/);
assert(!(await gc('claim')).some(x=>x.id===file.object_id));
const published=await group(a,'publish',{file_id:c.id,category:'经论'});
assert.equal((await group(a,'publish',{file_id:c.id,category:'经论'})).already_saved,true);
assert.equal((await rpc(b,'download',{id:published.id})).file.object_key,file.object_key);
const same=(await rpc(b,'begin',{...payload,upload_id:crypto.randomUUID()})).file;
assert.equal(same.verified,true);assert.equal(same.object_id,file.object_id);
assert.equal((await db.query('select owner_id from public.file_objects where id=$1',[same.object_id])).rows[0].owner_id,a);
// Verify a private group object before it can participate in deduplication.
const privateFile=crypto.randomUUID();
await db.query(`insert into public.community_files(id,owner_user_id,bucket,object_key,file_name,file_size,checksum)
 values($1,$2,'group-files','private-object','secret.pdf',2,$3)`,[privateFile,a,'b'.repeat(64)]);
await db.query('insert into public.chat_group_files(id,group_id,uploader_id,file_id) values($1,$2,$3,$4)',[crypto.randomUUID(),g,a,privateFile]);
await assert.rejects(()=>group(a,'publish',{file_id:privateFile,category:'经论'}),/VERIFY_REQUIRED/);
const privateLease=crypto.randomUUID();
await service(a,'group.verify_start',{file_id:privateFile,lease_id:privateLease});
await assert.rejects(()=>service(a,'group.verify_step',{file_id:privateFile,lease_id:privateLease,expected_offset:0,offset:2,checksum:'c'.repeat(64)}),/VERIFY_FAILED/);
await service(a,'group.verify_step',{file_id:privateFile,lease_id:privateLease,expected_offset:0,offset:2,checksum:'b'.repeat(64)});
const nonReadable=(await rpc(b,'begin',{...payload,checksum:'b'.repeat(64),upload_id:crypto.randomUUID()})).file;
assert.equal(nonReadable.verified,false);assert.notEqual(nonReadable.object_key,'private-object');
const duplicateLease=crypto.randomUUID();
await rpc(b,'upload.start',{upload_id:nonReadable.upload_id,lease_id:duplicateLease});
await rpc(b,'upload.verified',{upload_id:nonReadable.upload_id,lease_id:duplicateLease,size:2,checksum:'b'.repeat(64)});
const merged=(await rpc(b,'complete',{upload_id:nonReadable.upload_id})).file;
assert.equal(merged.object_key,'private-object');
assert.equal(merged.storage_bucket,'group-files');
assert.equal((await db.query('select count(distinct r.object_id) n from public.file_references r join public.file_objects o on o.id=r.object_id where o.checksum=$1',['b'.repeat(64)])).rows[0].n,1);
assert.equal((await rpc(b,'download',{id:merged.id})).file.storage_bucket,'group-files');
// Reuse preserves the selected album/folder and the requested display name.
const reused=await group(a,'reuse',{group_id:g,file_name:'renamed.pdf',file_size:2,checksum:'b'.repeat(64),album:true});
assert.equal(reused.reused,true);
assert.equal((await db.query('select album from public.chat_group_files where id=$1',[reused.id])).rows[0].album,true);
// Reference removal is independent; live objects cannot be physically deleted.
await db.query('insert into storage.objects values($1,$2)',[file.storage_bucket,file.object_key]);
await assert.rejects(()=>db.query('delete from storage.objects where name=$1',[file.object_key]),/FILE_STILL_REFERENCED/);
await rpc(admin,'admin.delete',{id:published.id});
await rpc(b,'delete',{id:same.id});
await db.query('update public.chat_group_files set deleted_at=now() where file_id=$1',[c.id]);
await db.query("update public.file_objects set not_before=now()-interval '1 second' where id=$1",[file.object_id]);
const job=(await gc('claim')).find(x=>x.id===file.object_id);
assert(job);
await assert.rejects(()=>db.query("insert into public.file_references values('group',$1,$2)",[crypto.randomUUID(),file.object_id]),/FILE_UNAVAILABLE/);
await assert.rejects(()=>gc('ack',{id:job.id,claim_id:crypto.randomUUID()}),/INVALID_CLAIM/);
await db.query('delete from storage.objects where name=$1',[file.object_key]);
await gc('ack',job);
assert.equal((await db.query('select state from public.file_objects where id=$1',[job.id])).rows[0].state,'deleted');
await db.exec('set role authenticated');
await assert.rejects(()=>gc('claim'),/permission denied/);
await assert.rejects(()=>rpc(a,'list'),/permission denied/);
await db.exec('reset role');
await db.close();
console.log('PASS shared lifecycle: server permissions, switches, multi-group references, independent deletion, reverse transfer, verified dedup, private-file isolation, GC locks and leases');
