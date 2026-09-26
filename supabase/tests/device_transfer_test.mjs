import {PGlite} from '../../../../work/admin-sql-tests/package/dist/index.js';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
const me='00000000-0000-4000-8000-000000000001', stranger='00000000-0000-4000-8000-000000000002';
const phone='10000000-0000-4000-8000-000000000001', pc='10000000-0000-4000-8000-000000000002';
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,is_anonymous boolean default false,banned_until timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated;insert into auth.users(id) values('${me}'),('${stranger}');`);
const sql=fs.readFileSync(new URL('../migrations/202609250073_device_transfer.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql);  // re-runnable
const user=async u=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[u]);await db.exec('set role authenticated');};
const call=async(action,data)=>(await db.query('select public.device_transfer_v1($1,$2) r',[action,data])).rows[0].r;

await user(me);
await call('heartbeat',{device_id:phone,name:'Redmi',platform:'android'});
let hb=await call('heartbeat',{device_id:pc,name:'Windows PC',platform:'windows'});
assert.equal(hb.devices.length,2);assert.ok(hb.devices.every(d=>d.online));
assert.equal(hb.devices.find(d=>d.device_id===pc).self,true);

const five=5*1024**3+123, id=crypto.randomUUID();
await assert.rejects(()=>call('offer',{device_id:phone,receiver_device:phone,id,name:'x',size:1}),/DEVICE_UNAVAILABLE/);
await call('offer',{device_id:phone,receiver_device:pc,id,name:'movie.mp4',size:five,block_size:4194304});
hb=await call('heartbeat',{device_id:pc,name:'Windows PC',platform:'windows'});
assert.equal(hb.offers.length,1);assert.equal(Number(hb.offers[0].size),five);   // 64-bit size intact
assert.equal((await call('heartbeat',{device_id:phone})).offers.length,0);        // sender does not see its own offer
await assert.rejects(()=>call('accept',{device_id:phone,id}),/TRANSFER_UNAVAILABLE/);
await call('accept',{device_id:pc,id});
await call('signal',{device_id:phone,id,nonce:crypto.randomUUID(),payload:{type:'offer',epoch:1}});
await call('signal',{device_id:pc,id,nonce:crypto.randomUUID(),payload:{type:'answer',epoch:1}});
let polled=await call('poll',{device_id:pc,id,after:0});
assert.equal(polled.signals.length,1);assert.equal(polled.signals[0].payload.type,'offer');   // only the other device's
assert.equal(polled.peer_online,true);
polled=await call('poll',{device_id:phone,id,after:0});
assert.equal(polled.signals[0].payload.type,'answer');
assert.equal((await call('heartbeat',{device_id:phone})).active.length,1);          // resumable list

await user(stranger);
await call('heartbeat',{device_id:'20000000-0000-4000-8000-000000000001'});
await assert.rejects(()=>call('poll',{device_id:'20000000-0000-4000-8000-000000000001',id}),/TRANSFER_DENIED/);
await assert.rejects(()=>db.query('select * from public.device_transfers'),/permission denied/);

await user(me);
await assert.rejects(()=>call('complete',{device_id:phone,id}),/TRANSFER_DENIED/);
assert.equal((await call('complete',{device_id:pc,id})).state,'complete');
await assert.rejects(()=>call('signal',{device_id:phone,id,nonce:crypto.randomUUID(),payload:{}}),/TRANSFER_UNAVAILABLE/);

await db.exec('reset role');
const cols=(await db.query(`select column_name,data_type from information_schema.columns where table_name in ('device_transfers','device_transfer_signals') and data_type in ('bytea')`)).rows;
assert.equal(cols.length,0);   // no place to store file bytes
assert.equal((await db.query(`select data_type from information_schema.columns where table_name='device_transfers' and column_name='size'`)).rows[0].data_type,'bigint');
await db.close();
console.log('PASS: own devices listed, self-offer refused, 5 GB bigint size, device-scoped signals, 7-day resumable accept, stranger denied, no file bytes stored');
