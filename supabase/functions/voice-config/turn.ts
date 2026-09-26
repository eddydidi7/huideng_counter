export async function turnServers(urls: string | undefined, secret: string | undefined,
  userId: string, expires: number) {
  if (!urls && !secret) return null;
  if (!urls || !secret || secret.length < 32) throw new Error('TURN configuration incomplete');
  const values = urls.split(',').map(s=>s.trim()).filter(Boolean);
  if (!values.length || values.some(s=>!/^turns?:[a-zA-Z0-9.[\]:-]+(?:\?transport=(udp|tcp))?$/.test(s))) throw new Error('Invalid TURN URL');
  const username = `${expires}:${userId}`;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    {name:'HMAC',hash:'SHA-1'}, false, ['sign']);
  const signature = new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(username)));
  return {urls:values, username, credential:btoa(String.fromCharCode(...signature))};
}
