// Only short-lived coturn REST credentials leave the server. No static TURN
// passwords or service-role keys are returned to Flutter.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { turnServers } from './turn.ts';
const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info'};
const reply = (status: number, data: unknown) => new Response(JSON.stringify(data), {
  status, headers: {...cors, 'Content-Type':'application/json','Cache-Control':'no-store'},
});
Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', {headers:cors});
  if (req.method !== 'POST') return reply(405, {error:'METHOD_NOT_ALLOWED'});
  try {
    const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i,'');
    if (!token) return reply(401, {error:'LOGIN_REQUIRED'});
    const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      auth:{persistSession:false}, global:{headers:{Authorization:`Bearer ${token}`}},
    });
    const {data, error} = await client.auth.getUser(token);
    if (error || !data.user) return reply(401, {error:'LOGIN_REQUIRED'});
    const active = await client.rpc('chat_voice_user_active');
    if (active.error || active.data !== true) return reply(403, {error:'CALL_NOT_ALLOWED'});
    const body = await req.json();
    // Explicit region override or a trusted edge location header, otherwise both
    // node groups are supplied and ICE selects the viable route.
    const country = req.headers.get('cf-ipcountry');
    const cn = body.region === 'cn' || (body.region === 'auto' && country === 'CN');
    const order = cn ? ['CN','GLOBAL'] : ['GLOBAL','CN'];
    const expiry = Math.floor(Date.now()/1000) + 900;
    const iceServers = [];
    for (const region of order) {
      const servers = await turnServers(Deno.env.get(`${region}_TURN_URLS`),
        Deno.env.get(`${region}_TURN_SECRET`), data.user.id, expiry);
      if (servers) iceServers.push(servers);
    }
    return reply(200, {iceServers, turnConfigured:iceServers.length > 0, expiresAt:expiry});
  } catch {
    // Never echo upstream credentials or request headers.
    return reply(503, {error:'CALL_CONFIG_UNAVAILABLE'});
  }
});
