import {createClient} from 'npm:@supabase/supabase-js@2';
const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const client=createClient(Deno.env.get('SUPABASE_URL')!,secret,{auth:{persistSession:false}});
Deno.serve(async(req)=>{
  if(req.method!=='POST'||req.headers.get('authorization')!==`Bearer ${secret}`)return new Response('Unauthorized',{status:401});
  try{
    const {data,error}=await client.rpc('file_gc_v1',{p_action:'claim'});if(error)throw error;
    let removed=0;
    for(const job of data){
      const result=await client.storage.from(job.bucket).remove([job.object_key]);
      if(result.error)continue;
      const ack=await client.rpc('file_gc_v1',{p_action:'ack',p_data:job});
      if(!ack.error)removed++;
    }
    return Response.json({removed,pending:data.length-removed});
  }catch{return Response.json({error:'CLEANUP_FAILED'},{status:500});}
});
