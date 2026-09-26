import {createHandler,checksum,ticket} from './handler.ts';
function assert(ok:unknown){if(!ok)throw Error('assertion failed');}
Deno.test('TUS completion cannot publish before server verification; old clients cannot proxy large APK',async()=>{
 let verified=false;let fail=true;const actions:string[]=[];
 const file={id:'id',user_id:'u',upload_id:'i',object_key:'key',file_size:314572800,checksum:'a'.repeat(64),file_name:'a.apk',mime_type:'application/vnd.android.package-archive',status:'uploading',verified:false};
 const h=createHandler({signingSecret:'test',endpoint:'https://example.test',authenticate:async()=> 'u',
 rpc:async(_,action)=>{actions.push(action);if(action==='upload.verify_step'){verified=true;file.verified=true;}if(action==='complete'){assert(verified);file.status='published';}return {file};},
 put:async()=>{throw Error('must not buffer APK');},read:async()=>new Uint8Array(),download:async()=>'',
 resumable:async()=>({token:'scoped-token'}),verifyStored:async()=>{if(fail)throw Error('VERIFY_FAILED');return {offset:file.file_size,checksum:file.checksum};}});
 const call=(action:string,protocol?:string)=>h(new Request('https://example.test',{method:'POST',headers:{authorization:'Bearer good'},body:JSON.stringify({api_version:1,action,upload_protocol:protocol})}));
 assert((await (await call('begin')).json()).error==='UPDATE_REQUIRED');
 assert((await (await call('begin','tus')).json()).resumable.token==='scoped-token');assert(actions.includes('upload.authorize'));
 assert((await call('complete','tus')).status===409);assert(!actions.includes('complete'));
 fail=false;assert((await call('complete','tus')).status===200);assert(verified);
});
Deno.test('authenticated upload verifies bytes, publishes, downloads; no user deletion or forged upload',async()=>{
 const bytes=new TextEncoder().encode('公共资料');const hash=await checksum(bytes);let enabled=true;let writes=0;
 const file={id:'file',user_id:'member',upload_id:'upload',object_key:'resources/member/file/a.txt',file_name:'a.txt',file_size:bytes.length,checksum:hash,mime_type:'application/octet-stream',status:'uploading',verified:false};
 const h=createHandler({signingSecret:'test-only-secret',endpoint:'https://example.test/functions/v1/public-resources',authenticate:async(t)=>t==='good'?'member':null,
 rpc:async(actor,action)=>{assert(actor==='member');if(!enabled&&action!=='list')throw Error('UPLOAD_DISABLED');if(action==='list')return {config:{enabled:true,review_required:false},files:[]};if(action==='upload.verified')file.verified=true;if(action==='complete'){if(!file.verified)throw Error('UPLOAD_NOT_COMPLETE');file.status='published';}return {file};},
 put:async(_,actual)=>{assert(await checksum(actual)===hash);writes++;},read:async()=>bytes,download:async()=> 'https://example.test/file?token=download'});
 const call=(action:string,token='good')=>h(new Request('https://example.test',{method:'POST',headers:{authorization:`Bearer ${token}`},body:JSON.stringify({action,api_version:1})}));
 assert((await call('list','bad')).status===401);
 assert((await call('delete')).status===400);
 assert((await call('complete')).status===409);
 const plan=await (await call('begin')).json();assert(plan.transfer.method==='PUT');assert(!JSON.stringify(plan).includes('object_key'));
 assert((await h(new Request(plan.transfer.url+'bad',{method:'PUT',body:bytes}))).status===401);
 assert((await h(new Request(plan.transfer.url,{method:'PUT',body:bytes}))).status===200);assert(writes===1);
 const complete=await (await call('complete')).json();assert(complete.file.status==='published');assert(!('user_id' in complete.file));
 assert((await (await call('download')).json()).transfer.method==='GET');
 assert((await h(new Request(plan.transfer.url,{method:'PUT',body:bytes}))).status===200);assert(writes===1);
 enabled=false;assert((await h(new Request(plan.transfer.url,{method:'PUT',body:bytes}))).status===409);
});
Deno.test('oversize and corrupted content never reaches object storage',async()=>{
 let writes=0;const expected=new Uint8Array([1,2]);const f={id:'id',user_id:'u',upload_id:'i',object_key:'fixed',file_size:2,checksum:await checksum(expected),file_name:'a.apk',mime_type:'application/vnd.android.package-archive',status:'uploading',verified:false};
 const secret='test-secret';const signed=await ticket(secret,'u','i');
 const h=createHandler({signingSecret:secret,endpoint:'https://example.test',authenticate:async()=>null,rpc:async()=>({file:f}),put:async()=>{writes++;},read:async()=>expected,download:async()=>''});
 for(const b of [new Uint8Array([1,2,3]),new Uint8Array([3,4])])assert((await h(new Request(`https://example.test?ticket=${signed}`,{method:'PUT',body:b}))).status===409);
 assert(writes===0);
});

Deno.test('preview authorizes first and uses bounded transform rather than original download',async()=>{
 let allowed=true, transformed=false;
 const f={id:'id',user_id:'u',upload_id:'i',object_key:'key',file_size:9000000,checksum:'a'.repeat(64),file_name:'image.png',mime_type:'image/png',status:'published',verified:true};
 const h=createHandler({signingSecret:'test',endpoint:'https://example.test',authenticate:async()=> 'u',
 rpc:async(_,action)=>{assert(action==='preview');if(!allowed)throw Error('DOWNLOAD_DISABLED');return {file:f};},
 put:async()=>{},read:async()=>new Uint8Array(),download:async()=>{throw Error('original download forbidden');},
 preview:async(_,large)=>{assert(!large);transformed=true;return 'https://example.test/storage/v1/render/image/sign/test';}});
 const request=()=>h(new Request('https://example.test',{method:'POST',headers:{authorization:'Bearer good'},body:JSON.stringify({api_version:1,action:'preview',large:false})}));
 assert((await request()).status===200);assert(transformed);transformed=false;allowed=false;
 assert((await request()).status===409);assert(!transformed);
});
