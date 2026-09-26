import { createPrivateKey, generateKeyPairSync, sign } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

// Run manually when infrastructure exists. Never commit the private PEM.
const [command, keyFile, inputFile, outputFile] = process.argv.slice(2);
if (command === 'keygen' && keyFile) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  writeFileSync(keyFile, privateKey.export({type:'pkcs8',format:'pem'}), {flag:'wx',mode:0o600});
  const der = publicKey.export({type:'spki',format:'der'});
  console.log('Public key (CONNECTION_CONFIG_PUBLIC_KEY):', der.subarray(-32).toString('base64'));
  console.log('Private key saved to the requested path. Keep it outside the project.');
} else if (command === 'sign' && keyFile && inputFile && outputFile) {
  const privateKey = createPrivateKey(readFileSync(keyFile));
  if(privateKey.asymmetricKeyType !== 'ed25519') throw Error('Ed25519 key required');
  const config = JSON.parse(readFileSync(inputFile,'utf8').replace(/^\uFEFF/,''));
  if(config.schema!==1 || !Number.isSafeInteger(config.version) || config.version<1 || !Array.isArray(config.origins) || !config.origins.length || config.origins.length>4) throw Error('Invalid manifest');
  for(const value of config.origins) {
    const u=new URL(value);if(u.protocol!=='https:' || u.username || u.password || u.port || u.search || u.hash || u.pathname!=='/')throw Error('HTTPS origins only');
  }
  const now=Date.now(), expires=Date.parse(config.expires_at), issued=Date.parse(config.issued_at);
  if(!Number.isFinite(expires)||!Number.isFinite(issued)||expires<=now||issued>now+300000||expires<=issued||expires-issued>180*86400000)throw Error('Invalid lifetime');
  const payload=Buffer.from(JSON.stringify(config));
  writeFileSync(outputFile,JSON.stringify({payload:payload.toString('base64'),signature:sign(null,payload,privateKey).toString('base64')},null,2),{flag:'wx'});
  console.log('Signed config written. Upload identical bytes to all independent configuration mirrors.');
} else {
  console.error('Usage: node sign-connection-config.mjs keygen PRIVATE.pem\n       node sign-connection-config.mjs sign PRIVATE.pem INPUT.json OUTPUT.json');
  process.exitCode=1;
}
