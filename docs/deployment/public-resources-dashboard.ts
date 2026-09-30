import {SHA256} from 'npm:@noble/hashes@1.8.0/sha2';
// Pin the version: checkpoint representation uses this library's protected state.
// Checkpoints never come from clients; only the service-role RPC stores them.
class CheckpointHash extends SHA256 {
  restore(words:number[], offset:number) {
    if(words.length!==8 || offset%64!==0 || !words.every(Number.isInteger))throw Error('VERIFY_FAILED');
    this.set(...words as [number,number,number,number,number,number,number,number]);
    this.length=offset;this.pos=0;
  }
  snapshot(){if(this.pos!==0)throw Error('VERIFY_FAILED');return this.get();}
}
export const VERIFY_PART_BYTES=8*1024*1024;
export function verifyPart(bytes:Uint8Array, offset:number, size:number, words:number[]|null, expected:string){
 if(bytes.length!==Math.min(VERIFY_PART_BYTES,size-offset)||offset<0||offset%VERIFY_PART_BYTES!==0)throw Error('VERIFY_FAILED');
 const hash=new CheckpointHash();
 if(offset){if(!words)throw Error('VERIFY_FAILED');hash.restore(words,offset);}
 hash.update(bytes);const next=offset+bytes.length;
 if(next===size){const digest=Array.from(hash.digest(),x=>x.toString(16).padStart(2,'0')).join('');if(digest!==expected)throw Error('VERIFY_FAILED');return {offset:next,checksum:digest};}
 return {offset:next,state:hash.snapshot()};
}

export type ResourceFile={id:string;user_id:string;upload_id:string;object_key:string;file_size:number;checksum:string;file_name:string;mime_type:string;status:string;verified:boolean;[key:string]:unknown};
export type ResourceDependencies={authenticate:(token:string)=>Promise<string|null>;rpc:(actor:string,action:string,data:Record<string,unknown>)=>Promise<any>;signingSecret:string;endpoint:string;put:(file:ResourceFile,bytes:Uint8Array)=>Promise<void>;read:(file:ResourceFile)=>Promise<Uint8Array>;download:(file:ResourceFile)=>Promise<string>;preview?:(file:ResourceFile,large:boolean)=>Promise<string>;resumable?:(file:ResourceFile)=>Promise<Record<string,unknown>>;verifyStored?:(file:ResourceFile)=>Promise<{offset:number;state?:number[];checksum?:string}>;cleanup?:()=>Promise<void>};
const enc=new TextEncoder();
const reply=(status:number,data:Record<string,unknown>)=>new Response(JSON.stringify({api_version:1,...data}),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});
const hex=(b:ArrayBuffer)=>Array.from(new Uint8Array(b),x=>x.toString(16).padStart(2,'0')).join('');
export async function checksum(bytes:Uint8Array){return hex(await crypto.subtle.digest('SHA-256',bytes as BufferSource));}
const encode=(s:string)=>btoa(s).replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');
const decode=(s:string)=>atob(s.replace(/-/g,'+').replace(/_/g,'/'));
async function key(secret:string){return await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);}
export async function ticket(secret:string,owner:string,upload:string){const body=encode(JSON.stringify({owner,upload,expires:Date.now()+900000}));const signature=encode(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign('HMAC',await key(secret),enc.encode(body)))));return `${body}.${signature}`;}
async function verify(secret:string,value:string){if(value.length>1024)throw Error('LOGIN_REQUIRED');const [body,signature,...extra]=value.split('.');if(!body||!signature||extra.length)throw Error('LOGIN_REQUIRED');let p;try{const signatureBytes=Uint8Array.from(decode(signature),x=>x.charCodeAt(0));if(!await crypto.subtle.verify('HMAC',await key(secret),signatureBytes,enc.encode(body)))throw Error();p=JSON.parse(decode(body));}catch{throw Error('LOGIN_REQUIRED');}if(p.expires<Date.now()||!p.owner||!p.upload)throw Error('LOGIN_REQUIRED');return p;}
export async function boundedBody(req:Request,limit:number){const reader=req.body?.getReader();if(!reader)throw Error('INVALID_REQUEST');let length=0;const chunks:Uint8Array[]=[];let timer:ReturnType<typeof setTimeout>|undefined;try{const timeout=new Promise<never>((_,reject)=>{timer=setTimeout(()=>{void reader.cancel();reject(Error('UPLOAD_TIMEOUT'));},110000);});while(true){const r=await Promise.race([reader.read(),timeout]);if(r.done)break;length+=r.value.length;if(length>limit){await reader.cancel();throw Error('FILE_TOO_LARGE');}chunks.push(r.value);}const result=new Uint8Array(length);let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}return result;}finally{clearTimeout(timer);}}
const publicFile=(f:ResourceFile)=>{const {id,file_name,file_size,checksum,category,description,author_name,status,created_at}=f;return {id,file_name,file_size,checksum,category,description,author_name,status,created_at,can_delete:f.can_delete===true};};
export function createHandler(d:ResourceDependencies){return async(req:Request):Promise<Response>=>{
 try{
 if(req.method==='PUT'){
 const claims=await verify(d.signingSecret,new URL(req.url).searchParams.get('ticket')??'');
 const lease=crypto.randomUUID();const data={upload_id:claims.upload,lease_id:lease};
 const {file}=await d.rpc(claims.owner,'upload.start',data);
 // Completed requests are immutable; do not accept a second body or overwrite.
 if(file.verified||file.status==='published')return reply(200,{uploaded:true});
 if(file.file_size<1||file.file_size>52428800)throw Error('FILE_TOO_LARGE');
 const bytes=await boundedBody(req,file.file_size);
 if(bytes.length!==file.file_size||await checksum(bytes)!==file.checksum)throw Error('VERIFY_FAILED');
 await d.put(file,bytes);
 await d.rpc(claims.owner,'upload.verified',{...data,size:bytes.length,checksum:file.checksum});
 return reply(200,{uploaded:true});
 }
 if(req.method!=='POST')return reply(405,{error:'METHOD_NOT_ALLOWED'});
 const bearer=req.headers.get('authorization');
 // Published resources are readable without an account. Write paths remain
 // authenticated, and the server RPC still enforces publication/moderation.
 const requested=JSON.parse(new TextDecoder().decode(await boundedBody(req,16384)));
 // Only published-resource reads are available without a login. Creating a
 // share link is a write operation and must retain the normal user identity.
 const anonymous=['list','download','preview'].includes(requested.action);
 const actor=bearer?.startsWith('Bearer ')?await d.authenticate(bearer.slice(7)):null;
 if(!actor&&!anonymous)throw Error('LOGIN_REQUIRED');
 const input=requested;
 if(input.api_version!==1)return reply(409,{error:'UPDATE_REQUIRED'});
 if(!['list','begin','complete','download','share','preview','delete','group.download','group.verify'].includes(input.action))return reply(400,{error:'ACTION_NOT_ALLOWED'});
 if(input.action==='group.verify'){
   if(!d.verifyStored)throw Error('UPDATE_REQUIRED');
   const lease_id=crypto.randomUUID();
   const data={file_id:input.file_id,lease_id};
   const {file}=await d.rpc(actor,'group.verify_start',data);
   if(file.verified)return reply(200,{verified:true});
   const step=await d.verifyStored(file);
   const result=await d.rpc(actor,'group.verify_step',{...data,expected_offset:file.verify_offset??0,...step});
   return reply(200,result);
 }
 // TUS transfers bypass this worker. Verify the stored bytes before publishing.
 if(input.action==='complete' && input.upload_protocol==='tus'){
 if(!d.verifyStored)throw Error('UPDATE_REQUIRED');
 const lease=crypto.randomUUID();
 const {file}=await d.rpc(actor,'upload.start',{upload_id:input.upload_id,lease_id:lease});
 if(!file.verified && file.status!=='published'){
 const step=await d.verifyStored(file);
 const advanced=await d.rpc(actor,'upload.verify_step',{upload_id:input.upload_id,lease_id:lease,expected_offset:file.verify_offset??0,...step});
 if(!advanced.file.verified)return reply(200,{verifying:true,verified_bytes:step.offset,total_bytes:file.file_size});
 }
 }
 const result=await d.rpc(actor??'__public__',input.action,input);
 if(input.action==='delete'){
   try{if(d.cleanup)await d.cleanup();}catch{/* Durable queue is retried by the cleanup worker. */}
   return reply(200,result);
 }
 if(input.action==='list')return reply(200,result);
 const file=result.file as ResourceFile;
 if(input.action==='preview'){
 if(!d.preview)throw Error('FILE_UNAVAILABLE');
 return reply(200,{url:await d.preview(file,input.large===true)});
 }
 if(input.action==='begin'){
 if(file.status==='published')return reply(200,{already_uploaded:true,file:publicFile(file)});
 if(input.upload_protocol==='tus' && d.resumable){
 await d.rpc(actor,'upload.authorize',{upload_id:file.upload_id});
 return reply(200,{resumable:await d.resumable(file)});
 }
 if(file.file_size>52428800)return reply(409,{error:'UPDATE_REQUIRED'});
 const signed=await ticket(d.signingSecret,actor,file.upload_id);
 return reply(200,{transfer:{method:'PUT',url:`${d.endpoint}?ticket=${encodeURIComponent(signed)}`,expires_at:new Date(Date.now()+900000).toISOString(),headers:{'Content-Type':file.mime_type},fields:{},file_field:'file'}});
 }
 if(input.action==='complete')return reply(200,{file:publicFile(file)});
 return reply(200,{transfer:{method:'GET',url:await d.download(file),expires_at:new Date(Date.now()+120000).toISOString(),headers:{},fields:{},file_field:'file'}});
 }catch(e){const code=String((e as {message?:string})?.message??'');const allowed=['FORBIDDEN','RESOURCE_ACCOUNT_BANNED','RESOURCE_UPLOAD_PAUSED','RESOURCE_TYPE_BLOCKED','RESOURCE_USER_QUOTA','RESOURCE_DAILY_LIMIT','RESOURCE_MONTHLY_LIMIT','LOGIN_REQUIRED','RESOURCE_DISABLED','UPLOAD_DISABLED','DOWNLOAD_DISABLED','RESOURCE_NOT_CONFIGURED','RESOURCE_QUOTA_EXCEEDED','DOWNLOAD_LIMIT','RESOURCE_RATE_LIMIT','FILE_TOO_LARGE','FILE_UNAVAILABLE','UPLOAD_BUSY','UPLOAD_CONFLICT','UPLOAD_NOT_COMPLETE','VERIFY_FAILED','UPLOAD_TIMEOUT','INVALID_REQUEST'];const safe=allowed.includes(code)?code:'RESOURCE_REQUEST_FAILED';return reply(safe==='LOGIN_REQUIRED'?401:safe==='FORBIDDEN'?403:409,{error:safe});}
 };}

import {createClient} from 'npm:@supabase/supabase-js@2';
const url=Deno.env.get('SUPABASE_URL')!;
const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const client=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
const bucket=(f:ResourceFile)=>f.storage_bucket==='group-files'?'group-files':'public-resources';
const objectUrl=(f:ResourceFile)=>`${url}/storage/v1/object/${bucket(f)}/${f.object_key.split('/').map(encodeURIComponent).join('/')}`;
const headers={Authorization:`Bearer ${secret}`,apikey:secret};
async function read(f:ResourceFile){const response=await fetch(objectUrl(f),{headers,signal:AbortSignal.timeout(30000)});if(!response.ok)throw Error('VERIFY_FAILED');const blob=new Uint8Array(await response.arrayBuffer());if(blob.length!==f.file_size||await checksum(blob)!==f.checksum)throw Error('VERIFY_FAILED');return blob;}
Deno.serve(createHandler({
 signingSecret:secret,endpoint:`${url}/functions/v1/public-resources`,
 authenticate:async(token)=>{const {data,error}=await client.auth.getUser(token);return !error&&data.user&&!data.user.is_anonymous?data.user.id:null;},
 rpc:async(actor,action,data)=>{const r=action.startsWith('group.')?await client.rpc('shared_file_service_v1',{p_actor:actor,p_action:action,p_data:data}):actor==='__public__'?await client.rpc('public_resource_guest_v1',{p_action:action,p_data:data}):action==='preview'?await client.rpc('public_resource_preview',{p_actor:actor,p_id:data.id}):action==='share'?await client.rpc('public_resource_share_create',{p_actor:actor,p_id:data.id}):await client.rpc('public_resources_service_v1',{p_actor:actor,p_action:action,p_data:data});if(r.error)throw r.error;return r.data;},
 read,
 resumable:async(f)=>{
 // Recover an upload whose final acknowledgement was lost or whose TUS URL expired.
 const existing=await fetch(objectUrl(f),{headers:{...headers,Range:'bytes=0-0'},signal:AbortSignal.timeout(15000)});
 await existing.body?.cancel();
 if(existing.status===206||existing.status===200)return {stored:true};
 const {data,error}=await client.storage.from('public-resources').createSignedUploadUrl(f.object_key,{upsert:false});
 if(error)throw error;
 const host=new URL(url);if(host.hostname.endsWith('.supabase.co'))host.hostname=host.hostname.replace('.supabase.co','.storage.supabase.co');
 return {url:`${host.origin}/storage/v1/upload/resumable/sign`,token:data.token,bucket:'public-resources',object_name:f.object_key,content_type:f.mime_type,chunk_size:6291456};
 },
 verifyStored:async(f)=>{
 const offset=Number(f.verify_offset??0),end=Math.min(offset+VERIFY_PART_BYTES,f.file_size)-1;
 const response=await fetch(objectUrl(f),{headers:{...headers,Range:`bytes=${offset}-${end}`},signal:AbortSignal.timeout(20000)});
 if(response.status!==206||response.headers.get('content-range')!==`bytes ${offset}-${end}/${f.file_size}`||!response.body){await response.body?.cancel();throw Error('UPLOAD_NOT_COMPLETE');}
 const bytes=await boundedBody(new Request('https://verification.local',{method:'POST',body:response.body}),end-offset+1);
 return verifyPart(bytes,offset,f.file_size,(f.verify_state??null) as number[]|null,f.checksum);
 },
 put:async(f,bytes)=>{const response=await fetch(objectUrl(f),{method:'POST',headers:{...headers,'Content-Type':f.mime_type,'x-upsert':'false','cache-control':'no-store'},body:bytes as BodyInit,signal:AbortSignal.timeout(30000)});if(!response.ok){await read(f);} },
 preview:async(f,large)=>{const {data,error}=await client.storage.from(bucket(f)).createSignedUrl(f.object_key,120,{transform:{width:large?1440:480,height:large?1440:480,resize:'contain',quality:large?80:65}});if(error)throw error;return data.signedUrl;},
 download:async(f)=>{const {data,error}=await client.storage.from(bucket(f)).createSignedUrl(f.object_key,120,{download:f.file_name});if(error)throw error;return data.signedUrl;},
 cleanup:async()=>{
   const {data,error}=await client.rpc('file_gc_v1',{p_action:'claim'});if(error)throw error;
   for(const job of data){
     const removed=await client.storage.from(job.bucket).remove([job.object_key]);if(removed.error)throw removed.error;
     const ack=await client.rpc('file_gc_v1',{p_action:'ack',p_data:job});if(ack.error)throw ack.error;
   }
 }
}));
