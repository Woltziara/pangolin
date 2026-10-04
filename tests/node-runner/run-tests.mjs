import {readdirSync,mkdirSync,writeFileSync,openSync,closeSync,readFileSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=dirname(fileURLToPath(import.meta.url));
const out=resolve(root,process.argv[2]||'../../.runtime/host-tests/node');mkdirSync(out,{recursive:true});
const results=[];
for(const file of readdirSync(root).filter(n=>n.endsWith('.test.mjs')).sort()){
 const start=Date.now(),log=resolve(out,file+'.log'),fd=openSync(log,'w');
 const p=spawnSync(process.execPath,[file],{cwd:root,stdio:['ignore',fd,fd],timeout:60000});closeSync(fd);
 const text=readFileSync(log,'utf8')+(p.error?'\n'+String(p.error)+'\n':'');
 if(p.error)writeFileSync(log,text);
 const r={file,command:[process.execPath,file],exitCode:p.status,signal:p.signal,error:p.error?.code||null,seconds:(Date.now()-start)/1000,status:p.status===0&&!p.error?'PASS':'FAIL'};
 results.push(r);writeFileSync(resolve(out,'partial-results.json'),JSON.stringify(results,null,2)+'\n');console.log(`${r.status} ${file} exit=${p.status} ${r.seconds}s`);
 if(r.status!=='PASS')console.log(text.slice(-3000));
}
writeFileSync(resolve(out,'results.json'),JSON.stringify({kind:'host-production-replay-not-HarmonyOS',results,passed:results.filter(r=>r.status==='PASS').length,total:results.length},null,2)+'\n');
if(results.some(r=>r.status!=='PASS'))process.exitCode=1;
