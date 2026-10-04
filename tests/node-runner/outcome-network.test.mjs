import assert from 'node:assert/strict';
import {makeLoader,Clock,deferred,flush} from './helpers/ets-loader.mjs';
import {vpnFixture} from './helpers/vpn-fixture.mjs';
const clock=new Clock(),files=new Map(),requests=[];let owner,serial=0;
const mocks={'@kit.AbilityKit':{},'@kit.ArkTS':{util:{generateRandomUUID:()=>`sample-${++serial}`}},'@ohos.process':{default:{pid:1,uid:2}},
 '@kit.NetworkKit':{http:{RequestMethod:{GET:0,HEAD:1},HttpDataType:{STRING:0},createHttp(){const d=deferred(),r={url:'',method:null,closed:0,d,request(url,options){r.url=url;r.method=options.method;requests.push(r);return d.promise;},destroy(){r.closed++;}};return r;}},socket:{}},
 'vpn/VpnConstants.ets':{BUNDLE_NAME:'fixture'},'services/StatusStore.ets':{StatusStore:{readStatus:()=>({...owner,at:clock.now}),readText:(_c,k)=>files.get(k)||'',writeText:(_c,k,v)=>files.set(k,v)}}};
const load=makeLoader(mocks,clock.globals()),D=load('net/DataplaneStatus.ets').DataplaneStatus;
const H=load('net/ConnectionHealth.ets'),P=load('net/ProbeResult.ets');
owner={...new D(),generation:'S',ownerInstance:'O',sessionRevision:1,networkEpoch:1,networkState:'available',payloadDigest:'policy',phase:'FORWARDER_RUNNING',desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,at:clock.now};
const probe=load('services/ProbeSelfCheck.ets').PROBE_SELF_CHECK;probe.probeDnsOk=async()=>true;
const settle=rs=>{rs.forEach((r,i)=>r.d.resolve({responseCode:i===2?200:204}));};
probe.startLoop({});await flush();const first=requests.slice();settle(first);await flush();
assert.equal(first.find(r=>r.url.includes('baidu.com/robots.txt')).method,0,'domestic check uses a small GET resource');
let raw=files.get('probe-fetch.json');assert(P.currentReceipt(JSON.parse(raw),owner,clock.now));
let state={...owner,at:clock.now};H.updateConnectionHealth(state,raw,'fixture',clock.now);assert.equal(state.connectionHealth,'reachable');
assert.equal(P.probeHomeSummary(raw,owner,clock.now),'国内可用 · 海外可用 · ChatGPT 需在实际应用中验证');
assert.equal(P.probeHomeSummary(raw,{...owner,phase:'STOP_UNCONFIRMED'},clock.now),'',
  'old green must disappear when recovery is required');
assert.equal(P.probeHomeSummary(raw,{...owner,phase:'ERROR',vpnCreated:false},clock.now),'',
  'old green must disappear after a failed connection');
const observedProbe=JSON.parse(raw);assert.equal(observedProbe.chatgptHttp,undefined,'automatic checks must not fetch ChatGPT');assert.equal(P.probeIssue(raw,owner,clock.now),'');
const old403=JSON.stringify({...observedProbe,chatgptHttp:403});
assert.equal(P.probeIssue(old403,owner,clock.now),'','an old synthetic 403 cannot classify real ChatGPT use');
assert.match(P.probeHomeSummary(old403,owner,clock.now),/ChatGPT 需在实际应用中验证/);
const confirmed={...owner,at:clock.now};H.updateConnectionHealth(confirmed,old403,'fixture',clock.now);
assert.equal(confirmed.connectionHealth,'reachable','network checks may pass without claiming ChatGPT application success');
assert.equal(P.probeIssue(JSON.stringify({...observedProbe,directHttp:0}),owner,clock.now),'domestic');
owner.networkEpoch++;owner.networkState='unavailable';state={...state,...owner,at:clock.now};H.updateConnectionHealth(state,raw,'fixture',clock.now);assert.equal(state.connectionHealth,'network-unavailable');assert(!P.currentReceipt(JSON.parse(raw),owner,clock.now));
owner.networkState='available';const pending=probe.tick({});await flush();const second=requests.slice(-3);
owner.networkEpoch++;const newer=probe.tick({});await flush();assert(second.every(r=>r.closed>0));
const third=requests.slice(-3);settle(third);await newer;const saved=files.get('probe-fetch.json');settle(second);await pending;await flush();assert.equal(files.get('probe-fetch.json'),saved);
assert(!requests.some(r=>r.url.includes('chatgpt.com')),'background check must not generate bot-like ChatGPT traffic');
// Manual joins the actual flight, not a cached success.
const manual=probe.checkNow({});await flush();const batch=requests.slice(-3);const joined=probe.checkNow({});await flush();assert.deepEqual(requests.slice(-3),batch);
settle(batch);assert.match(await manual,/HTTPS/);assert.match(await joined,/HTTPS/);
probe.stopLoop();owner.routeMode='direct';const oldCount=requests.length;probe.startLoop({});await flush();assert.equal(requests.length,oldCount+1);assert(requests.at(-1).url.includes('baidu.com/robots.txt'));requests.at(-1).d.resolve({responseCode:200});await flush();probe.stopLoop();
// Network watcher: ignore stale loss, coalesce topology changes, maintain a bounded auto-recovery budget.
const f=vpnFixture();f.v.onCreate(f.want('network'));await flush(250);f.v.startInFlight=false;
const seen=[];f.v.requestRecover=r=>seen.push(r);f.v.onNetEvent('available',{netId:1});f.v.onNetEvent('available',{netId:2});const epoch=f.v.status.networkEpoch;
f.v.onNetEvent('lost',{netId:1});assert.equal(f.v.status.networkEpoch,epoch);f.v.onNetEvent('available',{netId:2});assert.equal(f.v.status.networkEpoch,epoch);
await f.clock.advance(800);assert.equal(seen.length,1);
console.log('PASS production network epochs, late receipt exclusion, manual coalescing, no synthetic ChatGPT claim, direct-mode scope, network debounce');
