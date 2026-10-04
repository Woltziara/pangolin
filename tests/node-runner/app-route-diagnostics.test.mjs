import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const payloadModel = require('./build/AppRoutePayload.js');
const appModel = require('./build/AppRouteModel.js');

function load(path, deps) {
  const source = readFileSync(new URL('../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, {
    module, exports: module.exports, Date, Set, Map, Promise,
    require(name) {
      if (!(name in deps)) { throw Error('Unexpected import ' + name); }
      return deps[name];
    }
  });
  return module.exports;
}

const outbound = {
  protocol: 'trojan',
  settings: { servers: [{ address: 'node.example', port: 443, password: 'fixture' }] },
  streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: 'node.example' } }
};
const payload = JSON.stringify({
  v: 4,
  single: outbound,
  routeMode: 'rule',
  appRouting: {
    config: {
      version: 1,
      enabled: true,
      rules: [{ id: 'only-rule', bundleName: 'org.test.allowed', label: 'Allowed', nodeId: 'node-a', enabled: true,
        createdAt: 1, updatedAt: 1 }]
    },
    nodes: [{ nodeId: 'node-a', outbound }]
  }
});

let uid = 101;
let ownerBundle = 'org.test.allowed';
let ownerFailure = false;
let callback = null;
let failAck = false;
const acks = [];
const native = {
  clearAppRouteCallback() { callback = null; return 0; },
  setAppRouteCallback(next) { callback = next; return 0; },
  ackAppRoute(...args) { acks.push(args); return failAck ? -1 : 0; }
};
const catalog = {
  AppCatalog: {
    observed() { return []; },
    async resolve(bundleName) { return { bundleName, label: 'Allowed', uid: 101, lastSeenAt: 1 }; }
  },
  OBSERVED_APPS_FILE: 'observed-apps.json'
};
const { AppRouteRuntime } = load('services/AppRouteRuntime.ets', {
  '@kit.AbilityKit': { bundleManager: { async getBundleNameByUid() { return ownerBundle; } } },
  '@kit.NetworkKit': {
    connection: {
      ProtocolType: { PROTO_TYPE_TCP: 6, PROTO_TYPE_UDP: 17 },
      async getConnectOwnerUid() {
        if (ownerFailure) { throw Error('sentinel raw owner failure'); }
        return uid;
      }
    }
  },
  '../core/AppRoutePayload': payloadModel,
  '../core/AppRouteModel': appModel,
  '../core/XrayRuntime': { newSocksSession() { return { port: 24001 }; } },
  '../native/TunnelNative': native,
  './AppCatalog': catalog,
  './StatusStore': { StatusStore: { writeJsonAtomic() {} } }
});

const flow = (requestId, protocol = 6) => ({
  requestId, protocol, family: protocol === 6 ? 4 : 6,
  // Sentinels must never enter the diagnostic result.
  sourceAddress: 'SENTINEL_SOURCE_ADDRESS', sourcePort: 41001,
  destinationAddress: 'SENTINEL_DESTINATION_ADDRESS', destinationPort: 443
});
const plain = value => JSON.parse(JSON.stringify(value));

const disabled = await AppRouteRuntime.prepare({}, JSON.stringify({ routeMode: 'direct' }), 24000);
assert.deepEqual(plain(disabled.diagnostics()), {
  enabled: false, active: false, configuredRules: 0, pending: 0, queries: 0, selected: 0, defaulted: 0,
  rejected: 0, ownerQueryFailed: 0, identityMismatch: 0, overloaded: 0, inactive: 0, ackFailed: 0,
  tcpQueries: 0, udpQueries: 0
});

const runtime = await AppRouteRuntime.prepare({}, payload, 24000);
runtime.install();
assert.equal(typeof callback, 'function');

await runtime.resolveFlow(flow(1)); // selected TCP
uid = 777;
await runtime.resolveFlow(flow(2, 17)); // default UDP
uid = 101;
ownerBundle = 'org.test.reinstalled';
await runtime.resolveFlow(flow(3)); // selected UID but wrong bundle
ownerBundle = 'org.test.allowed';
ownerFailure = true;
await runtime.resolveFlow(flow(4)); // owner query failure
ownerFailure = false;

runtime.resolving = 128;
await runtime.resolveFlow(flow(5)); // bounded overload; no owner query
runtime.resolving = 0;

let resolveLate;
const late = new Promise(resolve => { resolveLate = resolve; });
const originalOwner = ownerFailure;
// Temporarily replace the bridge dependency behavior through the existing async owner call.
// The promise is injected by using a one-shot public mock closure.
let delayOwner = true;
const delayedRuntime = load('services/AppRouteRuntime.ets', {
  '@kit.AbilityKit': { bundleManager: { async getBundleNameByUid() { return 'org.test.allowed'; } } },
  '@kit.NetworkKit': { connection: { ProtocolType: { PROTO_TYPE_TCP: 6, PROTO_TYPE_UDP: 17 },
    async getConnectOwnerUid() { if (delayOwner) { return await late; } return 101; } } },
  '../core/AppRoutePayload': payloadModel, '../core/AppRouteModel': appModel,
  '../core/XrayRuntime': { newSocksSession() { return { port: 24002 }; } },
  '../native/TunnelNative': native, './AppCatalog': catalog,
  './StatusStore': { StatusStore: { writeJsonAtomic() {} } }
}).AppRouteRuntime;
const stopped = await delayedRuntime.prepare({}, payload, 24000);
stopped.install();
const lateResult = stopped.resolveFlow(flow(6));
stopped.stop();
resolveLate(101);
await lateResult;
delayOwner = false;
assert.equal(originalOwner, false);

runtime.install();
failAck = true;
await runtime.resolveFlow(flow(7)); // selected decision, failed native acknowledgement
failAck = false;
runtime.stop();
await runtime.resolveFlow(flow(8)); // inactive early return

const diag = plain(runtime.diagnostics());
assert.deepEqual(diag, {
  enabled: true, active: false, configuredRules: 1, pending: 0, queries: 5, selected: 2, defaulted: 1,
  rejected: 4, ownerQueryFailed: 1, identityMismatch: 1, overloaded: 1, inactive: 1, ackFailed: 1,
  tcpQueries: 4, udpQueries: 1
});
const stoppedDiag = stopped.diagnostics();
assert.equal(stoppedDiag.inactive, 1, 'a completion after stop is rejected as inactive');
assert.equal(stoppedDiag.rejected, 1);
assert.equal(stoppedDiag.queries, 1);
assert.equal(JSON.stringify(diag).includes('SENTINEL_SOURCE_ADDRESS'), false);
assert.equal(JSON.stringify(diag).includes('SENTINEL_DESTINATION_ADDRESS'), false);
assert.deepEqual(acks.map(item => item[0]), [1, 2, 3, 4, 5, 6, 7, 8]);
console.log('PASS AppRouteRuntime count-only diagnostics: selections, defaults, failures, overload, stop, ack failure, no tuple data');
