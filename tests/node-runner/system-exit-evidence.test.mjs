import assert from 'node:assert/strict';
import {makeLoader} from './helpers/ets-loader.mjs';

const files=new Map(); let watcher, removed, writes=0, denied=false;
const ctx={filesDir:'/fixture'};
const load=makeLoader({
  '@kit.AbilityKit':{},
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}},hiAppEvent:{domain:{OS:'OS'},
    event:{APP_CRASH:'APP_CRASH',APP_FREEZE:'APP_FREEZE',APP_KILLED:'APP_KILLED'},
    addWatcher(w){watcher=w;},removeWatcher(w){removed=w;}}},
  'services/StatusStore.ets':{StatusStore:{readText:(_c,n)=>files.get(n)||'',
    writeText(_c,n,v){if(denied)throw Error('denied');writes++;files.set(n,v);}}}
});
const {SystemExitEvidence:E,SYSTEM_EXIT_FILE:F}=load('services/SystemExitEvidence.ets');
E.start(ctx); const original=watcher; E.start(ctx); assert.equal(watcher,original);
assert.deepEqual(Array.from(watcher.appEventFilters[0].names),['APP_CRASH','APP_FREEZE','APP_KILLED']);
const emit=(name,params,domain='OS')=>watcher.onReceive(domain,[{appEventInfos:[{name,params}]}]);
const past=1_700_000_000_000;
emit('APP_CRASH',{time:past,pid:49493,process_name:'com.oscarwoltz.tongdao:vpn',
  bundle_version:'0.5.36',reason:'SIGSEGV',foreground:false,
  exception:{name:'SIGSEGV',message:'password=credential-sentinel'},
  token:'credential-sentinel',hilog:['private request body'],
  external_log:['/data/storage/el2/log/hiappevent/APP_CRASH_1700000000000_49493.log',
    '/other/APP_CRASH_1.log','/data/storage/el2/log/hiappevent/APP_CRASH_../secret.log']});
let rows=E.read(ctx); assert.equal(rows.length,1); assert.equal(rows[0].time,past);
assert(rows[0].receivedAt>past); assert.equal(rows[0].pid,49493);
assert.deepEqual(Array.from(rows[0].logFiles),['APP_CRASH_1700000000000_49493.log']);
assert.equal(rows[0].generation,undefined,'historical exit must not acquire current session identity');
assert(!files.get(F).includes('credential-sentinel'));assert(!files.get(F).includes('private request body'));
const before=writes; emit('APP_CRASH',{time:past,pid:49493,process_name:'com.oscarwoltz.tongdao:vpn',reason:'SIGSEGV'});
assert.equal(writes,before,'redelivery does not duplicate an exit');
emit('APP_KILLED',{time:past+1,reason:'LowMemoryKill'},'OTHER');
emit('UNRELATED',{time:past+1}); emit('APP_CRASH',{time:past+1,process_name:'other.bundle'});
assert.equal(E.read(ctx).length,1);
for(let i=1;i<40;i++)emit('APP_KILLED',{time:past+i,reason:'LowMemoryKill'});
rows=E.read(ctx);assert.equal(rows.length,32);assert.equal(rows[0].time,past+8);
const disk=JSON.parse(files.get(F));disk[0].password='credential-sentinel';files.set(F,JSON.stringify(disk));
assert(!JSON.stringify(E.read(ctx)).includes('credential-sentinel'),'export refilters persisted data');
denied=true;assert.doesNotThrow(()=>emit('APP_FREEZE',{time:past+100}));
files.set(F,'corrupt');assert.equal(E.read(ctx).length,0);
E.stop();assert.equal(removed,original);E.stop();
console.log('PASS system exit evidence: OS-only, historical identity, redaction, safe log references, deduplication, bounded retention, failure isolation');
