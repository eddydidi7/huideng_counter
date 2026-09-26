import { readFileSync } from 'node:fs';
const path=process.argv[2];
if(!path)throw Error('Usage: node check-release.mjs DEFINES.json');
const data=JSON.parse(readFileSync(path,'utf8').replace(/^\uFEFF/,''));
const key=data.CONNECTION_CONFIG_PUBLIC_KEY??'';
const sources=(data.CONNECTION_CONFIG_URLS??'').split(',').filter(Boolean).map(s=>new URL(s.trim()));
if(Buffer.from(key,'base64').length!==32)throw Error('A pinned 32-byte Ed25519 public key is required');
if(sources.length<2||sources.length>4||new Set(sources.map(u=>u.hostname)).size<2)throw Error('At least two independent configuration hostnames are required');
for(const url of sources){
 if(url.protocol!=='https:'||url.username||url.password||url.hash||url.hostname==='example.com'||url.hostname.endsWith('.example.com')||url.hostname.endsWith('.invalid'))throw Error('Replace example URLs with real HTTPS configuration URLs');
}
if('CONNECTION_SIGNING_PRIVATE_KEY' in data)throw Error('Private signing keys must never enter app build defines');
console.log('Configuration shape passed. Live TLS, identical signed mirrors and same-project gateway tests are still required.');
