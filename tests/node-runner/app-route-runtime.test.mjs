import {legacyBoundary} from './helpers/legacy-boundaries.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const payloadModel = require('./build/AppRoutePayload.js');
const model = require('./build/AppRouteModel.js');
function load(path, deps) {
  const source = readFileSync(new URL('../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, { module, exports: module.exports, Date, Set, Map, setTimeout, clearTimeout,
    require(name) { if (!(name in deps)) {const b=legacyBoundary(name);if(b!==undefined)return b;throw Error('Unexpected import '+name);} return deps[name]; } });
  return module.exports;
}
const node = name => ({ protocol: 'trojan', settings: { servers: [{ address: name + '.example', port: 443, password: 'fixture' }] },
  streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: name + '.example', allowInsecure: false } } });
const rule = (bundleName, nodeId) => ({ id: bundleName, bundleName, nodeId, label: bundleName,
  enabled: true, createdAt: 1, updatedAt: 1 });
const policy = { config: { version: 1, enabled: true, rules: [rule('org.test.alpha', 'a'), rule('org.test.beta', 'b')] },
  nodes: [{ nodeId: 'a', outbound: node('a') }, { nodeId: 'b', outbound: node('b') }] };
const payload = JSON.stringify({ v: 4, single: node('default'), routeMode: 'rule',
  appRouting: policy, userRules: [{ domain: 'example.com', action: 'direct' }] });
assert.equal(payloadModel.parseAppRoutePayload(undefined).config.enabled, false);
assert.throws(() => payloadModel.parseAppRoutePayload({ ...policy, nodes: [] }), /节点/);
assert.throws(() => payloadModel.parseAppRoutePayload({ ...policy, nodes: [...policy.nodes, policy.nodes[0]] }), /重复/);
const bindings = [];
payloadModel.addUidBinding(bindings, { uid: 101, bundleName: 'org.test.alpha', nodeId: 'a' });
assert.throws(() => payloadModel.addUidBinding(bindings, { uid: 101, bundleName: 'org.test.beta', nodeId: 'b' }), /共用/);
assert.equal(payloadModel.portForUid(-1, bindings, []), -1);
assert.equal(payloadModel.portForUid(202, bindings, []), 0);
assert.equal(payloadModel.portForUid(101, bindings, []), -1);
let produced = '', routeMode = 'rule', storedNodes = ['default', 'a', 'b'].map(id => ({ id, name: id,
  region: 'test', server: id + '.example', port: 443, protocol: 'trojan', outboundJson: JSON.stringify(node(id)), group: '' }));
const producer = load('services/SplitRouter.ets', {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } }, '../net/DataplaneCanary': {},
  './NodeCatalog': { NodeRecord: class {}, nodeUsableForSplit() { return true; },
    shortNodeName: name => name, singleMetaJson() { return '{}'; },
    buildSingleOutboundPayload(record, mode) { return JSON.stringify({ v: 4, single: JSON.parse(record.outboundJson), routeMode: mode }); } },
  './NodeStore': { NodeStore: { loadNodes() { return storedNodes; }, displayName(n) { return n.name; } } },
  './SettingsStore': { SettingsStore: { load() { return { routeMode }; } } },
  './StatusStore': { OUTBOUND_FILE: 'outbound.json', StatusStore: { writeText(_ctx, path, text) {
    if (path === 'outbound.json') produced = text;
  }, writeNodeMetaStaging() {} } },
  '../core/UserRuleMap': {}, './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
  './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; }, autoFailoverEnabled() { return false; } } },
  '../core/ChannelPolicy': require('./build/ChannelPolicy.js'), '../core/BackupSelection': {},
  './AppRouteStore': { AppRouteStore: { load() { return policy.config; } } }, '../core/AppRoutePayload': payloadModel
});
assert.equal(producer.prepareManualPlan({}, 'default'), 'default');
assert.equal(JSON.parse(produced).appRouting.nodes.length, 2);
assert.equal(JSON.parse(produced).appRouting.nodes[1].outbound.settings.servers[0].address, 'b.example');
const beforeMissing = produced;
storedNodes = storedNodes.filter(n => n.id !== 'b');
assert.throws(() => producer.prepareManualPlan({}, 'default'), /不存在/);
assert.equal(produced, beforeMissing, 'missing explicit App node must not replace committed staging with a partial policy');
routeMode = 'direct'; producer.prepareManualPlan({}, 'default');
assert.equal(JSON.parse(produced).appRouting.nodes.length, 0, 'direct pauses app node requirements');

const runtimeConfig = load('core/XrayRuntime.ets', {
  './CoreInfo': { DEBUG_ACCESS: false }, './LineHealth': { LINE_HEALTH_HOST: 'probe.example', LINE_HEALTH_HOST_B: 'probe2.example' },
  '../native/TunnelNative': {}, './OutboundReady': require('./build/OutboundReady.js'),
  './UserRuleMap': require('./build/UserRuleMap.js'), './AppRoutePayload': payloadModel
});
const socks = { host: '127.0.0.1', port: 20101, user: 'test-user', pass: 'test-pass' };
const ports = [{ nodeId: 'a', port: 20102 }, { nodeId: 'b', port: 20103 }];
const config = JSON.parse(runtimeConfig.buildRuntimeXrayConfig(payload, socks, '', '', false, ports));
assert.equal(config.inbounds.length, 3);
for (let i = 0; i < 2; i++) {
  const inbound = config.inbounds.find(x => x.port === ports[i].port);
  assert.equal(inbound.listen, '127.0.0.1'); assert.equal(inbound.settings.auth, 'password');
  assert.deepEqual(inbound.settings.accounts, [{ user: socks.user, pass: socks.pass }]);
  const selected = config.routing.rules.find(x => x.inboundTag?.includes(inbound.tag) && x.outboundTag !== 'dns-out');
  assert.equal(selected.outboundTag, inbound.tag);
  assert.equal(config.outbounds.find(x => x.tag === selected.outboundTag).settings.servers[0].address, i ? 'b.example' : 'a.example');
  assert.ok(config.routing.rules.indexOf(selected) < config.routing.rules.findIndex(x => x.domain?.includes('domain:example.com')));
}
assert.deepEqual(config.routing.rules[0].inboundTag, ['tun-in', 'app-node-0', 'app-node-1']);
assert.equal(config.routing.rules[4].outboundTag, 'direct');
assert.throws(() => runtimeConfig.buildRuntimeXrayConfig(payload, socks, ''), /端口/);
assert.throws(() => runtimeConfig.buildRuntimeXrayConfig(payload, socks, '', '', false,
  [{ nodeId: 'a', port: socks.port }, ports[1]]), /端口/);
const direct = JSON.parse(runtimeConfig.buildRuntimeXrayConfig(payload, socks, '', 'direct'));
assert.equal(direct.inbounds.length, 1); assert.equal(direct.outbounds.some(x => x.tag.startsWith('app-node-')), false);
const resolvedHosts = [];
const resolver = load('net/NodeAddressResolver.ets', {
  '@kit.NetworkKit': { connection: { async getAddressesByName(host) {
    resolvedHosts.push(host); return [{ address: '203.0.113.1' }, { address: '2001:db8::1' }];
  } } }
});
const resolvedConfig = JSON.parse(await resolver.withSystemResolvedNodes(JSON.stringify(config)));
assert.ok(resolvedHosts.includes('a.example') && resolvedHosts.includes('b.example'));
assert.equal(resolvedConfig.outbounds.find(x => x.tag === 'app-node-0').streamSettings.sockopt.domainStrategy, 'ForceIP');
assert.equal(resolvedConfig.outbounds.find(x => x.tag === 'app-node-1').streamSettings.sockopt.happyEyeballs.tryDelayMs, 250);

let nextPort = 22000, uid = 101, shared = false, ownerName = '', query = null, callback = null;
let epoch = 0, calls = [], writes = [], lookupArgs = [];
const catalog = { AppCatalog: { observed() { return []; }, async resolve(bundleName) {
  return { bundleName, label: bundleName, uid: shared ? 101 : bundleName === 'org.test.alpha' ? 101 : 102, lastSeenAt: 1 };
} }, OBSERVED_APPS_FILE: 'observed-apps.json' };
const native = { clearAppRouteCallback() { callback = null; epoch++; return 0; },
  setAppRouteCallback(cb) { callback = cb; return 0; }, ackAppRoute(...args) { calls.push(args); return 0; } };
const { AppRouteRuntime } = load('services/AppRouteRuntime.ets', {
  '@kit.AbilityKit': { bundleManager: { async getBundleNameByUid(value) {
    return ownerName || (value === 101 ? 'org.test.alpha' : 'org.test.beta');
  } } },
  '@kit.NetworkKit': { connection: { ProtocolType: { PROTO_TYPE_TCP: 6, PROTO_TYPE_UDP: 17 },
    async getConnectOwnerUid(...args) { lookupArgs.push(args); if (query) return await query; return uid; } } },
  '../core/AppRoutePayload': payloadModel, '../core/AppRouteModel': model,
  '../core/XrayRuntime': { newSocksSession() { return { port: ++nextPort }; } },
  '../native/TunnelNative': native, './AppCatalog': catalog,
  './StatusStore': { StatusStore: { writeJsonAtomic(_ctx, path, value) { writes.push([path, JSON.parse(value)]); } } }
});
shared = true;
await assert.rejects(() => AppRouteRuntime.prepare({}, payload, 22000), /共用/);
shared = false;
const runtime = await AppRouteRuntime.prepare({}, payload, 22000);
assert.equal(runtime.ports.length, 2);
runtime.install(); assert.equal(typeof callback, 'function');
const flow = { requestId: 1, protocol: 6, family: 4, sourceAddress: '172.19.0.2', sourcePort: 40100,
  destinationAddress: '203.0.113.5', destinationPort: 443 };
await runtime.resolveFlow(flow);
assert.deepEqual(calls.at(-1), [1, 0, runtime.ports[0].port]);
assert.equal(lookupArgs.at(-1)[0], 6);
assert.equal(lookupArgs.at(-1)[1].address, flow.sourceAddress); assert.equal(lookupArgs.at(-1)[1].port, 40100);
assert.equal(lookupArgs.at(-1)[2].address, flow.destinationAddress); assert.equal(lookupArgs.at(-1)[2].port, 443);
uid = 102;
await runtime.resolveFlow({ ...flow, requestId: 2, protocol: 17, family: 6,
  sourceAddress: 'fd00::2', destinationAddress: '2001:db8::5' });
assert.deepEqual(calls.at(-1), [2, 0, runtime.ports[1].port]);
assert.equal(lookupArgs.at(-1)[0], 17); assert.equal(lookupArgs.at(-1)[1].family, 2);
uid = 777; await runtime.resolveFlow({ ...flow, requestId: 3 }); assert.deepEqual(calls.at(-1), [3, 1, 0]);
uid = -1; await runtime.resolveFlow({ ...flow, requestId: 4 }); assert.deepEqual(calls.at(-1), [4, -1, 0]);
uid = 101; ownerName = 'org.test.reused';
await runtime.resolveFlow({ ...flow, requestId: 5 }); assert.deepEqual(calls.at(-1), [5, -1, 0]); ownerName = '';
let finish; query = new Promise(resolve => { finish = resolve; });
const stale = runtime.resolveFlow({ ...flow, requestId: 6 }); runtime.stop(); finish(101); await stale;
assert.deepEqual(calls.at(-1), [6, -1, 0]); query = null;
const directRuntime = await AppRouteRuntime.prepare({}, JSON.stringify({ routeMode: 'direct', appRouting: { bad: true } }), 22000);
directRuntime.install(); assert.equal(callback, null); assert.equal(directRuntime.ports.length, 0);
const discovery = await AppRouteRuntime.prepare({}, JSON.stringify({ appRouting: { config: { version: 1, enabled: true, rules: [] }, nodes: [] } }), 22000);
discovery.install(); uid = -1;
await discovery.resolveFlow({ ...flow, requestId: 7 }); assert.deepEqual(calls.at(-1), [7, 1, 0]); discovery.stop();
console.log('PASS App runtime: real payload/Xray/UID consumer, TCP+UDP+IPv6 tuples, independent endpoints, identity reuse, conflict, unknown owner, late generation, direct/discovery');
