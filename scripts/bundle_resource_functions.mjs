import fs from 'node:fs';
const root=new URL('../',import.meta.url);
const read=p=>fs.readFileSync(new URL(p,root),'utf8');
const verify=read('supabase/functions/public-resources/verify_stream.ts');
const handler=read('supabase/functions/public-resources/handler.ts');
const index=read('supabase/functions/public-resources/index.ts').replace(/^import .*from '\.\/.*';\r?\n/gm,'');
const bundled=[verify,handler,index].join('\n');
for(const path of ['supabase/functions/public-resources/dashboard-index.ts','docs/deployment/public-resources-dashboard.ts']){
  fs.writeFileSync(new URL(path,root),bundled);
}
fs.writeFileSync(new URL('docs/deployment/resource-web-dashboard.ts',root),read('supabase/functions/resource-web/index.ts'));
