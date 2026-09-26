// Supabase Dashboard single-file bundle of existing storage-token and _shared/oss.ts.
// Paste the entire file into index.ts. Contains no secret values.
export type OssConfig = { accessKeyId: string; accessKeySecret: string; roleArn: string; bucket: string; region: string };
export type TemporaryCredential = { accessKeyId: string; accessKeySecret: string; securityToken: string; expiresAt: string };
const enc = new TextEncoder();
const hex = (bytes: Uint8Array) => Array.from(bytes, b=>b.toString(16).padStart(2,'0')).join('');
async function mac256(secret: Uint8Array, value: string) {
  const key=await crypto.subtle.importKey('raw',secret as BufferSource,{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC',key,enc.encode(value)));
}
async function signingKey(secret:string,date:string,region:string) {
  let key=enc.encode('aliyun_v4'+secret);
  for(const value of [date,region,'oss','aliyun_v4_request']) key=await mac256(key,value);
  return key;
}
export async function v4Headers(c:OssConfig,t:TemporaryCredential,method:string,key:string,query='',now=new Date()) {
  const timestamp=now.toISOString().replace(/[-:]|\.\d{3}/g,'');
  const scope=`${timestamp.slice(0,8)}/${c.region.replace(/^oss-/,'')}/oss/aliyun_v4_request`;
  const headers:Record<string,string>={'x-oss-content-sha256':'UNSIGNED-PAYLOAD','x-oss-date':timestamp,'x-oss-security-token':t.securityToken};
  const canonicalHeaders=Object.keys(headers).sort().map(k=>`${k}:${headers[k].trim()}\n`).join('');
  const uri=`/${c.bucket}/${key}`.split('/').map(encodeURIComponent).join('/');
  const canonical=`${method}\n${uri}\n${query}\n${canonicalHeaders}\n\nUNSIGNED-PAYLOAD`;
  const hash=hex(new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(canonical))));
  const signature=hex(await mac256(await signingKey(t.accessKeySecret,timestamp.slice(0,8),c.region.replace(/^oss-/,'')),`OSS4-HMAC-SHA256\n${timestamp}\n${scope}\n${hash}`));
  headers.Authorization=`OSS4-HMAC-SHA256 Credential=${t.accessKeyId}/${scope},Signature=${signature}`;
  return headers;
}
export const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
export async function hmac(secret: string, message: string) {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), {name:'HMAC',hash:'SHA-1'}, false, ['sign']);
  return base64(new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(message))));
}
const escape = (v: string) => encodeURIComponent(v).replace(/[!'()*]/g, c=>`%${c.charCodeAt(0).toString(16).toUpperCase()}`);
export function objectKey(user: string, id: string) {
  const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
  if (!uuid.test(user) || !uuid.test(id)) throw new Error('INVALID_ID');
  return `users/${user}/cloud/${id}`;
}
export function endpoint(c: OssConfig) {
  if(!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(c.bucket) || !/^oss-[a-z0-9-]+$/.test(c.region)) throw new Error('STORAGE_CONFIGURATION_INVALID');
  return `https://${c.bucket}.${c.region}.aliyuncs.com`;
}
export function scopePolicy(c: OssConfig, key: string, write: boolean) {
  return {Version:'1',Statement:[{Effect:'Allow',Action:write?['oss:PutObject','oss:GetObject']:['oss:GetObject'],Resource:[`acs:oss:*:*:${c.bucket}/${key}`]},
    ...(write?[{Effect:'Allow',Action:['oss:GetBucketVersioning'],Resource:[`acs:oss:*:*:${c.bucket}`]}]:[])]};
}
export async function requireUnversioned(c:OssConfig,t:TemporaryCredential,fetcher:typeof fetch=fetch) {
  const response=await fetcher(`${endpoint(c)}/?versioning`,{headers:await v4Headers(c,t,'GET','','versioning'),signal:AbortSignal.timeout(20000)});
  if(!response.ok || /<Status>\s*(Enabled|Suspended)\s*<\/Status>/i.test(await response.text())) throw new Error('BUCKET_VERSIONING_UNSUPPORTED');
}
// A credential is scoped to ONE generated object, never an entire bucket.
export async function assumeRole(c: OssConfig, key: string, write: boolean, fetcher: typeof fetch = fetch): Promise<TemporaryCredential> {
  endpoint(c);
  const params: Record<string,string> = {
    Action:'AssumeRole',Version:'2015-04-01',Format:'JSON',AccessKeyId:c.accessKeyId,
    SignatureMethod:'HMAC-SHA1',SignatureVersion:'1.0',SignatureNonce:crypto.randomUUID(),
    Timestamp:new Date().toISOString().replace(/\.\d{3}Z$/,'Z'),
    RoleArn:c.roleArn,RoleSessionName:`huideng-${crypto.randomUUID().slice(0,16)}`,
    DurationSeconds:'900',Policy:JSON.stringify(scopePolicy(c,key,write)),
  };
  const canonical=Object.keys(params).sort().map(k=>`${escape(k)}=${escape(params[k])}`).join('&');
  const signature=await hmac(`${c.accessKeySecret}&`,`POST&%2F&${escape(canonical)}`);
  const response=await fetcher('https://sts.aliyuncs.com/', {method:'POST',
    headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:`${canonical}&Signature=${escape(signature)}`,signal:AbortSignal.timeout(20000)});
  const result=await response.json();
  if(!response.ok || !result.Credentials) throw new Error('STS_UNAVAILABLE');
  const t=result.Credentials;
  if(!t.AccessKeyId || !t.AccessKeySecret || !t.SecurityToken || Date.parse(t.Expiration)<=Date.now()+60000) throw new Error('STS_INVALID_RESPONSE');
  return {accessKeyId:t.AccessKeyId,accessKeySecret:t.AccessKeySecret,securityToken:t.SecurityToken,expiresAt:t.Expiration};
}
export async function uploadForm(c: OssConfig, t: TemporaryCredential, key: string, size: number) {
  if(!Number.isSafeInteger(size) || size<0 || size>1073741824) throw new Error('INVALID_SIZE');
  const expiration=new Date(Math.min(Date.parse(t.expiresAt),Date.now()+900000)).toISOString();
  const timestamp=new Date().toISOString().replace(/[-:]|\.\d{3}/g,'');
  const region=c.region.replace(/^oss-/,'');
  const authFields={'x-oss-signature-version':'OSS4-HMAC-SHA256','x-oss-credential':`${t.accessKeyId}/${timestamp.slice(0,8)}/${region}/oss/aliyun_v4_request`,'x-oss-date':timestamp};
  const policy=base64(enc.encode(JSON.stringify({expiration,conditions:[
    ...Object.entries(authFields).map(([k,v])=>({[k]:v})),
    {bucket:c.bucket},{key},['content-length-range',size,size],
    {'x-oss-security-token':t.securityToken},{'x-oss-forbid-overwrite':'true'},
    {success_action_status:'201'},
  ]})));
  return {url:endpoint(c),expiresAt:expiration,fields:{key,policy,
    ...authFields,'x-oss-signature':hex(await mac256(await signingKey(t.accessKeySecret,timestamp.slice(0,8),region),policy)),
    'x-oss-security-token':t.securityToken,'x-oss-forbid-overwrite':'true',success_action_status:'201'}};
}
export async function headObject(c: OssConfig,t: TemporaryCredential,key: string,fetcher:typeof fetch=fetch):Promise<number|null> {
  const response=await fetcher(`${endpoint(c)}/${key.split('/').map(encodeURIComponent).join('/')}`,{
    method:'HEAD',headers:await v4Headers(c,t,'HEAD',key),
    signal:AbortSignal.timeout(20000)});
  if(response.status===404) return null;
  if(!response.ok) throw new Error('OSS_VERIFY_FAILED');
  const length=response.headers.get('content-length');
  if(length===null || !/^\d+$/.test(length)) throw new Error('OSS_VERIFY_FAILED');
  return Number(length);
}

import {createClient} from 'npm:@supabase/supabase-js@2';

const reply=(status:number,body:unknown)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
function config():OssConfig|null {
  const c={accessKeyId:Deno.env.get('ALIYUN_STS_ACCESS_KEY_ID')??'',accessKeySecret:Deno.env.get('ALIYUN_STS_ACCESS_KEY_SECRET')??'',
    roleArn:Deno.env.get('ALIYUN_OSS_ROLE_ARN')??'',bucket:Deno.env.get('ALIYUN_OSS_BUCKET')??'',region:Deno.env.get('ALIYUN_OSS_REGION')??''};
  return Object.values(c).every(Boolean)?c:null;
}
Deno.serve(async req=>{
  if(req.method!=='POST') return reply(405,{error:'METHOD_NOT_ALLOWED'});
  const token=req.headers.get('Authorization');
  if(!token?.startsWith('Bearer ')) return reply(401,{error:'LOGIN_REQUIRED'});
  const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await client.auth.getUser(token.slice(7));
  if(authError || !auth.user || auth.user.is_anonymous) return reply(401,{error:'LOGIN_REQUIRED'});
  const user=auth.user.id;
  const rpc=async(action:string,data:Record<string,unknown>={})=>{
    const result=await client.rpc('drive_service_v1',{p_user:user,p_action:action,p_data:data});
    if(result.error) throw result.error;
    return result.data;
  };
  try {
    const reader=req.body?.getReader(); if(!reader) return reply(400,{error:'INVALID_REQUEST'});
    let body='';let size=0;const decoder=new TextDecoder();
    while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;
      if(size>16384){await reader.cancel();return reply(413,{error:'INVALID_REQUEST'});}body+=decoder.decode(value,{stream:true});}
    body+=decoder.decode();
    const input=JSON.parse(body);
    if(!input || typeof input!=='object' || !['list','begin','complete','download','trash','restore'].includes(input.action)) return reply(400,{error:'INVALID_REQUEST'});
    // Actor is ALWAYS the verified JWT subject; caller-supplied user_id is ignored.
    const quota=await rpc('quota');
    const c=config();
    if(input.action==='list') {
      const sort=input.sort==='name'?'file_name':input.sort==='size'?'file_size':'created_at';
      let query=client.from('user_files').select('*').eq('user_id',user).order(sort,{ascending:sort==='file_name'}).order('id',{ascending:false});
      if(typeof input.search==='string' && input.search.trim()) {
        const search=input.search.trim().slice(0,150).replace(/[\\%_]/g,(c:string)=>`\\${c}`);
        query=query.ilike('file_name',`%${search}%`);
      }
      query=input.trash===true?query.not('deleted_at','is',null):query.is('deleted_at',null);
      const offset=Number.isInteger(input.offset)&&input.offset>=0?Math.min(input.offset,100000):0;
      const result=await query.range(offset,offset+99);
      if(result.error) throw result.error;
      return reply(200,{files:result.data,quota,configured:c!==null,provider:'aliyun_oss',nextOffset:result.data.length===100?offset+100:null});
    }
    const id=String(input.id??'');
    const key=objectKey(user,id);
    if(input.action==='trash'||input.action==='restore') return reply(200,{file:await rpc(input.action,{id})});
    if(!c) return reply(503,{error:'STORAGE_NOT_CONFIGURED'});
    endpoint(c);
    if(input.provider && input.provider!=='aliyun_oss') return reply(400,{error:'PROVIDER_UNAVAILABLE'});
    const file=input.action==='begin'?await rpc('begin',{id,file_name:input.file_name,file_size:input.file_size,
      checksum:input.checksum,mime_type:'application/octet-stream',bucket_name:c.bucket}):await rpc('get',{id});
    if(file.deleted_at || file.object_key!==key) return reply(403,{error:'FILE_UNAVAILABLE'});
    // Never silently migrate old files when the platform changes provider/bucket.
    if(file.bucket_name!==c.bucket || file.storage_provider!=='aliyun_oss') return reply(503,{error:'ORIGINAL_STORAGE_UNAVAILABLE'});
    if(input.action==='download') {
      if(file.upload_state!=='ready') return reply(409,{error:'UPLOAD_NOT_COMPLETE'});
      const credential=await assumeRole(c,key,false);
      return reply(200,{file,credential:{...credential,provider:'aliyun_oss',bucket:c.bucket,region:c.region,
        endpoint:endpoint(c),userPrefix:`users/${user}/`,objectKey:key}});
    }
    if(file.upload_state==='ready') return reply(200,{file,alreadyUploaded:true});
    const credential=await assumeRole(c,key,input.action==='begin');
    const actual=await headObject(c,credential,key);
    if(actual!==null) return reply(200,{file:await rpc('complete',{id,verified_size:actual}),alreadyUploaded:true});
    if(input.action==='complete') return reply(409,{error:'UPLOAD_NOT_FOUND'});
    await requireUnversioned(c,credential);
    // Do NOT expose the write STS secret. A raw PutObject credential bypasses
    // content-length-range; only this size-bound form is returned to the app.
    return reply(200,{file,upload:await uploadForm(c,credential,key,file.file_size)});
  } catch(e) {
    const code=String((e as {message?:string}).message??'');
    const allowed=['RESOURCE_ACCOUNT_BANNED','RESOURCE_UPLOAD_PAUSED','RESOURCE_TYPE_BLOCKED','RESOURCE_USER_QUOTA','RESOURCE_DAILY_LIMIT','RESOURCE_MONTHLY_LIMIT','DRIVE_RATE_LIMIT','DRIVE_PENDING_LIMIT','DRIVE_QUOTA_EXCEEDED','DRIVE_ACCOUNT_UNAVAILABLE','DRIVE_INVALID_FILE','DRIVE_RETRY_MISMATCH','DRIVE_NOT_FOUND','DRIVE_SIZE_MISMATCH','DRIVE_DELETED','STS_UNAVAILABLE','STS_INVALID_RESPONSE','OSS_VERIFY_FAILED','STORAGE_CONFIGURATION_INVALID','BUCKET_VERSIONING_UNSUPPORTED'];
    const missing=['PGRST202','42P01'].includes(String((e as {code?:string}).code));
    const safe=missing?'STORAGE_NOT_CONFIGURED':allowed.includes(code)?code:'STORAGE_REQUEST_FAILED';
    // Never log JWTs, temporary credentials, signed forms or permanent keys.
    console.error('storage-token',safe);
    return reply(safe==='DRIVE_RATE_LIMIT'?429:safe==='DRIVE_QUOTA_EXCEEDED'?409:safe==='DRIVE_ACCOUNT_UNAVAILABLE'?403:502,{error:safe});
  }
});

