import {legacyBoundary} from './helpers/legacy-boundaries.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

function load(path, deps = {}, extra = {}) {
  const source = readFileSync(new URL('../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(compiled, { module, exports: module.exports, Date, setTimeout, clearTimeout, setInterval, clearInterval,
    require(name) { if (!(name in deps)) {const b=legacyBoundary(name);if(b!==undefined)return b;throw Error('Unexpected import: '+name);} return deps[name]; }, ...extra });
  return module.exports;
}
const statusModule = load('net/DataplaneStatus.ets');
const { updateConnectionHealth, isConnectionEstablished } = load('net/ConnectionHealth.ets');
const { connectionCopy } = load('core/UserFacingCopy.ets');
const now = 100000;
function liveStatus() {
  const s = new statusModule.DataplaneStatus();
  Object.assign(s, { phase: 'DEGRADED_UNPROVEN', desiredRunning: true, vpnCreated: true,
    tunFdValid: true, xrayRunning: true, forwarderOk: true, at: now, generation: 'g1',
    sessionRevision: 1, evidenceRid: 'rid-1', probeIssuedAt: now - 1000, probePending: true });
  return s;
}
function receipt(overrides = {}) {
  return JSON.stringify({ generation: 'g1', revision: 1, rid: 'rid-1', at: now - 10,
    bundle: 'test.bundle', source: 'entry-background', googleHttp: 204, directHttp: 200,
    dnsOk: true, ackOk: true, ...overrides });
}
let count = 0;
function test(name, run) { run(); count++; console.log('ok - ' + name); }

test('primary connection lifecycle is independent of all background check outcomes', () => {
  for (const health of ['checking', 'check-failed', 'unverified', 'reachable']) {
    const s = liveStatus(); s.connectionHealth = health;
    const ready = isConnectionEstablished(s, now);
    assert.equal(ready, true);
    const copy = connectionCopy(s.phase, false, true, health, ready);
    if (health === 'reachable') assert.equal(copy.title, '网络正常');
    else assert.notEqual(copy.title, '网络正常');
    assert.equal(copy.warning, health === 'check-failed');
  }
  for (const changed of [{xrayRunning:false},{forwarderOk:false},{tunFdValid:false},
    {desiredRunning:false},{nativePoisoned:true},{at:now-25001},{at:now+1},
    {phase:'STOPPED'},{phase:'ERROR'},{phase:'RECONNECTING'}]) {
    const s=liveStatus();Object.assign(s,changed);assert.equal(isConnectionEstablished(s,now),false);
  }
});

test('actual app response proves reachability without promoting routing audit', () => {
  const s = liveStatus(); updateConnectionHealth(s, receipt(), 'test.bundle', now);
  assert.equal(s.connectionHealth, 'reachable'); assert.equal(s.lastReachableAt, now - 10);
  assert.equal(s.phase, 'DEGRADED_UNPROVEN'); assert.equal(s.canaryOk, false);
  assert.equal(connectionCopy(s.phase, false, true, s.connectionHealth).title, '网络正常');
});
test('new probe and reset routing evidence do not erase a recent successful check', () => {
  const s = liveStatus(); updateConnectionHealth(s, receipt(), 'test.bundle', now);
  s.evidenceRid = 'rid-2'; s.evidenceAt = 0; s.probeIssuedAt = now; s.at = now + 2000;
  updateConnectionHealth(s, receipt(), 'test.bundle', now + 2000);
  assert.equal(s.connectionHealth, 'reachable'); assert.equal(s.lastReachableAt, now - 10);
});
test('remembered success expires rather than claiming online indefinitely', () => {
  const s = liveStatus(); updateConnectionHealth(s, receipt(), 'test.bundle', now);
  s.at = now + 76000;
  updateConnectionHealth(s, '', 'test.bundle', now + 76000);
  assert.equal(s.connectionHealth, 'unverified');
  assert.notEqual(connectionCopy('CANARY_OK', false, true, s.connectionHealth).title, '网络正常');
});
test('cached success cannot cross a generation or revision boundary', () => {
  for (const change of [{ generation: 'g2' }, { sessionRevision: 2 }]) {
    const s = liveStatus(); updateConnectionHealth(s, receipt(), 'test.bundle', now);
    Object.assign(s, change);
    updateConnectionHealth(s, receipt(), 'test.bundle', now);
    assert.notEqual(s.connectionHealth, 'reachable'); assert.equal(s.lastReachableAt, 0);
  }
});
test('missing initial check becomes unknown after 30s, not an endless spinner or disconnect', () => {
  const s = liveStatus(); updateConnectionHealth(s, '', 'test.bundle', now);
  assert.equal(s.connectionHealth, 'checking');
  s.at = now + 31000; updateConnectionHealth(s, '', 'test.bundle', now + 31000);
  assert.equal(s.connectionHealth, 'unverified');
  const title = connectionCopy(s.phase, false, true, s.connectionHealth).title;
  assert(!/正在|不可用|中断/.test(title));
});
test('old generation revision RID bundle source stale and future receipts never pass', () => {
  for (const bad of [{ generation: 'old' }, { revision: 0 }, { rid: 'old' }, { bundle: 'other' },
    { source: 'native-socks' }, { at: now - 2000 }, { at: now + 1 }]) {
    const s = liveStatus(); updateConnectionHealth(s, receipt(bad), 'test.bundle', now);
    assert.notEqual(s.connectionHealth, 'reachable'); assert.equal(s.lastReachableAt, 0);
  }
});
test('partial failure is a failed check, not invented proof that all traffic stopped', () => {
  const s = liveStatus(); updateConnectionHealth(s, receipt(), 'test.bundle', now);
  updateConnectionHealth(s, receipt({ at: now, googleHttp: 0, dnsOk: false }), 'test.bundle', now);
  assert.equal(s.connectionHealth, 'check-failed');
  assert.equal(connectionCopy(s.phase, false, true, s.connectionHealth).title, '点一下修复连接');
  s.evidenceRid = 'retry-rid'; s.at = now + 2000;
  updateConnectionHealth(s, '', 'test.bundle', now + 2000);
  assert.equal(s.connectionHealth, 'check-failed', 'rolling RID must not conceal the last failure');
});
test('a real runtime failure overrides fresh successful HTTP receipts', () => {
  const s = liveStatus(); s.xrayRunning = false;
  updateConnectionHealth(s, receipt(), 'test.bundle', now);
  assert.equal(s.connectionHealth, 'offline');
  assert.equal(connectionCopy(s.phase, false, true, s.connectionHealth).title, '连接已中断');
});
test('stopped and poisoned runtime never reuse a successful reachability label', () => {
  for (const phase of ['STOPPED', 'ERROR', 'POISONED', 'RECONNECTING']) {
    const s = liveStatus(); s.phase = phase; updateConnectionHealth(s, receipt(), 'test.bundle', now);
    assert.notEqual(connectionCopy(s.phase, false, true, s.connectionHealth).title, '网络正常');
  }
});
test('stale native heartbeat cannot be replaced by a fresh HTTP receipt', () => {
  const s = liveStatus(); s.at = now - 25001;
  updateConnectionHealth(s, receipt(), 'test.bundle', now);
  assert.equal(s.connectionHealth, 'unverified');
});
test('new status fields survive serialization without rewriting legacy evidence', () => {
  const s = liveStatus(); updateConnectionHealth(s, receipt(), 'test.bundle', now);
  const parsed = statusModule.parseStatus(statusModule.serializeStatus(s));
  assert.equal(parsed.connectionHealth, 'reachable'); assert.equal(parsed.healthCheckedAt, now - 10);
  assert.equal(parsed.phase, 'DEGRADED_UNPROVEN'); assert.equal(parsed.canaryOk, false);
});

let clock = now;
const controllerState = liveStatus(); controllerState.connectionHealth = 'checking';
const controllerModule = load('services/ConnectionController.ets', {
  '@kit.NetworkKit': {}, '@kit.AbilityKit': {}, '@kit.PerformanceAnalysisKit': {hilog:{warn(){},error(){},info(){}}},
  '../net/DataplaneStatus': statusModule, '../vpn/VpnConstants': {MODE_FULL:'full'},
  './ConnectionPolicy':{}, './HuksSecretStore': {}, './NodeStore': {}, './SettingsStore': {}, './SplitRouter': {},
  '../net/ConnectionHealth': load('net/ConnectionHealth.ets'),
  './StatusStore': {StatusStore:{readStatus(){return controllerState;}}}
}, {Date:{now:()=>now},setTimeout(){throw Error('established connection must not wait for background checks');}});
const controller = new controllerModule.ConnectionController();
for(const health of ['checking','check-failed','unverified']) {
  controllerState.connectionHealth=health;
  assert.equal(await controller.waitPhase({},30000,'full','g1'),controllerState);
}
console.log('PASS actual connection controller: no background-check wait after session establishment');

const catalog = load('services/NodeCatalog.ets', {
  '../core/OutboundReady':load('core/OutboundReady.ets'),
  '../core/UserRuleMap':load('core/UserRuleMap.ets'),
  '../core/BackupSelection':load('core/BackupSelection.ets')
});
const fixtureOutbound=JSON.stringify({protocol:'trojan',settings:{servers:[{address:'fixture.test',port:443,password:'fixture'}]},
  streamSettings:{network:'tcp',security:'tls',tlsSettings:{serverName:'fixture.test',allowInsecure:false}}});
const node = new catalog.NodeRecord();Object.assign(node,{name:'test-US1',region:catalog.REGION_US,protocol:'trojan',
  server:'fixture.test',port:443,outboundJson:fixtureOutbound});
let prior={name:'test-US1',usName:'test-US1',ytName:'test-US1'},rankCalls=0;
const router=load('services/SplitRouter.ets',{
  './ConnectionPolicy':{CONNECTION_POLICY:{mode(){return 'dual';},autoFailoverEnabled(){return false;}}},
  '../core/ChannelPolicy':load('core/ChannelPolicy.ets'),
  '../core/BackupSelection':load('core/BackupSelection.ets'),
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}},
  '../net/DataplaneCanary':{async tcpConnectCanary(){rankCalls++;return {ok:true,elapsedMs:10};}},
  './NodeCatalog':catalog,'./NodeStore':{NodeStore:{loadNodes(){return [{...node,id:'test-id',group:''}];},displayName(n){return n.name;},updateLatency(){return true;}}},
  './SettingsStore':{SettingsStore:{load(){return {chatgptNodeId:'',generalNodeId:'',routeMode:'rule',failoverGroup:'',failoverEnabled:true};}}},
  './StatusStore':{OUTBOUND_FILE:'outbound.json',StatusStore:{readNodes(){return [node];},readNodeMeta(){return prior;},writeText(){},writeNodeMeta(){},writeNodeMetaStaging(){}}},
  '../core/UserRuleMap':load('core/UserRuleMap.ets'), './UserRuleStore':{UserRuleStore:{enabledRoutes(){return [];}}},
  './AppRouteStore':{AppRouteStore:{load(){return {version:1,enabled:false,rules:[]};}}},
  '../core/AppRoutePayload':{AppRoutePayload:class { constructor(){this.config={version:1,enabled:false,rules:[]};this.nodes=[];} },AppNodeOutbound:class {}}
});
await router.prepareSingleProxy({});assert.equal(rankCalls,0,'valid existing selection must bypass foreground ranking');
prior={name:'removed',usName:'removed',ytName:'removed'};
await router.prepareSingleProxy({});assert.equal(rankCalls,1,'missing existing selection still ranks available catalog');
console.log('PASS actual selection router: reuse valid current nodes; rank on missing or first selection');
const probeStatus = liveStatus();
probeStatus.probeGoogleUrl = 'http://example.test/google';
probeStatus.probeDirectUrl = 'https://example.test/direct';
const probe = load('services/ProbeSelfCheck.ets', {
  '@kit.ArkTS': {util:{generateRandomUUID:()=> 'probe-test'}},
  '@kit.NetworkKit': { http: {}, socket: {} }, '@ohos.process': { default: { pid: 1, uid: 2 } },
  '../net/DataplaneStatus': statusModule, '../vpn/VpnConstants': { BUNDLE_NAME: 'test.bundle' },
  './StatusStore': { StatusStore: { readStatus() { probeStatus.at=clock; return probeStatus; } } }
}, { Date: { now: () => clock } }).PROBE_SELF_CHECK;
let calls = 0;
probe.runFetch = async () => { calls++; return true; };
probe.startLoop({});
await Promise.resolve();await Promise.resolve();
await probe.tick({}); assert.equal(calls, 1);
clock += 2000; probeStatus.evidenceRid = 'rid-2';
await probe.tick({}); assert.equal(calls, 1, 'healthy checks are rate limited across RIDs');
clock += 30000; await probe.tick({}); assert.equal(calls, 2);
clock += 30001; await probe.tick({}); assert.equal(calls, 3, 'successful same RID is periodically rechecked');
probe.nextRetryAt = clock + 120000; probe.failCount = 7; probeStatus.generation = 'g2';
await probe.tick({}); assert.equal(calls, 4, 'new session must not inherit old backoff');
probe.stopLoop();
console.log(`connection-health: ${count} decision tests plus actual probe cadence/restart replay passed`);
