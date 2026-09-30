// Run with node; optionally set PGLITE_MODULE to a local PGlite module URL.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const {PGlite} = await import(process.env.PGLITE_MODULE ??
  new URL('../../.dart_tool/chat_transfer_sql/package/dist/index.js', import.meta.url).href);
const db = new PGlite();
const a = '00000000-0000-4000-8000-000000000001';
const b = '00000000-0000-4000-8000-000000000002';
const outsider = '00000000-0000-4000-8000-000000000003';
const da = '10000000-0000-4000-8000-000000000001';
const dbb = '10000000-0000-4000-8000-000000000002';
const room = '20000000-0000-4000-8000-000000000001';
await db.exec(`
  create role anon; create role authenticated;
  create schema auth;
  create table auth.users(id uuid primary key,is_anonymous boolean default false,banned_until timestamptz);
  create function auth.uid() returns uuid language sql stable as
    $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
  create table public.chat_rooms(id uuid primary key,kind text);
  create table public.chat_members(room_id uuid,user_id uuid,left_at timestamptz);
  create table public.chat_blocks(user_id uuid,blocked_id uuid);
  create table public.chat_profiles(user_id uuid,nickname text);
  create table public.chat_privacy(user_id uuid,allow_strangers boolean);
  create function public.chat_member(r uuid) returns boolean language sql stable security definer as
    $$select exists(select 1 from public.chat_members where room_id=r and user_id=auth.uid() and left_at is null)$$;
  create function public.chat_can_contact(s uuid,r uuid) returns boolean language sql stable security definer as
    $$select coalesce((select allow_strangers from public.chat_privacy where user_id=r),true)$$;
  insert into auth.users(id) values('${a}'),('${b}'),('${outsider}');
  insert into public.chat_rooms values('${room}','direct');
  insert into public.chat_members values('${room}','${a}',null),('${room}','${b}',null);
  insert into public.chat_profiles values('${a}','A'),('${b}','B');
`);
const migration = name => fs.readFileSync(new URL(`../migrations/${name}`, import.meta.url),'utf8');
await db.exec(migration('202609170013_chat_live.sql'));
const sql = migration('202609280074_chat_transfer_resume.sql');
await db.exec(sql); await db.exec(sql);
const asUser = async u => {
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[u]);
  await db.exec('set role authenticated');
};
const call = async (action,data) => (await db.query(
  'select public.chat_transfer_v2($1,$2) r',[action,data])).rows[0].r;
await asUser(b);
await db.query('select public.chat_live_v1($1,$2)',['heartbeat',{device_id:dbb}]);
await asUser(a);
const id = crypto.randomUUID();
await call('offer',{id,device_id:da,receiver_id:b,room_id:room,name:'5GB.mp4',size:5368709120});
await assert.rejects(() => call('offer',{id:crypto.randomUUID(),device_id:da,receiver_id:b,room_id:room,name:'too-big',size:5368709121}));
await asUser(b);
await call('accept',{id,device_id:dbb});
await call('signal',{id,device_id:dbb,nonce:crypto.randomUUID(),payload:{type:'answer',sdp:'test'}});
await assert.rejects(() => call('restart',{id,device_id:dbb}),/TRANSFER_UNAVAILABLE/);
await asUser(outsider);
await assert.rejects(() => call('restart',{id,device_id:da}),/TRANSFER_DENIED/);
await asUser(a);
await assert.rejects(() => call('restart',{id,device_id:dbb}),/TRANSFER_UNAVAILABLE/);
await call('restart',{id,device_id:da});
assert.equal((await call('poll',{id,device_id:da,after:0})).state,'offered');
assert.equal((await call('poll',{id,device_id:da,after:0})).signals.length,0);
await asUser(b);
await call('accept',{id,device_id:dbb});
await db.exec('reset role');
await db.exec(`insert into public.chat_privacy values('${b}',false)`);
await asUser(a);
await assert.rejects(() => call('restart',{id,device_id:da}),/CHAT_STRANGERS_DISABLED/);
await db.exec('reset role');
await db.exec('delete from public.chat_privacy');
await db.exec(`insert into public.chat_blocks values('${b}','${a}')`);
await asUser(a);
await assert.rejects(() => call('restart',{id,device_id:da}),/CHAT_BLOCKED/);
await db.exec('reset role');
await db.exec('delete from public.chat_blocks');
await asUser(b);
await call('complete',{id,device_id:dbb});
await asUser(a);
assert.equal((await call('restart',{id,device_id:da})).state,'complete');
await db.close();
console.log('PASS: 5 GiB, oversized rejection, restart, signal reset, recipient reacceptance, account/device/privacy/block isolation, completion recovery, repeat migration');
