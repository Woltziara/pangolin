import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

function load(path, deps = {}) {
  const source = readFileSync(new URL('../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, { module, exports: module.exports, Date, require(name) {
    if (!(name in deps)) { throw Error('Unexpected dependency ' + name); }
    return deps[name];
  } });
  return module.exports;
}

const channel = load('core/ChannelPolicy.ets');
const ready = load('core/OutboundReady.ets');
let mode = 'dual';
const policy = load('services/ConnectionPolicy.ets', {
  '../core/ChannelPolicy': channel, '../core/OutboundReady': ready,
  './SettingsStore': { SettingsStore: { load() { return { channelMode: mode, failoverEnabled: true }; } } }
}).CONNECTION_POLICY;
const outbound = (host) => ({ protocol: 'trojan', settings: { servers: [{ address: host, port: 443, password: 'fixture' }] },
  streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: host, allowInsecure: true } } });
const raw = JSON.stringify({ v: 3, channelMode: 'dual', routingProfile: 'chatgpt-general',
  us: outbound('chat.test'), yt: outbound('general.test'), us2: outbound('chat-backup.test'), yt2: outbound('general-backup.test') });
const dual = JSON.parse(policy.enforcePayload({}, raw));
assert.equal(dual.us2.settings.servers[0].address, 'chat-backup.test');
assert.equal(dual.us.streamSettings.tlsSettings.allowInsecure, false);
mode = 'single';
const single = JSON.parse(policy.enforcePayload({}, raw));
assert.equal(single.v, 4); assert.ok(single.single2);
const vpn = readFileSync(new URL('../../entry/src/main/ets/vpn/TunnelVpnAbility.ets', import.meta.url), 'utf8');
assert(!vpn.includes('EditionCapability'));
assert(vpn.includes('runtimeMayPromoteBackup(this.failoverEnabled'));
console.log('PASS self-use build: both channel modes and strict TLS without edition gating');
