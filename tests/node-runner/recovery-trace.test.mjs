import assert from 'node:assert/strict';
import {makeLoader,Clock} from './helpers/ets-loader.mjs';
const clock=new Clock(),files=new Map();let generation='old',failWrite=false,health='reachable',age=0,epoch=1;
const mocks={
 '@kit.AbilityKit':{},
 'services/BuildIdentity.ets':{BuildIdentity:{source:()=> 'source'}},
 'net/DataplaneStatus.ets':{serializeStatus:s=>JSON.stringify(s)},
 'services/RuntimeJournal.ets':{RuntimeJournal:{snapshot:s=>({generation:s.generation}),read:()=>({before:true})}},
 'services/DiagnosticReport.ets':{DiagnosticReport:{write(_c,d){if(failWrite)throw Error('disk');files.set('incident-report-1.json',JSON.stringify(d));return '/files/incident-report-1.json';}}},
 'services/StatusStore.ets':{StatusStore:{readText:()=> '{}',readStrictText:(_c,n)=>files.get(n)||'',listNames:()=>Array.from(files.keys()),writeText(_c,n,t){files.set(n,t);},readStatus:()=>({generation,networkEpoch:epoch,phase:'FORWARDER_RUNNING',connectionHealth:health,networkState:'available',desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,cleanupPending:false,nativePoisoned:false,at:clock.now-age})}}
};
const trace=makeLoader(mocks,clock.globals())('services/RecoveryTrace.ets').RecoveryTrace;
const name=trace.begin({},'restore-current-route');assert.equal(typeof name,'string','capture is synchronous so cancel cannot be overtaken before controller owns the repair');generation='new';trace.finish({},name);
const doc=JSON.parse(files.get(name));assert.equal(doc.status.generation,'old');assert.equal(doc.runtimeJournal.before,true);
assert.equal(doc.recoveryAttempt.afterGeneration,'new');assert.equal(doc.recoveryAttempt.state,'network-ready');assert.equal(doc.recoveryAttempt.businessOutcome,'not-observed');
assert.equal(trace.reportBusiness({},name,true),true);assert.equal(JSON.parse(files.get(name)).recoveryAttempt.businessOutcome,'user-reported-success');
epoch++;assert.equal(trace.reportBusiness({},name,false),false,'new network result cannot be attributed to the old recovery');
failWrite=true;assert.equal(trace.begin({},'restore-current-route'),'','disk failure must not block recovery');failWrite=false;
age=26000;trace.begin({},'rebuild-current-route');trace.finish({},name);assert.equal(JSON.parse(files.get(name)).recoveryAttempt.state,'unverified');
age=0;health='check-failed';trace.begin({},'rebuild-current-route');trace.finish({},name);assert.equal(JSON.parse(files.get(name)).recoveryAttempt.state,'failed');
assert.equal(trace.currentRouteAlreadyFailed({}),true);
epoch++;assert.equal(trace.currentRouteAlreadyFailed({}),false,'new network epoch must not inherit a previous failure');
console.log('PASS pre-recovery evidence survives new connection, stale/failed status remains non-success, network success never becomes business success, recording failure is nonblocking');
