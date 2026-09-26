import {PGlite} from '../../../../work/admin-sql-tests/package/dist/index.js';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
const ids=Array.from({length:20},(_,i)=>`00000000-0000-4000-8000-${String(i+1).padStart(12,'0')}`);
const [owner,adm,mem,other,late,...rest]=ids;
const migration=n=>fs.readFileSync(new URL('../migrations/'+n,import.meta.url),'utf8');
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,is_anonymous boolean default false,banned_until timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;
grant usage on schema auth to authenticated;
create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint);
create table storage.objects(bucket_id text,name text,metadata jsonb);alter table storage.objects enable row level security;
create function storage.foldername(text) returns text[] language sql as $$select string_to_array($1,'/')$$;
create table public.app_notices(id uuid primary key);
create schema admin_private;create table admin_private.members(user_id uuid,enabled boolean,role text);
create table public.user_notes(data jsonb);`);
for(const id of ids)await db.query('insert into auth.users(id) values($1)',[id]);
await db.exec(migration('202609170012_chat.sql').replaceAll('not coalesce(is_anonymous,false)','true').replaceAll('not coalesce(u.is_anonymous,false)','true'));
await db.exec(migration('202609170017_chat_avatars.sql'));
await db.exec(migration('202609180020_chat_qr.sql').replaceAll('not coalesce(is_anonymous,false) and ',''));
await db.exec(migration('202609180031_group_learning.sql'));
await db.exec(migration('202609180024_chat_numbers_capacity.sql').split('do $$')[0]+'commit;');
await db.exec(migration('202609210061_group_management.sql'));
await db.exec(`alter table public.chat_messages add column if not exists attachment_size bigint,add column if not exists attachment_mime_type text,
add column if not exists voice_file_id uuid,add column if not exists voice_duration_ms integer,add column if not exists voice_file_size bigint,
add column if not exists voice_storage_provider text;create table public.chat_voice_files(id uuid primary key,object_key text);`);
await db.exec(migration('202609210057_chat_recall.sql'));
await db.exec(migration('202609250072_group_admin.sql'));
await db.exec(migration('202609250072_group_admin.sql')); // re-runnable
const user=async u=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[u]);await db.exec('set role authenticated');};
const call=async(action,data={})=>(await db.query('select public.chat_api_v1($1,$2) r',[action,data])).rows[0].r;
const admin=async(action,data={})=>(await db.query('select public.group_admin_v1($1,$2) r',[action,data])).rows[0].r;
const invite=async(room,users)=>(await db.query('select public.group_invite_v1($1,$2) r',[room,users])).rows[0].r;
const qr=async(action,data)=>(await db.query('select public.chat_qr_v1($1,$2) r',[action,data])).rows[0].r;
const send=async(room,body,extra={})=>call('send',{room_id:room,id:crypto.randomUUID(),body,...extra});
const age=async(room)=>{await db.exec('reset role');await db.query("update chat_messages set created_at=created_at-interval '10 minutes' where room_id=$1",[room]);};

for(const u of ids){await user(u);await call('directory');}
await user(owner);
const group=crypto.randomUUID();
await call('create_group',{id:group,title:'大群',members:[adm,mem,other,...rest.slice(0,11)]});
const room={room_id:group};

// ---- Admins: owner only, at most 10, admins cannot demote each other.
await admin('set_admin',{...room,user_id:adm});
for(const u of rest.slice(0,9))await admin('set_admin',{...room,user_id:u});
await assert.rejects(()=>admin('set_admin',{...room,user_id:rest[9]}),/GROUP_ADMIN_LIMIT/);
await user(adm);
await assert.rejects(()=>admin('set_admin',{...room,user_id:rest[0],enabled:false}),/GROUP_OWNER_REQUIRED/);
let page=await admin('members',{...room,limit:2});
assert.equal(page.managers.length,11);assert.equal(page.managers[0].role,'owner');
assert.equal(page.items.length,2);assert.ok(page.items.every(m=>m.role==='member'));
assert.equal(page.total,15);
const next=await admin('members',{...room,limit:2,before_at:page.items[1].joined_at,before_id:page.items[1].user_id});
assert.equal(next.managers.length,0);assert.ok(next.items.every(m=>!page.items.some(p=>p.user_id===m.user_id)));

// ---- Mutes: admin mutes members only; muted members read but cannot post.
let r=await admin('mute',{...room,user_ids:[mem,rest[0],owner],minutes:60});
assert.deepEqual(r,{done:1,skipped:2});
await user(mem);await assert.rejects(()=>send(group,'hi'),/GROUP_MUTED/);
assert.ok(Array.isArray(await call('messages',room)));
await user(adm);await admin('mute',{...room,user_id:mem,minutes:0});
await user(mem);await send(group,'unmuted');
await user(adm);await admin('mute',{...room,user_id:other,minutes:-1});
await user(other);await assert.rejects(()=>send(group,'perm'),/GROUP_MUTED/);
await user(adm);await admin('mute',{...room,user_id:other,minutes:0});

// ---- All-mute: managers still speak; owner may exempt a member.
await admin('all_mute',{...room,enabled:true});
await user(mem);await assert.rejects(()=>send(group,'x'),/GROUP_ALL_MUTED/);
await user(adm);await send(group,'admin still speaks');
await assert.rejects(()=>admin('exempt',{...room,user_id:mem}),/GROUP_OWNER_REQUIRED/);
await user(owner);await admin('exempt',{...room,user_id:mem});
await user(mem);await send(group,'exempted');
await user(owner);await admin('all_mute',{...room,enabled:false});

// ---- Remove, blacklist, unban.
await user(adm);r=await admin('remove',{...room,user_ids:[other],ban:true});assert.equal(r.done,1);
await user(owner);r=await invite(group,[other]);assert.equal(r.added,0);assert.equal(r.banned,1);
await user(adm);await admin('unban',{...room,user_id:other});
await user(owner);assert.equal((await invite(group,[other])).added,1);
await user(adm);await admin('remove',{...room,user_ids:[other]});   // plain removal
await user(owner);assert.equal((await invite(group,[other])).added,1);

// ---- Join modes, QR, approval, pause, new-member mute.
const token=(await qr('code',room)).token;
await admin('settings',{...room,settings:{join_mode:'invite'}});
await user(late);await assert.rejects(()=>qr('join',{token}),/GROUP_INVITE_ONLY/);
await user(owner);await admin('settings',{...room,settings:{join_mode:'approval',new_member_mute_minutes:10}});
await user(late);await assert.rejects(()=>qr('join',{token}),/GROUP_APPROVAL_REQUIRED/);
assert.equal((await admin('request_join',{token,message:'请通过'})).requested,true);
await user(mem);assert.equal((await invite(group,[rest[12]])).requested,1);  // member invite -> request
await user(adm);const reqs=await admin('requests',room);assert.equal(reqs.length,2);
await admin('decide',{...room,request_id:reqs.find(x=>x.user_id===late).id,approve:true});
await user(late);await assert.rejects(()=>send(group,'new'),/GROUP_MUTED/);   // new-member mute
await user(owner);await admin('settings',{...room,settings:{join_mode:'open',joins_paused:true,new_member_mute_minutes:0}});
await user(mem);await assert.rejects(()=>invite(group,[rest[13]]),/GROUP_JOINS_PAUSED/);
await user(adm);assert.equal((await invite(group,[rest[13]])).added,1);   // managers may
await user(owner);await admin('settings',{...room,settings:{joins_paused:false,allow_qr:false}});
await user(rest[14]);await assert.rejects(()=>qr('join',{token}),/GROUP_QR_DISABLED/);
await user(owner);await admin('settings',{...room,settings:{allow_qr:true,qr_valid_days:30}});
assert.ok(new Date((await qr('rotate',room)).expires_at)-Date.now()>29*86400000);

// ---- Required announcement.
await admin('settings',{...room,settings:{require_announcement_read:true}});
const ann=(await admin('announce',{...room,title:'群规',body:'请先阅读',popup:true,is_pinned:true,payload:{links:['https://example.com']}})).id;
await user(mem);await assert.rejects(()=>send(group,'x'),/GROUP_READ_ANNOUNCEMENT/);
assert.equal((await admin('popup',room)).id,ann);
await admin('ack',{...room,item_id:ann});
assert.equal(await admin('popup',room),null);
await send(group,'read it');
assert.equal((await admin('announcements',room))[0].is_read,true);

// ---- Anti-spam (members only), reject without banning.
await user(owner);await admin('settings',{...room,settings:{require_announcement_read:false}});
await user(mem);await age(group);await user(mem);
await send(group,'same');await send(group,'same');
await assert.rejects(()=>send(group,'same'),/GROUP_DUPLICATE/);
await age(group);await user(mem);
for(let i=0;i<8;i++)await send(group,'m'+i);
await assert.rejects(()=>send(group,'m9'),/GROUP_SLOW_DOWN/);
await age(group);await user(adm);for(let i=0;i<10;i++)await send(group,'admin '+i);  // managers exempt
await user(owner);await admin('settings',{...room,settings:{spam_guard:false}});
await user(mem);for(let i=0;i<10;i++)await send(group,'free'+i);
await user(owner);await admin('settings',{...room,settings:{spam_guard:true}});

// ---- Moderation: delete, purge, pin; personal recall unchanged.
await age(group);
await user(mem);const bad=crypto.randomUUID();await call('send',{room_id:group,id:bad,body:'违规链接 https://spam'});
const mine=crypto.randomUUID();await call('send',{room_id:group,id:mine,body:'my own'});
await user(owner);const ownerMsg=crypto.randomUUID();await call('send',{room_id:group,id:ownerMsg,body:'owner says'});
await user(adm);r=await admin('delete_messages',{...room,ids:[bad,ownerMsg]});assert.deepEqual(r,{done:1,skipped:1});
await user(mem);assert.deepEqual(await call('message_presence',{room_id:group,ids:[bad,mine,ownerMsg]}),[mine,ownerMsg]);
await call('recall',{room_id:group,id:mine});                      // personal recall still works
await assert.rejects(()=>call('recall',{room_id:group,id:ownerMsg}),/CHAT_RECALL_DENIED/);
await user(adm);await admin('pin',{...room,message_id:ownerMsg});
await user(mem);assert.equal((await admin('pins',room))[0].id,ownerMsg);
await user(adm);r=await admin('purge_member',{...room,user_id:mem,hours:24});assert.ok(r.done>=10);
await user(mem);assert.equal((await admin('search',{...room,user_id:mem})).length,0);
await user(adm);await assert.rejects(()=>admin('purge_member',{...room,user_id:rest[0]}),/CHAT_MANAGER_REQUIRED/);

// ---- Search filters, nickname, logs, transfer.
await user(adm);await send(group,'参考 https://example.org');
await user(mem);
assert.equal((await admin('search',{...room,kind:'link'}))[0].body,'参考 https://example.org');
assert.equal((await admin('search',{...room,query:'参考',user_id:adm})).length,1);
assert.equal((await admin('my_nickname',{...room,nickname:'小明'})).nickname,'小明');
await user(owner);await admin('settings',{...room,settings:{allow_member_nickname:false}});
await user(mem);await assert.rejects(()=>admin('my_nickname',{...room,nickname:'x'}),/GROUP_NICKNAME_DISABLED/);
await user(adm);await assert.rejects(()=>admin('logs',room),/GROUP_OWNER_REQUIRED/);
await user(owner);
const logs=await admin('logs',{...room,limit:100});
for(const a of ['set_admin','mute','unmute','all_mute','exempt','ban','unban','remove','approve_join','settings','announcement','delete_messages','purge_member','pin_message'])
  assert.ok(logs.some(l=>l.action===a),'missing log '+a);
assert.ok(logs.some(l=>l.action==='mute'&&l.actor_name&&l.target_id===mem));
// All 10 admin seats are taken: free one so the previous owner keeps admin.
await admin('set_admin',{...room,user_id:rest[8],enabled:false});
assert.equal((await admin('overview',room)).admin_count,9);
await admin('transfer_owner',{...room,user_id:mem});
assert.equal((await admin('overview',room)).my_role,'admin');
await user(mem);assert.equal((await admin('overview',room)).my_role,'owner');

// ---- Tables are only reachable through the RPC.
await user(mem);
for(const t of ['chat_group_bans','chat_group_join_requests','chat_group_logs','chat_group_pins'])
  await assert.rejects(()=>db.query(`select * from public.${t}`),/permission denied/);
await db.exec('reset role');
const rls=(await db.query(`select bool_and(relrowsecurity) ok from pg_class where relname in ('chat_group_bans','chat_group_join_requests','chat_group_logs','chat_group_pins')`)).rows[0].ok;
assert.equal(rls,true);
await db.close();
console.log('PASS: 10-admin cap, owner-only powers, timed/permanent mute, all-mute exemption, blacklist, join modes/QR/approval/pause, new-member mute, required announcement, anti-spam, moderation sync, recall intact, pins, paged members, search, nicknames, audit log, transfer, RLS');
