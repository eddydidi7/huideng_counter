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
