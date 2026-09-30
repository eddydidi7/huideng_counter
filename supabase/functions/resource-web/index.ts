import {createClient} from 'npm:@supabase/supabase-js@2';
const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
Deno.serve(async(req)=>{
 const reply=(status:number,data:unknown)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
 if(req.method!=='GET')return reply(405,{error:'METHOD_NOT_ALLOWED'});
 const u=new URL(req.url),slug=u.searchParams.get('slug')??'',download=u.searchParams.get('download')==='1';
 if(!/^[a-f0-9]{64}$/.test(slug))return reply(404,{error:'FILE_UNAVAILABLE'});
 try{
 const {data,error}=await client.rpc('public_resource_web_resolve',{p_slug:slug,p_download:download});
 if(error)throw error;
 if(!download)return reply(200,{file:data});
 const signed=await client.storage.from(data.storage_bucket==='group-files'?'group-files':'public-resources').createSignedUrl(data.object_key,120,{download:data.file_name});
 if(signed.error)throw signed.error;
 if(u.searchParams.get('redirect')==='1')return new Response(null,{status:302,headers:{Location:signed.data.signedUrl,'Cache-Control':'no-store'}});
 return reply(200,{url:signed.data.signedUrl});
 }catch(e){const code=(e as {message?:string}).message;return reply(code==='FILE_UNAVAILABLE'?404:409,{error:['FILE_UNAVAILABLE','DOWNLOAD_DISABLED','DOWNLOAD_LIMIT'].includes(code??'')?code:'DOWNLOAD_UNAVAILABLE'});}
});
