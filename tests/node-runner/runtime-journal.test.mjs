import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source=readFileSync(new URL('../../entry/src/main/ets/services/RuntimeJournal.ets',import.meta.url),'utf8');
let now=1_800_000_000_000, fail=false, nextFd=10;
let files=new Map(), handles=new Map();
const name=p=>p.split('/').at(-1);
const fs={
  OpenMode:{WRITE_ONLY:1,CREATE:2,APPEND:4},
  accessSync(p){return files.has(name(p));},
  readTextSync(p){if(fail)throw Error('denied'); const v=files.get(name(p));if(v===undefined)throw Error('missing');return v;},
  statSync(p){const v=files.get(name(p));if(v===undefined)throw Error('missing');return {size:v.length};},
  openSync(p,mode){if(fail)throw Error('denied');const n=name(p);if(!(mode&4))files.set(n,'');const fd=nextFd++;handles.set(fd,n);return {fd};},
  writeSync(fd,text){if(fail)throw Error('denied');const n=handles.get(fd);files.set(n,(files.get(n)||'')+String(text));},
  fsyncSync(fd){if(fail)throw Error('denied');},
  closeSync(fd){handles.delete(fd);},
  unlinkSync(p){files.delete(name(p));},
  renameSync(a,b){const from=name(a),to=name(b);if(!files.has(from))throw Error('missing');files.set(to,files.get(from));files.delete(from);}
};
const module={exports:{}};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
 {module,exports:module.exports,Date:{now:()=>now},JSON,Array,Object,Math,isFinite,console:{error(){},warn(){}} ,require(n){if(n==='@kit.CoreFileKit')return {fileIo:fs};if(n==='@kit.AbilityKit')return {common:{}};throw Error(n);}});
const J=module.exports.RuntimeJournal, ctx={filesDir:'/fixture'};
const status=(generation='g1',phase='STARTING')=>({generation,phase,sessionRevision:3,vpnCreated:true,tunRxBytes:7,
 payloadDigest:'a'.repeat(64),lastError:'secret error https://private.example',nodeName:'do-not-log',tunFd:88});
const native=(badHev=false,routeFailures=1)=>({xrayRunning:true,tunRunning:true,poisoned:false,
 protectQueued:7,protectAcked:6,protectTimeout:1,protectVisible:5,protectMeasured:4,protectTcp4:2,protectTcp6:1,protectUdp:3,protectTotalUs:12,protectMaxUs:8,
 appRouting:{enabled:true,active:true,configuredRules:2,pending:3,defaulted:4,rejected:routeFailures,ownerQueryFailed:5,identityMismatch:6,overloaded:7,inactive:8,ackFailed:9,tcpQueries:10,udpQueries:11},
 protectDiagnostics:{requests:4,lastErrorCode:-13},hevDiagnostics:badHev?'not JSON':JSON.stringify({rxCalls:9,rxErrors:2,controlErrors:3,pollErrors:4,tunFd:99,tunCounts:[0,1,2,3,4,5,6,7,8,9,10,11,12],error:'password=private'}),
 error:'password=private',host:'private.example'});
function reset(){files=new Map();handles=new Map();fail=false;now=1_800_000_000_000;}

reset();J.sample(ctx,status(),native());assert.equal(J.read(ctx).count,1);
J.sample(ctx,status(),native());assert.equal(J.read(ctx).count,1,'identical samples throttle for 30 seconds');
J.sample(ctx,status('g1','CORE_RUNNING'),native());assert.equal(J.read(ctx).count,2,'phase changes are immediate');
J.sample(ctx,status('g2','CORE_RUNNING'),native());assert.equal(J.read(ctx).count,3,'new generations retain old history');

const raw=[...files.values()].join('');
assert(!/private\.example|password=private|secret error|nodeName|"tunFd"|"lastError"/i.test(raw),raw);
assert(raw.includes('n.appRouting.ownerQueryFailed')&&raw.includes('n.protectTimeout')&&raw.includes('n.hev.rxCalls')&&raw.includes('n.tunCounts'));
const snap=J.snapshot(status(),native());assert.equal(snap.at,undefined);assert.equal(snap['n.tunFd'],undefined);assert.equal(snap['n.appRouting.configuredRules'],2);
assert.equal(snap['n.appRouting.ackFailed'],9);assert.equal(snap['n.protectTcp6'],1);assert.equal(snap['n.hev.rxErrors'],2);
assert.equal(J.snapshot(status(),native(true))['n.xrayRunning'],true,'bad HEV does not hide independent native fields');assert.equal(J.snapshot(status(),native(true))['n.hev.rxCalls'],undefined);assert.equal(J.snapshot(status(),native(true))['n.hevDiagnosticsMissing'],true);
J.event(ctx,'net',status(),native(),{net:'changed',reason:'reconnect',netChanged:true,message:'secret'});
assert.equal(J.read(ctx).count,4);assert(![...files.values()].join('').includes('message'));
assert.equal(J.read(ctx).records.at(-1)['x.net'],'changed');assert.equal(J.read(ctx).records.at(-1)['x.reason'],'reconnect');
J.event(ctx,'tick',status(),native(),{outcome:'ok'});assert.equal(J.read(ctx).count,4);
// Bytes change normally, but do not defeat 30s sample throttling; failure counts do.
now+=1_000;const flowing=status('g2','CORE_RUNNING');flowing.tunRxBytes=999999;J.sample(ctx,flowing,native());assert.equal(J.read(ctx).count,4);
J.sample(ctx,flowing,native(false,2));assert.equal(J.read(ctx).count,5);

// Oversized rotations use fixed names and never exceed four one-MiB segments.
reset();const huge={generation:'g',phase:'STARTING',sessionRevision:1,tunRxBytes:1};
for(let i=0;i<4000;i++){now+=31_000;huge.tunRxBytes=i;J.sample(ctx,huge,native());}
assert(files.size<=4);assert([...files.values()].reduce((n,v)=>n+v.length,0)<=4*1024*1024);
assert(files.has('runtime-journal.1.jsonl'),'at least one real rotation archives the active segment');

// A bad or partial line is counted but good records after it remain readable.
reset();J.sample(ctx,status(),native());files.set('runtime-journal.jsonl','{"at":bad}\n'+files.get('runtime-journal.jsonl')+'{"at":');
let read=J.read(ctx);assert.equal(read.count,1);assert.equal(read.corruptLines,2);
files.set('runtime-journal.1.jsonl',JSON.stringify({at:now,phase:'STARTING',unknownSecret:'private.example'})+'\n');read=J.read(ctx);assert.equal(read.records[0].unknownSecret,undefined,'disk records are re-filtered before reporting');
now+=49*60*60*1000;read=J.read(ctx);assert.equal(read.count,0,'read never pretends expired data is retained');assert.equal(read.expiredLines,2);assert.equal(read.retentionHours,48);assert.equal(read.capacityBytes,4*1024*1024);

// Writes and reads are both fail-closed and never throw into the VPN path.
reset();fail=true;assert.doesNotThrow(()=>J.sample(ctx,status(),native()));assert.doesNotThrow(()=>J.event(ctx,'net',status(),native(),{netChanged:true}));
read=J.read(ctx);assert.equal(read.missing,true);assert.equal(read.writeFailedCurrentProcess,true);assert.equal(read.writeFailureVisibility,'current-process-only');assert.equal(read.writeFailureCoverage,'prior-process-failures-unknown');assert.equal(read.readFailed,undefined);
console.log('PASS runtime journal: actual transpiled service throttles, preserves generations, bounds storage/retention, filters secrets, recovers after corrupt lines, and fails closed');
