import assert from 'node:assert/strict';
import {makeLoader,Clock,deferred,flush} from './helpers/ets-loader.mjs';
let passed=0;
const c=new Clock(), files=new Map(), calls=[], requests=[];let owner,keepStops=0;
const sockets=[];let nonce=0;
const mocks={
  '@kit.AbilityKit':{},'@kit.ArkTS':{util:{generateRandomUUID:()=>`probe-${++nonce}`}},
  '@kit.NetworkKit':{http:{RequestMethod:{GET:0},HttpDataType:{STRING:0},createHttp(){
    const d=deferred();const r={d,destroyed:0,request(){calls.push('http');requests.push(r);return d.promise;},destroy(){this.destroyed++;}};return r;}},
    socket:{constructUDPSocketInstance(){const s={closed:0,bind(){return Promise.resolve();},close(){this.closed++;},on(){},send(){return Promise.resolve();}};sockets.push(s);return s;}}},
  '@ohos.process':{default:{pid:1,uid:2}},
  'vpn/VpnConstants.ets':{BUNDLE_NAME:'fixture'},
  '@kit.BackgroundTasksKit':{backgroundTaskManager:{stopBackgroundRunning:async()=>{keepStops++;},startBackgroundRunning(){throw Error('No continuous task may be created');}}},
  'services/StatusStore.ets':{StatusStore:{readStatus:()=>({...owner,at:c.now}),readText:(_c,k)=>files.get(k)||'',writeText(_c,k,v){files.set(k,v);}}}
};
const load=makeLoader(mocks,c.globals());const status=load('net/DataplaneStatus.ets');
const probe=load('services/ProbeSelfCheck.ets').PROBE_SELF_CHECK;
const host=load('services/BackgroundProbeHost.ets').BACKGROUND_PROBE_HOST;
owner={...new status.DataplaneStatus(),generation:'g1',sessionRevision:1,phase:'UNPROVEN',desiredRunning:true,probePending:true,at:c.now,
  vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,
  evidenceRid:'rid1',probeIssuedAt:c.now-1,probeGoogleUrl:'http://fixture.invalid/a',probeDirectUrl:'https://fixture.invalid/b'};
host.start({},'Index.startTunnel');host.stop({},'cancel');await flush();
assert.equal(probe.loopId,-1);assert(requests.every(r=>r.destroyed>0));assert(!files.has('probe-fetch.json'));requests.length=0;passed++;
// Start the REAL loop and HTTP code. Replace DNS only to isolate HTTP timeout/cancel.
probe.probeDnsOk=async()=>true;host.start({},'Index.startTunnel');await flush();
assert.equal(requests.length,3);const old=requests.slice();host.stop({},'cancel');await flush();
assert(old.every(r=>r.destroyed>0));old.forEach(r=>r.d.resolve({responseCode:204}));await flush();assert(!files.has('probe-fetch.json'));passed++;
// New generation succeeds first; previous callbacks arrive after it.
owner={...owner,generation:'g2',evidenceRid:'rid2',probeIssuedAt:c.now};
host.start({},'Index.startTunnel');await flush();
const fresh=requests.slice(-3);fresh[0].d.resolve({responseCode:204});fresh[1].d.resolve({responseCode:204});fresh[2].d.resolve({responseCode:200});await flush();
assert.equal(JSON.parse(files.get('probe-fetch.json')).generation,'g2');const saved=files.get('probe-fetch.json');
old.forEach(r=>r.d.resolve({responseCode:500}));await flush();assert.equal(files.get('probe-fetch.json'),saved);assert.equal(probe.failCount,0);passed++;
// Healthy cadence is 30 seconds, not every timer tick.
await c.advance(28000);assert.equal(requests.length,6);await c.advance(4000);assert.equal(requests.length,9);passed++;
// Cancel previous in-flight work by changing generation (without stopping host).
const superseded=requests.slice(-3);owner={...owner,generation:'g3',evidenceRid:'rid3',probeIssuedAt:c.now};await c.advance(2000);
assert(superseded.every(r=>r.destroyed>0));const current=requests.slice(-3);current[0].d.resolve({responseCode:204});current[1].d.resolve({responseCode:204});current[2].d.resolve({responseCode:200});await flush();
superseded.forEach(r=>r.d.resolve({responseCode:0}));await flush();assert.equal(JSON.parse(files.get('probe-fetch.json')).generation,'g3');assert.equal(probe.nextRetryAt,0);passed++;
// Stop must settle even if the SDK destroy implementation throws.
await c.advance(30000);const thrown=requests.slice(-3);thrown.forEach(r=>r.destroy=()=>{throw Error('SDK cleanup');});
host.stop({},'cancel');await flush();assert.equal(probe.inflightWork,null);assert.equal(probe.loopId,-1);passed++;
// Real UDP bind never settling is bounded and canceled, with no receipt write.
const bind=deferred();mocks['@kit.NetworkKit'].socket.constructUDPSocketInstance=()=>({bind:()=>bind.promise,close(){calls.push('udp-close');},on(){},send(){return Promise.resolve();}});
const p2=makeLoader(mocks,c.globals())('services/ProbeSelfCheck.ets').PROBE_SELF_CHECK;
p2.startLoop({});await flush();p2.stopLoop();await flush();bind.resolve();await flush();
assert(calls.includes('udp-close'));assert.equal(p2.inflightWork,null);passed++;
console.log(`PASS ${passed} production probe lifecycle scenarios (real Host, loop, HTTP cancel, generation fences, cadence, throwing cleanup, stalled bind)`);
