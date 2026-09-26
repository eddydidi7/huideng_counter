import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {runInNewContext} from 'node:vm';
import assert from 'node:assert/strict';
const source=readFileSync(new URL('../functions/resource-web/index.ts',import.meta.url),'utf8')
  .replace(/^import .*\r?\n/,'').replace(/^const client=.*\r?\n/m,'const client=mockClient;\n');
let handler, denied=false, signed=0;
const mockClient={rpc:async()=>denied?{error:{message:'DOWNLOAD_DISABLED'}}:{data:{object_key:'test.apk',file_name:'test.apk'}},
 storage:{from:()=>({createSignedUrl:async()=>{signed++;return {data:{signedUrl:'https://storage.example/test.apk?token=test'}};}})}};
runInNewContext(stripTypeScriptTypes(source),{mockClient,Deno:{serve:h=>handler=h},Response,URL});
const slug='a'.repeat(64);
let r=await handler(new Request(`https://example/edge?slug=${slug}&download=1&redirect=1`));
assert.equal(r.status,302);assert.equal(r.headers.get('location'),'https://storage.example/test.apk?token=test');
assert.equal(r.headers.get('cache-control'),'no-store');
r=await handler(new Request(`https://example/edge?slug=${slug}&download=1`));assert.equal((await r.json()).url,'https://storage.example/test.apk?token=test');
denied=true;const before=signed;
r=await handler(new Request(`https://example/edge?slug=${slug}&download=1&redirect=1`));assert.equal(r.status,409);assert.equal(r.headers.get('location'),null);assert.equal(signed,before);
r=await handler(new Request('https://example/edge?slug=bad&download=1&redirect=1'));assert.equal(r.status,404);
console.log('4 resource-web checks passed: redirect, legacy JSON, disabled policy, invalid slug');
