export type ResourceFile={id:string;user_id:string;upload_id:string;object_key:string;file_size:number;checksum:string;file_name:string;mime_type:string;status:string;verified:boolean;[key:string]:unknown};
export type ResourceDependencies={authenticate:(token:string)=>Promise<string|null>;rpc:(actor:string,action:string,data:Record<string,unknown>)=>Promise<any>;signingSecret:string;endpoint:string;put:(file:ResourceFile,bytes:Uint8Array)=>Promise<void>;read:(file:ResourceFile)=>Promise<Uint8Array>;download:(file:ResourceFile)=>Promise<string>;preview?:(file:ResourceFile,large:boolean)=>Promise<string>;resumable?:(file:ResourceFile)=>Promise<Record<string,unknown>>;verifyStored?:(file:ResourceFile)=>Promise<{offset:number;state?:number[];checksum?:string}>};
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
const publicFile=(f:ResourceFile)=>{const {id,file_name,file_size,checksum,category,description,author_name,status,created_at}=f;return {id,file_name,file_size,checksum,category,description,author_name,status,created_at};};
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
 if(!['list','begin','complete','download','share','preview'].includes(input.action))return reply(400,{error:'ACTION_NOT_ALLOWED'});
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
 }catch(e){const code=String((e as {message?:string})?.message??'');const allowed=['RESOURCE_ACCOUNT_BANNED','RESOURCE_UPLOAD_PAUSED','RESOURCE_TYPE_BLOCKED','RESOURCE_USER_QUOTA','RESOURCE_DAILY_LIMIT','RESOURCE_MONTHLY_LIMIT','LOGIN_REQUIRED','RESOURCE_DISABLED','UPLOAD_DISABLED','DOWNLOAD_DISABLED','RESOURCE_NOT_CONFIGURED','RESOURCE_QUOTA_EXCEEDED','DOWNLOAD_LIMIT','RESOURCE_RATE_LIMIT','FILE_TOO_LARGE','FILE_UNAVAILABLE','UPLOAD_BUSY','UPLOAD_CONFLICT','UPLOAD_NOT_COMPLETE','VERIFY_FAILED','UPLOAD_TIMEOUT','INVALID_REQUEST'];const safe=allowed.includes(code)?code:'RESOURCE_REQUEST_FAILED';return reply(safe==='LOGIN_REQUIRED'?401:409,{error:safe});}
 };}
