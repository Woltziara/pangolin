import assert from 'node:assert/strict';
import {makeLoader} from './helpers/ets-loader.mjs';
const writes=[],observers={},configured=[],files={};
const load=makeLoader({
 '@kit.AbilityKit':{common:{},errorManager:{on(kind,observer){observers[kind]=observer;return 1;}}},
 '@kit.CoreFileKit':{fileIo:{accessSync:p=>p in files,statSync:p=>({size:files[p].length}),readTextSync:p=>files[p]}},
 '@kit.PerformanceAnalysisKit':{hilog:Object.fromEntries(['info','debug','warn','error','fatal'].map(k=>[k,()=>{}]))},
 'native/TunnelNative.ets':{configureErrorLog:p=>configured.push(p),recordErrorLog:(...args)=>writes.push(args)}
},{},{realLogging:true});
const {ErrorJournal:E}=load('services/ErrorJournal.ets');
E.start({filesDir:'/sandbox'},'vpn');E.start({filesDir:'/sandbox'},'vpn');
assert.equal(configured.length,2);
observers.error.onException(new Error('caught failure'));
observers.error.onUnhandledException('uncaught failure');
observers.unhandledRejection('rejected promise',Promise.resolve());
assert.equal(writes[0][2],'caught failure');assert.match(writes[0][3],/Error: caught failure/);
assert.equal(writes[1][0],'fatal');assert.equal(writes[2][2],'rejected promise');
const {AppLog}=load('services/AppLog.ets');
AppLog.error(1,'native','failure %{public}s secret %{private}s count %{public}d','IO','DO_NOT_STORE',7);
assert.equal(writes.at(-1)[2],'failure IO secret [private] count 7');
files['/sandbox/error-journal.1.jsonl']=JSON.stringify({schema:1,at:1,message:'old'})+'\nmalformed\n';
files['/sandbox/error-journal.jsonl']=Array.from({length:501},(_,i)=>JSON.stringify({schema:1,at:i+2,message:'new'})).join('\n');
const report=E.read({filesDir:'/sandbox'});
assert.equal(report.count,500);assert.equal(report.totalRecords,502);assert.equal(report.omittedFromReport,2);assert.equal(report.corruptLines,1);assert.equal(report.records[0].at,3);
const failing=makeLoader({'@kit.CoreFileKit':{fileIo:{}},'@kit.AbilityKit':{errorManager:{on(){throw Error('no observer');}}},'native/TunnelNative.ets':{configureErrorLog(){},recordErrorLog(){throw Error('disk full');}}},{},{realLogging:true})('services/ErrorJournal.ets').ErrorJournal;
assert.doesNotThrow(()=>failing.start({filesDir:'/sandbox'},'ui'));assert.doesNotThrow(()=>failing.error('ui',new Error('original')));
console.log('PASS actual error journal: exceptions, promise rejection, private placeholders, report limits, and storage failure isolation');
