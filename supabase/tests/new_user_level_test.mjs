import fs from 'node:fs';
import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.PGLITE_MODULE??new URL('../../.dart_tool/group_resource_sql/node_modules/@electric-sql/pglite/dist/index.js',import.meta.url).href);
const db=new PGlite();
await db.exec(`create role anon; create role authenticated;
 create schema auth;
 create table auth.users(id uuid primary key,is_anonymous boolean default false);
 create table public.app_user_levels(user_id uuid primary key references auth.users(id),level integer default 1);
 insert into auth.users values('00000000-0000-0000-0000-000000000001',false),
 ('00000000-0000-0000-0000-000000000002',false),('00000000-0000-0000-0000-000000000003',true);
 insert into public.app_user_levels values('00000000-0000-0000-0000-000000000002',4);`);
const sql=fs.readFileSync(new URL('../migrations/202609290083_new_user_level_two.sql',import.meta.url),'utf8');
await db.exec(sql); await db.exec(sql);
const level=async suffix=>(await db.query('select level from public.app_user_levels where user_id=$1',[
 `00000000-0000-0000-0000-${String(suffix).padStart(12,'0')}`])).rows[0]?.level;
assert.equal(await level(1),1); assert.equal(await level(2),4); assert.equal(await level(3),undefined);
await db.exec(`insert into auth.users values('00000000-0000-0000-0000-000000000004',false);
 update auth.users set is_anonymous=false where id='00000000-0000-0000-0000-000000000003';`);
assert.equal(await level(4),2); assert.equal(await level(3),2);
await db.exec(`update public.app_user_levels set level=5 where user_id='00000000-0000-0000-0000-000000000004';
 update auth.users set is_anonymous=false where id='00000000-0000-0000-0000-000000000004';`);
assert.equal(await level(4),5);
await db.close();
console.log('PASS registration levels: default 2, guest conversion, historical and administrator levels preserved, idempotent migration.');
