import {createClient} from 'npm:@supabase/supabase-js@2';
import {assumeRole,endpoint,headObject,objectKey,uploadForm,requireUnversioned,type OssConfig} from '../_shared/oss.ts';

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
