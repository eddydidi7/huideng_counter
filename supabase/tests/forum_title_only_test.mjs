import fs from 'node:fs';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE ??
  new URL('../../.dart_tool/chat_transfer_sql/package/dist/index.js', import.meta.url).href);
const db = new PGlite();
// Fixtures retain the exact installed empty-post guards from migrations 044/070.
await db.exec(`
  create table public.forum_posts(id integer primary key, title text, body text, image_urls text[]);
  create table public.forum_attachments(post_id integer);
  insert into public.forum_posts values(1, '', 'Historical first sentence. Historical body.', '{}');
  create function public.forum_action_v2(p_action text,p_data jsonb) returns jsonb language plpgsql as $$
  begin
    if p_data->>'actor' <> 'owner' then raise exception 'permission_denied'; end if;
    if length(p_data->>'title')>160 then raise exception 'invalid_title'; end if;
    if p_action='create' then
      if coalesce(btrim(p_data->>'body'),'')='' and jsonb_array_length(coalesce(p_data->'attachments','[]'))=0 then raise exception 'empty_post'; end if;
    end if;
    return p_data;
  end $$;
`);
for (const version of [1, 2]) {
  const images = version === 1 ? 'p.image_urls' : "coalesce((select image_urls from public.forum_posts where id=p.id),'{}')";
  await db.exec(`create function public.forum_author_write_v${version}(p_data jsonb) returns jsonb language plpgsql as $$
    declare p public.forum_posts; heading text:=p_data->>'title'; content text:=p_data->>'body';
    begin
      if p_data->>'actor' <> 'owner' then raise exception 'permission_denied'; end if;
      select * into p from public.forum_posts where id=1;
      if content='' and cardinality(${images})=0 and not exists(select 1 from public.forum_attachments where post_id=p.id) then raise exception 'empty_post'; end if;
      return p_data;
    end $$;`);
}
const sql = fs.readFileSync(new URL('../migrations/202609280075_forum_title_only.sql', import.meta.url), 'utf8');
const history = (await db.query('select * from public.forum_posts')).rows;
await db.exec(sql);
await db.exec(sql);
const payload = { actor: 'owner', title: 'Only title', body: '', attachments: [] };
const create = data => db.query("select public.forum_action_v2('create',$1) value", [data]);
assert.equal((await create(payload)).rows[0].value.title, 'Only title');
await assert.rejects(() => create({ ...payload, title: '' }), /empty_post/);
await assert.rejects(() => create({ ...payload, title: 'x'.repeat(161) }), /invalid_title/);
await assert.rejects(() => create({ ...payload, actor: 'other' }), /permission_denied/);
await create({ ...payload, title: '', body: 'Body only' });
await create({ ...payload, title: '', attachments: [{}] });
for (const version of [1, 2]) {
  const edit = data => db.query(`select public.forum_author_write_v${version}($1) value`, [data]);
  assert.equal((await edit(payload)).rows[0].value.body, '');
  await assert.rejects(() => edit({ ...payload, title: '' }), /empty_post/);
  await assert.rejects(() => edit({ ...payload, actor: 'other' }), /permission_denied/);
}
assert.deepEqual((await db.query('select * from public.forum_posts')).rows, history);
await db.close();
console.log('PASS: idempotent title-only create/edit guards, empty-post rejection, unchanged permissions and historical rows');
