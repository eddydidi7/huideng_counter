import assert from 'node:assert/strict';
import {createHandler} from '../functions/public-resources/handler.ts';
const calls=[];
const file={id:'file',file_name:'test.pdf',file_size:4,checksum:'a'.repeat(64),object_key:'original',storage_bucket:'group-files',status:'published',verified:false,can_delete:true};
let cleanupCalls=0;
const handler=createHandler({
  endpoint:'https://example.test',signingSecret:'test',
  authenticate:async token=>token==='member'?'user':null,
  rpc:async(actor,action,data)=>{
    calls.push({actor,action,data});
    if(action==='delete'&&denyDelete)throw Error('FORBIDDEN');
    if(action==='delete')return {deleted:true,cleanup_pending:true};
    if(action==='group.verify_step')return {verified:true};
    return {file};
  },
  verifyStored:async f=>{assert.equal(f.storage_bucket,'group-files');return {offset:4,checksum:file.checksum};},
  put:async()=>{throw Error('Should not upload while sharing/deleting');},
  read:async()=>{throw Error('Should not read whole file');},
  download:async f=>{assert.equal(f.storage_bucket,'group-files');return 'https://storage.test/shared-object';},
  cleanup:async()=>{cleanupCalls++;throw Error('temporary outage');},
});
let denyDelete=false;
async function request(action,token='member'){
  return handler(new Request('https://example.test',{method:'POST',headers:{authorization:`Bearer ${token}`},body:JSON.stringify({api_version:1,action,id:'file',file_id:'community-file'})}));
}
for(const action of ['delete','group.download','group.verify'])assert.equal((await request(action,'guest')).status,401);
assert.equal(calls.length,0);
const deleted=await request('delete');assert.equal(deleted.status,200);
assert.equal((await deleted.json()).cleanup_pending,true);assert.equal(cleanupCalls,1);
const download=await request('group.download');assert.equal(download.status,200);
assert.equal((await download.json()).transfer.url,'https://storage.test/shared-object');
const verified=await request('group.verify');assert.equal((await verified.json()).verified,true);
assert(calls.some(c=>c.action==='group.verify_start'));
assert(calls.some(c=>c.action==='group.verify_step'&&c.data.checksum===file.checksum));
assert.equal((await (await request('complete')).json()).file.can_delete,true);
assert.equal((await (await request('begin')).json()).file.can_delete,true);
denyDelete=true;
const denied=await request('delete');
assert.equal(denied.status,403);
assert.equal((await denied.json()).error,'FORBIDDEN');
console.log('PASS handler: authenticated deletion, durable cleanup retry, canonical group download, server verification');
