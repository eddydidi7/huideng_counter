import { createClient } from "npm:@supabase/supabase-js@2";
const headers={"Content-Type":"application/json","Cache-Control":"no-store","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,apikey,content-type,x-client-info"};
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response(null,{headers});
 if(req.method!=="POST")return new Response("{}",{status:405,headers});
 try{
  const {slug}=await req.json();if(typeof slug!=="string"||!/^[a-f0-9]{64}$/.test(slug))throw Error();
  const client=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
  // The only content entrypoint enforces current moderation, visibility and expiry.
  const {data,error}=await client.rpc("shared_page_v1",{p_slug:slug});if(error||!data?.post)throw Error();
  const post=data.post;post.image_urls=(post.image_urls??[]).filter((u:unknown)=>typeof u==="string"&&u.startsWith("https://"));
  for(const file of post.attachments??[]){
   if(typeof file.path!=="string"||!file.path.startsWith(post.author_user_id+"/"))continue;
   const {data:signed}=await client.storage.from("forum-files").createSignedUrl(file.path,120);
   if(signed){file.url=signed.signedUrl;if(file.kind==="image")post.image_urls.push(file.url);}
  }
  const {data:profile}=await client.from("chat_profiles").select("avatar_path").eq("user_id",post.author_user_id).maybeSingle();
  if(profile?.avatar_path){const {data:signed}=await client.storage.from("chat-avatars").createSignedUrl(profile.avatar_path,120);post.author_avatar=signed?.signedUrl;}
  return new Response(JSON.stringify(data),{headers});
 }catch(_){return new Response(JSON.stringify({error:"post_unavailable"}),{status:404,headers});}
});
