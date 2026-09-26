import {createClient} from 'npm:@supabase/supabase-js@2';
import {createHandler,checksum,boundedBody,type ResourceFile} from './handler.ts';
import {verifyPart,VERIFY_PART_BYTES} from './verify_stream.ts';
const url=Deno.env.get('SUPABASE_URL')!;
const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const client=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
const objectUrl=(f:ResourceFile)=>`${url}/storage/v1/object/public-resources/${f.object_key.split('/').map(encodeURIComponent).join('/')}`;
const headers={Authorization:`Bearer ${secret}`,apikey:secret};
async function read(f:ResourceFile){const response=await fetch(objectUrl(f),{headers,signal:AbortSignal.timeout(30000)});if(!response.ok)throw Error('VERIFY_FAILED');const blob=new Uint8Array(await response.arrayBuffer());if(blob.length!==f.file_size||await checksum(blob)!==f.checksum)throw Error('VERIFY_FAILED');return blob;}
Deno.serve(createHandler({
 signingSecret:secret,endpoint:`${url}/functions/v1/public-resources`,
 authenticate:async(token)=>{const {data,error}=await client.auth.getUser(token);return !error&&data.user&&!data.user.is_anonymous?data.user.id:null;},
 rpc:async(actor,action,data)=>{const r=actor==='__public__'?await client.rpc('public_resource_guest_v1',{p_action:action,p_data:data}):action==='preview'?await client.rpc('public_resource_preview',{p_actor:actor,p_id:data.id}):action==='share'?await client.rpc('public_resource_share_create',{p_actor:actor,p_id:data.id}):await client.rpc('public_resources_service_v1',{p_actor:actor,p_action:action,p_data:data});if(r.error)throw r.error;return r.data;},
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
 preview:async(f,large)=>{const {data,error}=await client.storage.from('public-resources').createSignedUrl(f.object_key,120,{transform:{width:large?1440:480,height:large?1440:480,resize:'contain',quality:large?80:65}});if(error)throw error;return data.signedUrl;},
 download:async(f)=>{const {data,error}=await client.storage.from('public-resources').createSignedUrl(f.object_key,120,{download:f.file_name});if(error)throw error;return data.signedUrl;}
}));
