import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE);
const db = new PGlite();
await db.exec('create schema auth; create table auth.users(id uuid primary key); create role anon; create role authenticated;');
await db.exec(await readFile(new URL('../migrations/202609170009_forum_read.sql', import.meta.url), 'utf8'));
await db.exec(`insert into public.forum_posts(title,body,category_id,visibility,author_name,tags) values
 ('公开佛法','正文','study','published','莲花',array['修行']),
 ('草稿','内容','study','draft','游客','{}'),
 ('隐藏','内容','study','hidden','游客','{}'),
 ('删除','内容','study','published','游客','{}');
 update public.forum_posts set deleted_at=now() where title='删除';`);
for (const role of ['anon','authenticated']) {
 await db.exec(`set role ${role}`);
 const feed = async (search='') => (await db.query('select forum_feed_v1($1) as result',[search])).rows[0].result.items;
 assert.equal((await feed()).length,1);
 for (const term of ['佛法','莲花','修行']) assert.equal((await feed(term)).length,1);
 assert.equal((await feed('%')).length,0);
 await assert.rejects(db.exec("insert into forum_posts(title,body,category_id) values('写入','测试','study')"));
 await assert.rejects(db.exec("select forum_feed_v1('','','invalid')"));
 await assert.rejects(db.exec("select forum_feed_v1('','',null)"));
 await assert.rejects(db.exec("select forum_feed_v1('','','latest',null)"));
 await assert.rejects(db.exec("update forum_posts set visibility='published'"));
 await assert.rejects(db.exec("delete from forum_posts"));
 await db.exec('reset role');
}
await db.exec("update forum_categories set enabled=false where id='study'; set role anon");
assert.equal((await db.query('select forum_feed_v1() as result')).rows[0].result.items.length,0);
await db.close();
console.log('PASS: public visibility, soft delete, disabled category, Chinese title/author/tag search, literal wildcard, role write denial, invalid sort.');
