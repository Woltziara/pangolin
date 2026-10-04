import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ready = require('./build/OutboundReady.js');
const dedupe = require('./build/NodeDedupe.js');
const commit = require('./build/OutboundCommit.js');
const channel = require('./build/ChannelPolicy.js');
const health = require('./build/LineHealth.js');
const backup = require('./build/BackupSelection.js');
const appRouteModel = require('./build/AppRouteModel.js');
const defaultAppRouteStore = { AppRouteStore: { load() { return { version: 1, enabled: false, rules: [] }; } } };
const appRoutePayloadStub = {
  AppRoutePayload: class { constructor() { this.config = { version: 1, enabled: false, rules: [] }; this.nodes = []; } },
  AppNodeOutbound: class {}
};
const appRouteRuntimeStub = {
  AppRouteRuntime: class { static async prepare() { return { ports: [], install() {}, stop() {}, reallocate() {}, diagnostics() { return {}; } }; } }
};

let passed = 0;
const pending = [];
function test(name, fn) {
  const result = fn();
  if (result && typeof result.then === 'function') {
    pending.push(Promise.resolve(result).then(() => {
      passed += 1;
      console.log('ok - ' + name);
    }));
    return;
  }
  passed += 1;
  console.log('ok - ' + name);
}

function load(path, deps = {}) {
  const source = readFileSync(new URL('../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, {
    module, exports: module.exports, Date, Map, Set,
    require(n) {
      // Passive journal behavior is exercised by runtime-journal/history tests.
      if (n === '../services/RuntimeJournal') return { RuntimeJournal: { sample() {}, event() {} } };
      if (!(n in deps)) throw Error('Unexpected import ' + n); return deps[n];
    }
  });
  return module.exports;
}

function trojan(host, extra = {}) {
  return JSON.stringify({
    protocol: 'trojan',
    settings: { servers: [{ address: host, port: 443, password: 'x' }] },
    streamSettings: {
      network: extra.network || 'tcp',
      security: 'tls',
      tlsSettings: { serverName: extra.sni || host, allowInsecure: false },
      wsSettings: extra.network === 'ws' ? { path: extra.path || '/ws' } : undefined
    }
  });
}

function vless(host, { sni } = {}) {
  const stream = { network: 'tcp', security: 'tls', tlsSettings: { allowInsecure: false } };
  if (sni) stream.tlsSettings.serverName = sni;
  return JSON.stringify({
    protocol: 'vless',
    settings: { vnext: [{ address: host, port: 443, users: [{ id: 'uuid' }] }] },
    streamSettings: stream
  });
}

test('digit-leading domain is not an IP and is runnable', () => {
  const json = trojan('1.edge.example', { sni: '1.edge.example' });
  assert.equal(ready.outboundRunError(json), '');
  assert.equal(ready.outboundIsRunnable(json), true);
});

test('IPv4 literal still cannot satisfy SNI', () => {
  const json = trojan('203.0.113.10', { sni: '203.0.113.10' });
  assert.match(ready.outboundRunError(json), /serverName\/SNI/);
});

test('vnext implicit domain SNI is accepted', () => {
  assert.equal(ready.outboundRunError(vless('edge.example.com')), '');
});

test('wrong allowInsecure still fails', () => {
  const json = JSON.stringify({
    protocol: 'trojan',
    settings: { servers: [{ address: '1.edge.example', port: 443, password: 'x' }] },
    streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: '1.edge.example', allowInsecure: true } }
  });
  assert.match(ready.outboundRunError(json), /证书/);
});

test('TCP and WS with same credential stay distinct', () => {
  const tcp = trojan('jp.example.com');
  const ws = trojan('jp.example.com', { network: 'ws', path: '/v2' });
  assert.notEqual(dedupe.nodeDedupeKey('trojan', tcp), dedupe.nodeDedupeKey('trojan', ws));
});

const store = load('services/NodeStore.ets', {
  '../core/NodeDedupe': dedupe,
  '../core/ShareLinkParser': { formatOutboundJsonToShareLink() { return ''; }, ParsedNode: class {} },
  './StatusStore': { StatusStore: { readJsonFile() { return ''; }, writeJsonAtomic() {} } }
});

function stored(id, sourceId, outboundJson, name) {
  const node = new store.StoredNode();
  node.id = id;
  node.name = name;
  node.sourceId = sourceId;
  node.protocol = 'trojan';
  node.server = 'jp.example.com';
  node.port = 443;
  node.outboundJson = outboundJson;
  node.rawLink = '';
  node.favorite = sourceId === 'manual';
  return node;
}

test('subscription cannot take over or delete a manual node', () => {
  const tcp = trojan('jp.example.com');
  const manual = stored('node-manual', 'manual', tcp, 'mine');
  const parsed = [{ name: 'sub', region: '日本', server: 'jp.example.com', port: 443, protocol: 'trojan', outboundJson: tcp, rawLink: '' }];
  const merged = store.NodeStore.mergeParsedNodes([manual], parsed, 'sub-b');
  assert.equal(merged.nodes.length, 2);
  const kept = merged.nodes.find((n) => n.id === 'node-manual');
  assert.equal(kept.sourceId, 'manual');
  assert.equal(kept.favorite, true);
  assert.ok(merged.nodes.some((n) => n.id === 'node-manual' && n.sourceId === 'manual'));
});

test('deleting one overlapping subscription keeps the other copy', () => {
  const tcp = trojan('jp.example.com');
  const a = stored('node-a', 'sub-a', tcp, 'A');
  const b = stored('node-b', 'sub-b', tcp, 'B');
  let disk = [a, b];
  store.NodeStore.loadNodes = () => disk;
  store.NodeStore.saveNodes = (_ctx, nodes) => { disk = nodes; };
  store.NodeStore.mergeRuntime({}, [], 'sub-a');
  assert.equal(disk.length, 1);
  assert.equal(disk[0].id, 'node-b');
  assert.equal(disk[0].sourceId, 'sub-b');
});

test('wrap failure keeps previous payload and does not apply B', () => {
  const a = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const b = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const decision = commit.decideProtect(false, true, b, '{"name":"B"}', a, '{"name":"A"}');
  assert.equal(decision.applied, false);
  assert.equal(decision.keepPrevious, true);
  assert.equal(decision.payload, a);
  assert.match(decision.error, /未应用/);
  const ok = commit.decideProtect(true, true, b, '{"name":"B"}', a, '{"name":"A"}');
  assert.equal(ok.applied, true);
  assert.equal(ok.payload, b);
  assert.equal(ok.snapshotPrevious, true);
});

test('read rejects payload that does not match commit digest', () => {
  const payload = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const rec = commit.makeCommit(payload, '{"name":"B"}', 'single', 'b', '', '', 2, 1);
  const mismatch = commit.verifyAppliedRead('{"protocol":"trojan","old":true,"padding":"xxxxxxxx"}', JSON.stringify(rec), '{"name":"B"}');
  assert.match(mismatch, /不一致/);
  assert.equal(commit.verifyAppliedRead(payload, JSON.stringify(rec), '{"name":"B"}'), '');
});

test('backup promotion follows the local safety state, not an edition', () => {
  assert.equal(channel.runtimeMayPromoteBackup(true, false), true);
  assert.equal(channel.runtimeMayPromoteBackup(false, false), false);
  assert.equal(channel.runtimeMayPromoteBackup(true, true), false);
});

test('google probe in chatgpt-general binds to general outbound, not US', () => {
  assert.equal(health.probeOutboundTag('google', 'chatgpt-general', 'dual'), 'proxy-yt');
  assert.equal(health.probeOutboundTag('youtube', 'chatgpt-general', 'dual'), 'proxy-yt');
  assert.equal(health.probeOutboundTag('line-health', 'chatgpt-general', 'dual'), 'proxy');
  let general = health.emptyLeg('proxy-yt');
  general = health.recordProbeResult(general, 'www.google.com', false);
  assert.equal(health.legShouldPromote(general, 2), false);
  general = health.recordProbeResult(general, 'www.youtube.com', false);
  assert.equal(health.legShouldPromote(general, 2), true);
  let proxy = health.emptyLeg('proxy');
  proxy = health.recordProbeResult(proxy, 'www.google.com', false);
  proxy = health.recordProbeResult(proxy, 'www.google.com', false);
  assert.equal(health.legShouldPromote(proxy, 2), false, 'one website cannot fail the other leg');
});

test('backup without fresh latency is not second-best', () => {
  const now = 1_000_000;
  const picked = backup.pickBackupWithEvidence([
    { name: 'other', outboundJson: '{"protocol":"trojan","padding":"xxxxxxxxxxxxxxxx"}', latencyMs: -1, latencyAt: 0 }
  ], 'current', now);
  assert.equal(picked.name, '');
  const fresh = backup.pickBackupWithEvidence([
    { name: 'other', outboundJson: '{"protocol":"trojan","padding":"xxxxxxxxxxxxxxxx"}', latencyMs: 40, latencyAt: now - 1000 }
  ], 'current', now);
  assert.equal(fresh.name, 'other');
});

test('HUKS unavailable cannot apply B', () => {
  const a = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const b = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const denied = commit.decideProtect(true, false, b, '{"name":"B"}', a, '{"name":"A"}');
  assert.equal(denied.applied, false);
  assert.match(denied.error, /不可用/);
});

test('write-point failures restore previous envelope/commit/meta', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const aPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const aEnv = unwrap(aPlain);
  const bEnv = unwrap(bPlain);
  const aMeta = '{"name":"A"}';
  const bMeta = '{"name":"B"}';
  const aCommit = JSON.stringify(commit.makeCommit(aPlain, aMeta, 'single', 'a', '', '', 1, 1));
  for (const failAt of [commit.ENVELOPE_FILE, commit.META_FILE, commit.COMMIT_FILE,
    'remove:' + commit.OUTBOUND_PLAIN_FILE, 'remove:' + commit.META_STAGING_FILE]) {
    const files = new commit.MemoryCommitFiles();
    files.data[commit.ENVELOPE_FILE] = aEnv;
    files.data[commit.META_FILE] = aMeta;
    files.data[commit.COMMIT_FILE] = aCommit;
    files.data[commit.OUTBOUND_PLAIN_FILE] = bPlain;
    files.data[commit.META_STAGING_FILE] = bMeta;
    files.failAt = failAt;
    const err = commit.applyNewCommit(files, bPlain, bMeta, bEnv, true, true);
    assert.match(err, /未应用/);
    assert.equal(commit.readCommittedEnvelope(files, unwrap), aPlain);
    assert.equal(JSON.parse(files.read(commit.META_FILE)).name, 'A');
  }
});

test('catalog preserves latency evidence used by backup pick', () => {
  const catalog = load('services/NodeCatalog.ets', {
    '../core/OutboundReady': ready,
    '../core/UserRuleMap': { UserRuleRoute: class {} },
    '../core/BackupSelection': backup
  });
  const now = Date.now();
  const raw = JSON.stringify({
    v: 2,
    nodes: [{
      name: 'A', region: '美国', server: 'a.example', port: 443, protocol: 'trojan',
      outbound: JSON.parse(trojan('a.example')), latencyMs: 20, latencyAt: now, latencyText: '20ms'
    }, {
      name: 'B', region: '美国', server: 'b.example', port: 443, protocol: 'trojan',
      outbound: JSON.parse(trojan('b.example')), latencyMs: 30, latencyAt: now, latencyText: '30ms'
    }]
  });
  const nodes = catalog.parseNodeCatalog(raw);
  assert.equal(nodes[0].latencyMs, 20);
  assert.equal(nodes[0].latencyAt, now);
  assert.equal(nodes[1].latencyMs, 30);
  const second = catalog.pickSecondBest(nodes, 'A', []);
  assert.equal(second.name, 'B');
});

test('proxy leg can promote only after two destinations fail, and can recover', () => {
  let proxy = health.emptyLeg('proxy');
  proxy = health.recordProbeResult(proxy, health.LINE_HEALTH_HOST, false);
  assert.equal(health.legShouldPromote(proxy, 2), false);
  proxy = health.recordProbeResult(proxy, health.LINE_HEALTH_HOST_B, false);
  assert.equal(health.legShouldPromote(proxy, 2), true);
  proxy = health.recordProbeResult(proxy, health.LINE_HEALTH_HOST, true);
  assert.equal(health.legShouldPromote(proxy, 2), false);
});

test('trial proof binds swapped legs and does not treat one website as the whole leg', () => {
  assert.equal(health.trialLegsProven(false, true, true, true, false, false), false,
    'healthy general google cannot prove a bad us leg');
  assert.equal(health.trialLegsProven(true, false, false, false, true, true), false,
    'healthy us cannot prove a bad general leg');
  assert.equal(health.trialLegsProven(true, true, true, true, false, false), false,
    'both legs swapped still need us destinations');
  assert.equal(health.trialLegsProven(true, true, true, true, true, true), true);
  assert.equal(health.trialLegsProven(false, true, true, true, true, false), false,
    'one us website fail is not whole-leg proof');
  assert.equal(health.trialLegsProven(false, true, false, true, true, true), true,
    'unswitched google fail does not decide the us trial');
  assert.equal(health.trialLegsProven(false, false, true, true, true, true), false);
});

test('policy preserves configured backup candidates in either channel mode', () => {
  const policyCore = load('core/ChannelPolicy.ets');
  const readyMod = load('core/OutboundReady.ets');
  const dual = JSON.stringify({
    v: 3, channelMode: 'dual', routingProfile: 'chatgpt-general',
    yt: JSON.parse(trojan('g.example')), us: JSON.parse(trojan('c.example')),
    yt2: JSON.parse(trojan('g2.example')), us2: JSON.parse(trojan('c2.example')),
    routeMode: 'rule'
  });
  const dualPolicy = load('services/ConnectionPolicy.ets', {
    '../core/ChannelPolicy': policyCore,
    '../core/OutboundReady': readyMod,
    './SettingsStore': { SettingsStore: { load() { return { channelMode: 'dual', failoverEnabled: true }; } } }
  }).CONNECTION_POLICY;
  assert.equal(dualPolicy.allowsAutoFailover(), true);
  assert.equal(dualPolicy.autoFailoverEnabled({}), true);
  const enforced = JSON.parse(dualPolicy.enforcePayload({}, dual));
  assert.ok(enforced.yt2); assert.ok(enforced.us2);
  const singlePolicy = load('services/ConnectionPolicy.ets', {
    '../core/ChannelPolicy': policyCore, '../core/OutboundReady': readyMod,
    './SettingsStore': { SettingsStore: { load() { return { channelMode: 'single', failoverEnabled: true }; } } }
  }).CONNECTION_POLICY;
  assert.equal(singlePolicy.mode({}), 'single');
  const single = JSON.parse(singlePolicy.enforcePayload({}, dual));
  assert.equal(single.v, 4);
  assert.ok(single.single2);
  const settingsText = readFileSync(new URL('../../entry/src/main/ets/pages/Settings.ets', import.meta.url), 'utf8');
  assert.match(settingsText, /CONNECTION_POLICY\.allowsAutoFailover\(\)/);
  const vpnText = readFileSync(new URL('../../entry/src/main/ets/vpn/TunnelVpnAbility.ets', import.meta.url), 'utf8');
  assert.match(vpnText, /runtimeMayPromoteBackup\(this\.failoverEnabled/);
  const huksText = readFileSync(new URL('../../entry/src/main/ets/services/HuksSecretStore.ets', import.meta.url), 'utf8');
  assert.match(huksText, /applyNewCommit\(/);
  assert.match(huksText, /readCommittedEnvelopeAsync\(/);
});

test('applied policy keeps intended pin distinct from failover executor', () => {
  const writes = [];
  const policyMod = load('services/AppliedPolicy.ets', {
    '../core/OutboundCommit': commit,
    './StatusStore': {
      StatusStore: {
        writeJsonAtomic(_c, _f, text) { writes.push(JSON.parse(text)); },
        readJsonFile() { return writes.length ? JSON.stringify(writes[writes.length - 1]) : ''; },
        readStatus() { return { xrayRunning: true, vpnCreated: true, at: Date.now(), generation: 'g' }; }
      }
    },
    './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
    './SettingsStore': {
      SettingsStore: {
        load() {
          return { chatgptNodeId: 'pin-a', generalNodeId: 'pin-g', singleNodeId: 'pin-a', routeMode: 'rule' };
        }
      }
    },
    './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; } } },
    '../core/ChannelPolicy': { routesForChannel(routes) { return routes; } },
    '../core/AppRouteModel': appRouteModel,
    './AppRouteStore': defaultAppRouteStore
  });
  policyMod.AppliedPolicy.record({}, JSON.stringify({
    routeMode: 'rule', channelMode: 'single', singleNodeId: 'backup-b', singleName: 'B',
    chatgptNodeId: '', generalNodeId: '', singleFailedOver: true, userRules: []
  }), 'g');
  assert.equal(writes[0].intendedSingleNodeId, 'pin-a');
  assert.equal(writes[0].singleNodeId, 'backup-b');
  assert.equal(writes[0].failedOver, true);
  assert.equal(writes[0].executingName, 'B');
});

test('legacy envelope without commit restores A when B write fails', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const aPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const files = new commit.MemoryCommitFiles();
  files.data[commit.ENVELOPE_FILE] = unwrap(aPlain);
  files.data[commit.META_FILE] = '{"name":"A"}';
  files.data[commit.OUTBOUND_PLAIN_FILE] = bPlain;
  files.data[commit.META_STAGING_FILE] = '{"name":"B"}';
  files.failAt = commit.META_FILE;
  const err = commit.applyNewCommit(files, bPlain, '{"name":"B"}', unwrap(bPlain), true, true);
  assert.match(err, /未应用/);
  assert.equal(commit.readCommittedEnvelope(files, unwrap), aPlain);
});

test('reader still returns A when restore commit write keeps failing', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const aPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const aMeta = '{"name":"A"}';
  const aCommit = JSON.stringify(commit.makeCommit(aPlain, aMeta, 'single', 'a', '', '', 1, 1));
  const files = new commit.MemoryCommitFiles();
  files.data[commit.ENVELOPE_FILE] = unwrap(aPlain);
  files.data[commit.META_FILE] = aMeta;
  files.data[commit.COMMIT_FILE] = aCommit;
  files.data[commit.OUTBOUND_PLAIN_FILE] = bPlain;
  files.data[commit.META_STAGING_FILE] = '{"name":"B"}';
  files.failAt = 'remove:' + commit.OUTBOUND_PLAIN_FILE;
  assert.match(commit.applyNewCommit(files, bPlain, '{"name":"B"}', unwrap(bPlain), true, true), /未应用/);
  files.failAt = commit.COMMIT_FILE;
  assert.equal(commit.readCommittedEnvelope(files, unwrap), aPlain);
});

test('empty store applied pack with staging delete dual-fault is applied B, not unread B', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const files = new commit.MemoryCommitFiles();
  files.data[commit.OUTBOUND_PLAIN_FILE] = bPlain;
  files.data[commit.META_STAGING_FILE] = '{"name":"B"}';
  files.failAt = 'remove:' + commit.ENVELOPE_NEXT_FILE;
  files.failAlso = ['remove:' + commit.APPLIED_FILE];
  const err = commit.applyNewCommit(files, bPlain, '{"name":"B"}', unwrap(bPlain), true, true);
  assert.equal(err, commit.STAGING_CLEANUP_WARNING);
  assert.doesNotMatch(err, /未应用/);
  assert.equal(commit.readCommittedEnvelope(files, unwrap), bPlain);
  assert.ok(files.read(commit.APPLIED_FILE).length > 8);
  assert.ok(files.read(commit.ENVELOPE_NEXT_FILE).length > 20);
});

test('restorePreviousCommit fails when applied pack stays B and reader still sees B', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const aPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const files = new commit.MemoryCommitFiles();
  assert.equal(commit.applyNewCommit(files, aPlain, '{"name":"A"}', unwrap(aPlain), true, true), '');
  assert.equal(commit.applyNewCommit(files, bPlain, '{"name":"B"}', unwrap(bPlain), true, true), '');
  files.failAt = commit.APPLIED_FILE;
  assert.equal(commit.restorePreviousCommit(files), false);
  assert.equal(commit.readCommittedEnvelope(files, unwrap), bPlain);
  assert.equal(files.read(commit.ENVELOPE_FILE), unwrap(aPlain));
});

test('restorePreviousCommit succeeds when applied pack is A even if envelope mirror fails', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const aPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const files = new commit.MemoryCommitFiles();
  assert.equal(commit.applyNewCommit(files, aPlain, '{"name":"A"}', unwrap(aPlain), true, true), '');
  assert.equal(commit.applyNewCommit(files, bPlain, '{"name":"B"}', unwrap(bPlain), true, true), '');
  files.failAt = commit.ENVELOPE_FILE;
  assert.equal(commit.restorePreviousCommit(files), true);
  assert.equal(commit.readCommittedEnvelope(files, unwrap), aPlain);
});

test('empty first commit failure is not consumed as legacy B', () => {
  const unwrap = (envelope) => envelope.split('').reverse().join('');
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const files = new commit.MemoryCommitFiles();
  files.data[commit.OUTBOUND_PLAIN_FILE] = bPlain;
  files.data[commit.META_STAGING_FILE] = '{"name":"B"}';
  files.failAt = commit.META_FILE;
  const err = commit.applyNewCommit(files, bPlain, '{"name":"B"}', unwrap(bPlain), true, true);
  assert.match(err, /新配置未应用/);
  assert.doesNotMatch(err, /上一版仍可恢复/);
  assert.throws(() => commit.readCommittedEnvelope(files, unwrap));
  const leftover = files.read(commit.ENVELOPE_FILE);
  if (leftover.length > 20) {
    assert.throws(() => commit.readCommittedEnvelope(files, unwrap), /未应用|不完整/);
  }
});

test('same-generation stale receipt does not match running B payload', () => {
  const files = {};
  let liveDigest = commit.digestText(JSON.stringify({ routeMode: 'rule', channelMode: 'single', singleNodeId: 'pin-a', singleName: 'A', userRules: [] }));
  const policyMod = load('services/AppliedPolicy.ets', {
    '../core/OutboundCommit': commit,
    './StatusStore': {
      StatusStore: {
        writeJsonAtomic(_c, name, text) { files[name] = text; },
        writeText(_c, name, text) { files[name] = text; },
        readJsonFile(_c, name) { return files[name] || ''; },
        readText(_c, name) { return files[name] || ''; },
        readStatus() { return { xrayRunning: true, vpnCreated: true, at: Date.now(), generation: 'g', payloadDigest: liveDigest }; }
      }
    },
    './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
    './SettingsStore': { SettingsStore: { load() { return { singleNodeId: 'pin-a', chatgptNodeId: '', generalNodeId: '', routeMode: 'rule' }; } } },
    './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; } } },
    '../core/ChannelPolicy': { routesForChannel(routes) { return routes; } },
    '../core/AppRouteModel': appRouteModel,
    './AppRouteStore': defaultAppRouteStore
  });
  const payloadA = JSON.stringify({ routeMode: 'rule', channelMode: 'single', singleNodeId: 'pin-a', singleName: 'A', userRules: [] });
  const payloadB = JSON.stringify({ routeMode: 'rule', channelMode: 'single', singleNodeId: 'backup-b', singleName: 'B', singleFailedOver: true, userRules: [] });
  policyMod.AppliedPolicy.noteRunning({}, payloadA);
  policyMod.AppliedPolicy.record({}, payloadA, 'g');
  assert.equal(policyMod.AppliedPolicy.matches({}), true);
  liveDigest = commit.digestText(payloadB);
  assert.equal(policyMod.AppliedPolicy.current({}) === null, true);
  assert.equal(policyMod.AppliedPolicy.matches({}), false);
  liveDigest = commit.digestText(payloadA);
  const dualFail = load('services/AppliedPolicy.ets', {
    '../core/OutboundCommit': commit,
    './StatusStore': {
      StatusStore: {
        writeJsonAtomic() { throw new Error('receipt'); },
        writeText() { throw new Error('digest'); },
        readJsonFile() { return files['applied-policy.json'] || ''; },
        readText() { return files[commit.RUNNING_DIGEST_FILE] || ''; },
        readStatus() { return { xrayRunning: true, vpnCreated: true, at: Date.now(), generation: 'g', payloadDigest: commit.digestText(payloadB) }; }
      }
    },
    './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
    './SettingsStore': { SettingsStore: { load() { return { singleNodeId: 'pin-a', chatgptNodeId: '', generalNodeId: '', routeMode: 'rule' }; } } },
    './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; } } },
    '../core/ChannelPolicy': { routesForChannel(routes) { return routes; } },
    '../core/AppRouteModel': appRouteModel,
    './AppRouteStore': defaultAppRouteStore
  });
  assert.throws(() => dualFail.AppliedPolicy.noteRunning({}, payloadB));
  assert.throws(() => dualFail.AppliedPolicy.record({}, payloadB, 'g'));
  assert.equal(dualFail.AppliedPolicy.matches({}), false);
  assert.equal(dualFail.AppliedPolicy.current({}) === null, true);
});

test('real single producer writes executing and backup ids', () => {
  const catalog = load('services/NodeCatalog.ets', {
    '../core/OutboundReady': ready, '../core/UserRuleMap': { UserRuleRoute: class {} }, '../core/BackupSelection': backup
  });
  const a = new catalog.NodeRecord();
  a.id = 'id-a'; a.name = 'A'; a.region = '美国'; a.outboundJson = trojan('a.example');
  const b = new catalog.NodeRecord();
  b.id = 'id-b'; b.name = 'B'; b.region = '美国'; b.outboundJson = trojan('b.example');
  const produced = JSON.parse(catalog.buildSingleOutboundPayload(a, 'rule', [], '', b));
  assert.equal(produced.singleNodeId, 'id-a');
  assert.equal(produced.single2Id, 'id-b');
  const swapped = JSON.parse(catalog.failoverSplitPayload(JSON.stringify(produced), true, true));
  assert.equal(swapped.singleNodeId, 'id-b');
  assert.equal(swapped.single2Id, 'id-a');
});

test('stale dual latency is not second-best; group filter uses id/group not display name', () => {
  const catalog = load('services/NodeCatalog.ets', {
    '../core/OutboundReady': ready, '../core/UserRuleMap': { UserRuleRoute: class {} }, '../core/BackupSelection': backup
  });
  const now = Date.now();
  const raw = JSON.stringify({
    v: 2,
    nodes: [{
      id: 'slow-g', name: 'B', group: 'g', region: '美国', server: 'allowed-slow.test', port: 443, protocol: 'trojan',
      outbound: JSON.parse(trojan('allowed-slow.test')), latencyMs: 80, latencyAt: now
    }, {
      id: 'fast-h', name: 'B', group: 'h', region: '美国', server: 'disallowed-faster.test', port: 443, protocol: 'trojan',
      outbound: JSON.parse(trojan('disallowed-faster.test')), latencyMs: 10, latencyAt: now
    }, {
      id: 'stale', name: 'C', group: 'g', region: '美国', server: 'stale.test', port: 443, protocol: 'trojan',
      outbound: JSON.parse(trojan('stale.test')), latencyMs: 5, latencyAt: now - 86400000
    }]
  });
  const nodes = catalog.parseNodeCatalog(raw);
  const stalePick = catalog.pickSecondBest(nodes.filter((n) => n.id === 'stale'), 'A', [], 'other', now);
  assert.equal(stalePick.name, '');
  const grouped = nodes.filter((n) => n.group === 'g');
  const second = catalog.pickSecondBest(grouped, 'primary', [], 'primary-id', now);
  assert.equal(second.id, 'slow-g');
  assert.equal(second.server, 'allowed-slow.test');
});

test('line-health destinations are not the same Cloudflare name family', () => {
  assert.equal(health.LINE_HEALTH_HOST.includes('cloudflare'), true);
  assert.equal(health.LINE_HEALTH_HOST_B.includes('cloudflare'), false);
});

test('backup discovery probes only the failover group', async () => {
  const catalog = load('services/NodeCatalog.ets', {
    '../core/OutboundReady': ready, '../core/UserRuleMap': { UserRuleRoute: class {} }, '../core/BackupSelection': backup
  });
  const stored = [];
  for (let i = 0; i < 3; i++) {
    stored.push({
      id: 'out-' + i, name: 'out-' + i, group: 'h', region: '美国', server: 'out' + i + '.test', port: 443,
      protocol: 'trojan', outboundJson: trojan('out' + i + '.test'), latencyMs: -1, latencyAt: 0, latencyText: '', customName: ''
    });
  }
  stored.push({
    id: 'id-a', name: 'A', group: 'g', region: '美国', server: 'a.example', port: 443, protocol: 'trojan',
    outboundJson: trojan('a.example'), latencyMs: -1, latencyAt: 0, latencyText: '', customName: ''
  });
  stored.push({
    id: 'id-g', name: 'G', group: 'g', region: '美国', server: 'g.example', port: 443, protocol: 'trojan',
    outboundJson: trojan('g.example'), latencyMs: -1, latencyAt: 0, latencyText: '', customName: ''
  });
  const probed = [];
  const saved = [];
  const channelPolicy = load('core/ChannelPolicy.ets');
  const router = load('services/SplitRouter.ets', {
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    '../net/DataplaneCanary': { async tcpConnectCanary(_h, port, _t) { probed.push(port); return { ok: true, elapsedMs: 40 }; } },
    './NodeCatalog': catalog,
    './NodeStore': {
      NodeStore: {
        loadNodes() { return stored; },
        displayName(n) { return n.name; },
        updateLatency(_c, id, ms, text) {
          const node = stored.find((item) => item.id === id);
          if (node) { node.latencyMs = ms; node.latencyText = text; node.latencyAt = Date.now(); }
          return true;
        }
      }
    },
    './SettingsStore': {
      SettingsStore: {
        load() {
          return { channelMode: 'single', singleNodeId: 'id-a', routeMode: 'rule', failoverEnabled: true, failoverGroup: 'g' };
        }
      }
    },
    './StatusStore': {
      OUTBOUND_FILE: 'outbound.json',
      StatusStore: {
        writeText(_c, file, text) { saved.push({ file, text }); },
        writeNodeMetaStaging() {},
        readNodeMeta() { return { name: 'A', ytName: 'A', usName: 'A' }; }
      }
    },
    './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
    './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; }, autoFailoverEnabled() { return true; } } },
    '../core/BackupSelection': backup,
    '../core/ChannelPolicy': channelPolicy,
    '../core/UserRuleMap': { UserRuleRoute: class {} },
    './AppRouteStore': defaultAppRouteStore,
    '../core/AppRoutePayload': appRoutePayloadStub
  });
  await router.prepareSingleProxy({});
  const produced = JSON.parse(saved.find((item) => item.file === 'outbound.json').text);
  assert.equal(produced.single2Id, 'id-g');
  assert.ok(!String(produced.single2 && JSON.stringify(produced.single2) || '').includes('out0.test'));
});

function loadVpnAbility(opts = {}) {
  const logs = [];
  const destOk = Object.assign({
    'www.baidu.com': true,
    'www.google.com': true,
    'www.youtube.com': true
  }, opts.destOk || {});
  destOk[health.LINE_HEALTH_HOST] = destOk[health.LINE_HEALTH_HOST] === undefined ? true : destOk[health.LINE_HEALTH_HOST];
  destOk[health.LINE_HEALTH_HOST_B] = destOk[health.LINE_HEALTH_HOST_B] === undefined ? true : destOk[health.LINE_HEALTH_HOST_B];
  let restoreCount = 0;
  const sessions = [];
  const cleanups = [];
  const nativeStops = { global: 0, owned: [] };
  const nativeStarts = [];
  const policy = { recorded: 0, noted: 0 };
  const restoreResult = opts.restoreResult === undefined ? true : opts.restoreResult;
  const deps = {
    '../services/ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'dual'; }, enforcePayload(_c, p) { return p; }, autoFailoverEnabled() { return true; } } },
    '../core/ChannelPolicy': channel,
    '@kit.NetworkKit': {
      VpnExtensionAbility: class {},
      connection: {},
      vpnExtension: {
        createVpnConnection() {
          return {
            protectProcessNet: async () => {
              if (opts.protectHold) {
                await opts.protectHold;
              }
            },
            create: async () => 3,
            protect: async () => {}
          };
        }
      }
    },
    '@kit.PerformanceAnalysisKit': {
      hilog: {
        info(_d, _t, msg) { logs.push(String(msg)); },
        warn(_d, _t, msg) { logs.push(String(msg)); },
        error(_d, _t, msg) { logs.push(String(msg)); }
      }
    },
    '@kit.ArkTS': {},
    '../net/DataplaneStatus': statusMod,
    '../core/XrayRuntime': {
      SocksSession: class { constructor() { this.host = '127.0.0.1'; this.port = 1; this.user = 'u'; this.pass = 'p'; } },
      newSocksSession() { return new (class { constructor() { this.host = '127.0.0.1'; this.port = 2; this.user = 'u'; this.pass = 'p'; } })(); },
      buildRuntimeXrayConfig() { return '{}'; },
      NODE_META_FILE: 'node-meta.json',
      parseNodeMeta() { return { name: 'A', region: '' }; }
    },
    '../native/TunnelNative': {
      getNativeStats() {
        return {
          xrayRunning: opts.coreOk !== false,
          xrayStarting: false,
          tunRunning: opts.hevOk !== false,
          poisoned: false
        };
      },
      startNativeXray() {
        const result = {
          ok: opts.coreOk !== false,
          message: opts.coreMessage || (opts.coreOk === false ? 'core fail' : 'started'),
          poisoned: false,
          ownerSeq: opts.ownerSeq === undefined ? 11 : opts.ownerSeq
        };
        nativeStarts.push(result);
        return result;
      },
      stopNativeXray() { nativeStops.global += 1; return { ok: true, message: 'stopped' }; },
      stopNativeXrayOwned(seq) { nativeStops.owned.push(seq); return { ok: true, message: 'owned-stop', ownerSeq: seq }; },
      stopNativeTun2Socks() { return { ok: true, message: 'stopped' }; },
      startNativeHevTun() { return { ok: opts.hevOk !== false, message: opts.hevOk === false ? 'hev' : 'started' }; },
      setProtectCallback() { return 1; },
      clearProtectCallback() { return 0; },
      claimProtectFd() { return 1; },
      ackProtectFd() { return 0; }
    },
    '../net/DataplaneCanary': {
      async socksHttpCanary(_h, _p, target) {
        return { ok: destOk[target] === true, elapsedMs: 1, message: String(target) };
      },
      async tcpConnectCanary() { return { ok: false, elapsedMs: 1, message: '' }; }
    },
    './VpnConstants': { MODE_FULL: 'full', VPN_COMMAND_KEY: 'command', VPN_GENERATION_KEY: 'generation', VPN_MODE_KEY: 'mode' },
    '../services/AppliedPolicy': {
      AppliedPolicy: {
        record() { policy.recorded += 1; },
        noteRunning() { policy.noted += 1; }
      }
    },
    '../services/AppRouteRuntime': appRouteRuntimeStub,
    '../core/LineHealth': health,
    '../core/OutboundCommit': commit,
    '../services/HuksSecretStore': {
      HuksSecretStore: {
        restorePrevious() {
          restoreCount += 1;
          if (opts.restoreThrow) {
            throw new Error('restore write');
          }
          return restoreResult;
        },
        async readOutbound() { return opts.outboundJson || '{"v":4,"channelMode":"dual","routingProfile":"chatgpt-general"}'; },
        async protectOutbound() {}
      }
    },
    '../services/StatusStore': {
      OUTBOUND_FILE: 'outbound.json',
      StatusStore: {
        readText() { return ''; },
        writeText() {},
        readStatus() { return {}; },
        writeStatus() {},
        writeNodeMeta() {},
        readNodeMeta() { return { name: 'A', region: '' }; },
        removeFile() {},
        destExistsNonempty() { return false; }
      }
    }
  };
  for (const n of ['../core/HevTunConfig', '../core/OutboundTiming', '../net/NodeAddressResolver', '../net/ProcNet',
    '../services/EventStore', '../services/NodeCatalog', '../services/SettingsStore',
    '../services/LatencyProbe', '../services/NodeLatencyTest', '../net/ConnectionHealth', '../net/NodeEndpointProbe']) {
    deps[n] = n === '../core/HevTunConfig' ? { buildHevTunConfigYaml() { return ''; } } : {};
  }
  deps['../net/NodeAddressResolver'] = { withSystemResolvedNodes: async (config) => config };
  deps['../services/SettingsStore'] = { SettingsStore: { load() { return { failoverGroup: '' }; } } };
  const Vpn = load('vpn/TunnelVpnAbility.ets', deps).default;
  const v = new Vpn();
  v.context = { filesDir: '/private' };
  v.generation = 'g';
  v.status.generation = 'g';
  v.status.sessionRevision = 1;
  v.desiredRunning = true;
  v.status.desiredRunning = true;
  v.nodeSystemDns = false;
  v.tunFd = opts.tunFd === undefined ? 3 : opts.tunFd;
  v.status.vpnCreated = opts.vpnCreated !== false;
  v.status.tunFdValid = v.tunFd >= 0;
  v.latestCommand = opts.latestCommand === undefined ? {
    token: 1, kind: 'start', generation: 'g', mode: 'full', outboundTrace: false, nodeSystemDns: false
  } : opts.latestCommand;
  if (opts.liveStartChain) {
    v.generation = '';
    v.latestCommand = null;
    v.status.vpnCreated = false;
    v.tunFd = -1;
    v.status.tunFdValid = false;
    v.commandEpoch = 0;
  }
  v.failoverTrial = opts.trialYt === true || opts.trialUs === true || opts.failoverTrial === true;
  v.failoverTrialYt = opts.trialYt === true;
  v.failoverTrialUs = opts.trialUs === true;
  v.refreshCounters = () => true;
  v.publishAccessSlice = () => {};
  v.applyLiveEvidence = () => {};
  v.publish = () => {};
  v.emit = () => {};
  v.fail = opts.keepFail ? v.fail.bind(v) : () => {};
  if (!opts.liveStartChain) {
    v.beginSession = (g, m, t) => {
      sessions.push({ g, m, t });
      v.cancelled = false;
      v.status.vpnCreated = true;
      v.tunFd = 1;
    };
  }
  v.requestCleanup = (reason) => {
    cleanups.push(reason);
  };
  return { v, logs, restoreCount: () => restoreCount, sessions, cleanups, nativeStops, nativeStarts, policy };
}

const statusMod = load('net/DataplaneStatus.ets');

function simulateCleanupRestart(v) {
  v.cancelled = true;
  v.cleaningUp = false;
  v.status.vpnCreated = false;
  v.tunFd = -1;
  v.dispatchLatest();
}

test('recover failure after failover trial restores previous commit', async () => {
  const statusMod = load('net/DataplaneStatus.ets');
  let restored = 0;
  const deps = {
    '../services/ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; }, enforcePayload(_c, p) { return p; }, autoFailoverEnabled() { return true; } } },
    '../core/ChannelPolicy': channel,
    '@kit.NetworkKit': { VpnExtensionAbility: class {}, connection: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    '@kit.ArkTS': {},
    '../net/DataplaneStatus': statusMod,
    '../core/XrayRuntime': { SocksSession: class { constructor() { this.host = '127.0.0.1'; this.port = 1; this.user = 'u'; this.pass = 'p'; } }, newSocksSession() { return new (class { constructor() { this.host = '127.0.0.1'; this.port = 2; this.user = 'u'; this.pass = 'p'; } })(); }, buildRuntimeXrayConfig() { return '{}'; }, NODE_META_FILE: 'node-meta.json', parseNodeMeta() { return { name: 'A', region: '' }; } },
    '../native/TunnelNative': { getNativeStats() { return { xrayRunning: false, xrayStarting: false, tunRunning: false }; }, startNativeXray() { return { ok: false, message: 'core fail' }; }, stopNativeXray() { return { ok: true, message: 'stopped' }; }, stopNativeTun2Socks() { return { ok: true, message: 'stopped' }; }, startNativeHevTun() { return { ok: false, message: 'hev' }; } },
    '../net/DataplaneCanary': { async socksHttpCanary() { return { ok: false, elapsedMs: 1, message: '' }; }, async tcpConnectCanary() { return { ok: false, elapsedMs: 1, message: '' }; } },
    './VpnConstants': { MODE_FULL: 'full', VPN_COMMAND_KEY: 'command', VPN_GENERATION_KEY: 'generation', VPN_MODE_KEY: 'mode' },
    '../services/AppliedPolicy': { AppliedPolicy: { record() {}, noteRunning() {} } },
    '../services/AppRouteRuntime': appRouteRuntimeStub,
    '../core/LineHealth': health,
    '../core/OutboundCommit': commit,
    '../services/HuksSecretStore': { HuksSecretStore: { restorePrevious() { restored += 1; return true; }, async readOutbound() { return '{"v":4}'; }, async protectOutbound() {} } },
    '../services/StatusStore': { OUTBOUND_FILE: 'outbound.json', StatusStore: { readText() { return '{}'; }, writeText() {}, readStatus() { return {}; }, writeStatus() {}, writeNodeMeta() {} } }
  };
  for (const n of ['../core/HevTunConfig', '../core/OutboundTiming', '../net/NodeAddressResolver', '../net/ProcNet',
    '../services/EventStore', '../services/NodeCatalog', '../services/SettingsStore',
    '../services/LatencyProbe', '../services/NodeLatencyTest', '../net/ConnectionHealth', '../net/NodeEndpointProbe']) {
    deps[n] = n === '../core/HevTunConfig' ? { buildHevTunConfigYaml() { return ''; } } : {};
  }
  const Vpn = load('vpn/TunnelVpnAbility.ets', deps).default;
  const v = new Vpn();
  v.context = { filesDir: '/private' };
  v.generation = 'g';
  v.status.generation = 'g';
  v.status.sessionRevision = 1;
  v.desiredRunning = true;
  v.failoverTrial = true;
  v.fail = () => {};
  v.requestCleanup = () => {};
  v.publish = () => {};
  v.emit = () => {};
  v.dispatchLatest = () => {};
  await v.recover();
  assert.ok(restored >= 1);
});

test('recover canary does not accept a bad us leg because general google succeeded', async () => {
  const fx = loadVpnAbility({
    trialUs: true,
    destOk: { 'www.google.com': true, 'www.youtube.com': true, [health.LINE_HEALTH_HOST]: false, [health.LINE_HEALTH_HOST_B]: false }
  });
  await fx.v.recover();
  assert.ok(fx.restoreCount() >= 1);
  assert.equal(fx.v.failoverTrial, false);
  simulateCleanupRestart(fx.v);
  assert.equal(fx.sessions.length, 1);
});

test('recover canary does not accept a bad general leg because us health succeeded', async () => {
  const fx = loadVpnAbility({
    trialYt: true,
    destOk: { 'www.google.com': false, 'www.youtube.com': false, [health.LINE_HEALTH_HOST]: true, [health.LINE_HEALTH_HOST_B]: true }
  });
  await fx.v.recover();
  assert.ok(fx.restoreCount() >= 1);
  simulateCleanupRestart(fx.v);
  assert.equal(fx.sessions.length, 1);
});

test('recover canary verifies both swapped legs', async () => {
  const badUs = loadVpnAbility({
    trialYt: true,
    trialUs: true,
    destOk: { 'www.google.com': true, 'www.youtube.com': true, [health.LINE_HEALTH_HOST]: false, [health.LINE_HEALTH_HOST_B]: false }
  });
  await badUs.v.recover();
  assert.ok(badUs.restoreCount() >= 1);
  const proven = loadVpnAbility({
    trialYt: true,
    trialUs: true,
    destOk: { 'www.google.com': true, 'www.youtube.com': true, [health.LINE_HEALTH_HOST]: true, [health.LINE_HEALTH_HOST_B]: true }
  });
  await proven.v.recover();
  assert.equal(proven.restoreCount(), 0);
  assert.equal(proven.v.failoverTrial, false);
  assert.equal(proven.sessions.length, 0);
});

test('recover canary treats one us website fail as incomplete leg proof', async () => {
  const fx = loadVpnAbility({
    trialUs: true,
    destOk: { 'www.google.com': true, 'www.youtube.com': true, [health.LINE_HEALTH_HOST]: false, [health.LINE_HEALTH_HOST_B]: true }
  });
  await fx.v.recover();
  assert.ok(fx.restoreCount() >= 1, 'one website fail is not whole-leg success');
});

test('recover canary accepts us trial from us destinations even if unswitched google failed', async () => {
  const fx = loadVpnAbility({
    trialUs: true,
    destOk: { 'www.google.com': false, 'www.youtube.com': true, [health.LINE_HEALTH_HOST]: true, [health.LINE_HEALTH_HOST_B]: true }
  });
  await fx.v.recover();
  assert.equal(fx.restoreCount(), 0);
  assert.equal(fx.v.failoverTrial, false);
  assert.equal(fx.v.failoverTrialUs, false);
});

test('restorePrevious success keeps start command so cleanup restarts A', async () => {
  const fx = loadVpnAbility({ failoverTrial: true, coreOk: false, restoreResult: true });
  await fx.v.recover();
  assert.ok(fx.restoreCount() >= 1);
  assert.equal(fx.logs.some((msg) => msg.indexOf('restored previous commit') >= 0), true);
  assert.equal(fx.v.desiredRunning, true);
  assert.equal(fx.v.latestCommand !== null && fx.v.latestCommand.kind === 'start', true);
  assert.equal(fx.v.failoverTrial, false);
  simulateCleanupRestart(fx.v);
  assert.equal(fx.sessions.length, 1);
});

test('restorePrevious false does not claim restored or restart still-B as A', async () => {
  const fx = loadVpnAbility({ failoverTrial: true, trialUs: true, coreOk: false, restoreResult: false });
  await fx.v.recover();
  assert.ok(fx.restoreCount() >= 1);
  assert.equal(fx.logs.some((msg) => msg.indexOf('restored previous commit') >= 0), false);
  assert.equal(fx.logs.some((msg) => msg.indexOf('previous commit not restored') >= 0), true);
  assert.equal(fx.v.desiredRunning, false);
  assert.equal(fx.v.latestCommand === null || fx.v.latestCommand.kind !== 'start', true);
  assert.equal(fx.v.failoverTrialUs, true);
  simulateCleanupRestart(fx.v);
  assert.equal(fx.sessions.length, 0);
});

test('user cancel during restore success does not late-start A', async () => {
  const fx = loadVpnAbility({
    failoverTrial: true,
    coreOk: false,
    restoreResult: true,
    latestCommand: { token: 2, kind: 'stop', generation: 'g', mode: 'full', outboundTrace: false, nodeSystemDns: false }
  });
  fx.v.desiredRunning = false;
  fx.v.status.desiredRunning = false;
  await fx.v.recover();
  assert.ok(fx.restoreCount() >= 1);
  simulateCleanupRestart(fx.v);
  assert.equal(fx.sessions.length, 0);
});

test('single VPN start want does not dispatch a second start from onRequest', async () => {
  const fx = loadVpnAbility({
    liveStartChain: true,
    coreOk: false,
    coreMessage: 'Xray start notify failed',
    keepFail: true,
    vpnCreated: false,
    tunFd: -1
  });
  const want = { parameters: { generation: 'g1', mode: 'full', nodeSystemDns: 'false' } };
  fx.v.onCreate(want);
  fx.v.onRequest(want, 1);
  const deadline = Date.now() + 1000;
  while (fx.nativeStarts.length === 0 && Date.now() < deadline) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(fx.nativeStarts.length, 1, 'same want must not start xray twice');
  assert.equal(fx.nativeStarts[0].ok, false);
  assert.ok(fx.logs.some((msg) => msg.indexOf('ignore duplicate start command') >= 0));
  assert.equal(fx.logs.some((msg) => msg.indexOf('queue start until in-flight') >= 0), false);
  assert.ok(fx.cleanups.some((reason) => String(reason).indexOf('start failed') >= 0));
  assert.ok(String(fx.v.status.lastError).indexOf('Xray start notify failed') >= 0);
});

test('newer generation queued during start still runs after the first command finishes', async () => {
  let releaseProtect;
  const holdProtect = new Promise((resolve) => {
    releaseProtect = resolve;
  });
  const fx = loadVpnAbility({
    liveStartChain: true,
    coreOk: false,
    coreMessage: 'Xray start notify failed',
    keepFail: true,
    vpnCreated: false,
    tunFd: -1,
    protectHold: holdProtect
  });
  const want1 = { parameters: { generation: 'g1', mode: 'full', nodeSystemDns: 'false' } };
  const want2 = { parameters: { generation: 'g2', mode: 'full', nodeSystemDns: 'false' } };
  fx.v.onCreate(want1);
  fx.v.onRequest(want2, 2);
  assert.ok(fx.logs.some((msg) => msg.indexOf('queue start until in-flight') >= 0));
  assert.equal(fx.v.latestCommand.generation, 'g2');
  releaseProtect();
  const deadline = Date.now() + 1000;
  while (fx.nativeStarts.length < 2 && Date.now() < deadline) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.ok(fx.nativeStarts.length >= 2,
    'a later user generation must still start after the in-flight command starts=' +
      fx.nativeStarts.length + ' logs=' + fx.logs.join(' | ') + ' cleanups=' + fx.cleanups.join(','));
});

test('late xray start result does not resume a cancelled recover', async () => {
  const delayed = loadVpnAbility({ failoverTrial: true, restoreResult: true, ownerSeq: 41 });
  delayed.v.startXrayWithPortRetry = async () => {
    delayed.v.cancelled = true;
    delayed.v.desiredRunning = false;
    delayed.v.latestCommand = {
      token: 2, kind: 'stop', generation: 'g', mode: 'full', outboundTrace: false, nodeSystemDns: false
    };
    return { ok: true, message: 'started', poisoned: false, ownerSeq: 41 };
  };
  await delayed.v.recover();
  assert.ok(delayed.cleanups.some((reason) => String(reason).indexOf('stale') >= 0));
  assert.deepEqual(delayed.nativeStops.owned, [41]);
  simulateCleanupRestart(delayed.v);
  assert.equal(delayed.sessions.length, 0);
});

test('stale recover after real xray start uses owned stop and does not record policy', async () => {
  const fx = loadVpnAbility({ ownerSeq: 41 });
  const orig = fx.v.startXrayWithPortRetry.bind(fx.v);
  fx.v.startXrayWithPortRetry = async (cfg) => {
    const result = await orig(cfg);
    fx.v.generation = 'b';
    fx.v.status.generation = 'b';
    return result;
  };
  await fx.v.recover();
  assert.equal(fx.policy.recorded, 0, 'stale start must not write AppliedPolicy');
  assert.equal(fx.policy.noted, 0, 'stale start must not noteRunning');
  assert.deepEqual(fx.nativeStops.owned, [41]);
  assert.equal(fx.nativeStops.global, 1, 'only the live pre-restart stop may be global');
  assert.ok(fx.cleanups.some((reason) => String(reason).indexOf('stale') >= 0));
});

test('live recover records policy and does not owned-stop the new core', async () => {
  const fx = loadVpnAbility({ ownerSeq: 7 });
  await fx.v.recover();
  assert.ok(fx.policy.recorded >= 1);
  assert.ok(fx.policy.noted >= 1);
  assert.equal(fx.nativeStops.owned.length, 0);
});

test('restorePrevious write throw is not logged as restored', async () => {
  const fx = loadVpnAbility({ failoverTrial: true, coreOk: false, restoreThrow: true });
  await fx.v.recover();
  assert.equal(fx.logs.some((msg) => msg.indexOf('restored previous commit') >= 0), false);
  assert.equal(fx.v.desiredRunning, false);
  simulateCleanupRestart(fx.v);
  assert.equal(fx.sessions.length, 0);
});

test('single prepare discovers bounded backups without a prior manual ping', async () => {
  const catalog = load('services/NodeCatalog.ets', {
    '../core/OutboundReady': ready, '../core/UserRuleMap': { UserRuleRoute: class {} }, '../core/BackupSelection': backup
  });
  const stored = [
    { id: 'id-a', name: 'A', group: '', region: '美国', server: 'a.example', port: 443, protocol: 'trojan',
      outboundJson: trojan('a.example'), latencyMs: -1, latencyAt: 0, latencyText: '', customName: '' },
    { id: 'id-b', name: 'B', group: '', region: '美国', server: 'b.example', port: 443, protocol: 'trojan',
      outboundJson: trojan('b.example'), latencyMs: -1, latencyAt: 0, latencyText: '', customName: '' }
  ];
  let probes = 0;
  const saved = [];
  const channelPolicy = load('core/ChannelPolicy.ets');
  const router = load('services/SplitRouter.ets', {
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    '../net/DataplaneCanary': { async tcpConnectCanary() { probes += 1; return { ok: true, elapsedMs: 25 }; } },
    './NodeCatalog': catalog,
    './NodeStore': {
      NodeStore: {
        loadNodes() { return stored; },
        displayName(n) { return n.name; },
        updateLatency(_c, id, ms, text) {
          const node = stored.find((item) => item.id === id);
          if (node) { node.latencyMs = ms; node.latencyText = text; node.latencyAt = Date.now(); }
          return true;
        }
      }
    },
    './SettingsStore': {
      SettingsStore: {
        load() {
          return { channelMode: 'single', singleNodeId: 'id-a', routeMode: 'rule', failoverEnabled: true, failoverGroup: '' };
        }
      }
    },
    './StatusStore': {
      OUTBOUND_FILE: 'outbound.json',
      StatusStore: {
        writeText(_c, file, text) { saved.push({ file, text }); },
        writeNodeMetaStaging(_c, text) { saved.push({ file: 'meta', text }); },
        readNodeMeta() { return { name: 'A', ytName: 'A', usName: 'A' }; }
      }
    },
    './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
    './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; }, autoFailoverEnabled() { return true; } } },
    '../core/BackupSelection': backup,
    '../core/ChannelPolicy': channelPolicy,
    '../core/UserRuleMap': { UserRuleRoute: class {} },
    './AppRouteStore': defaultAppRouteStore,
    '../core/AppRoutePayload': appRoutePayloadStub
  });
  await router.prepareSingleProxy({});
  assert.ok(probes > 0 && probes <= 3);
  const produced = JSON.parse(saved.find((item) => item.file === 'outbound.json').text);
  assert.ok(produced.single2);
  assert.equal(produced.single2Id, 'id-b');
});

test('build recipe uses relative xray replace and close-once hold', () => {
  const build = readFileSync(new URL('../../scripts/build_libxray_ohos.sh', import.meta.url), 'utf8');
  assert.match(build, /go mod edit -replace="github.com\/xtls\/xray-core=\.\/third_party\/xray-core-protect-fail-closed"/);
  assert.match(build, /STAGED_SO=/);
  const native = readFileSync(new URL('../../entry/src/main/cpp/napi_init.cpp', import.meta.url), 'utf8');
  assert.match(native, /holdFd\.exchange\(-1\)/);
  assert.match(native, /g_xrayJobMu/);
  const startFn = native.split('napi_value StartXray(')[1].split('void* XrayStopWorker(')[0];
  assert.match(startFn, /napi_create_promise/);
  assert.doesNotMatch(startFn, /usleep\(/);
  assert.match(native, /XrayStartWatch/);
  assert.match(native, /KeepOrphan\(job\)/);
  assert.match(startFn, /ReapXrayStartWorker\(job, false\)/);
  assert.match(native, /xray_start_notify.h/);
  assert.match(native, /xray_start_lifecycle.h/);
  const notifyH = readFileSync(new URL('../../entry/src/main/cpp/xray_start_notify.h', import.meta.url), 'utf8');
  assert.match(notifyH, /XrayClassifyTsfnStatus/);
  assert.match(notifyH, /XRAY_NOTIFY_RETRY_LIMIT/);
  assert.match(notifyH, /XrayAdvanceNotify/);
  assert.match(native, /napi_closing/);
  assert.match(native, /drop without release/);
  assert.match(native, /StartXrayTsfnFinalize/);
  assert.match(native, /g_xrayTsfnFailRemaining/);
  assert.match(native, /start notify failed; tsfn released for finalize/);
  assert.doesNotMatch(native, /retry later/);
  const tunNative = readFileSync(new URL('../../entry/src/main/ets/native/TunnelNative.ets', import.meta.url), 'utf8');
  assert.doesNotMatch(tunNative, /notify bound reached/);
  assert.doesNotMatch(tunNative, /Promise\.race/);
  assert.match(tunNative, /stopNativeXrayOwned/);
  assert.match(native, /XraySettleNotify/);
  assert.match(native, /RequestOwnedCoreStop/);
  assert.match(native, /stopXrayOwned/);
  const settleFn = native.split('void SettleXrayStartJob(')[1].split('void* XrayStartWatch(')[0];
  assert.doesNotMatch(settleFn, /StopStartedXrayLocked/);
  assert.doesNotMatch(settleFn, /KeepOrphan/);
  assert.match(settleFn, /result\.stopOwnerSeq/);
  const finishFn = native.split('void FinishXrayStartJob(')[1].split('void* XrayStartWorker(')[0];
  assert.match(finishFn, /XrayFinishStartedJob/);
  assert.match(finishFn, /RequestOwnedCoreStop/);
  const workerFn = native.split('void* XrayStartWorker(')[1].split('bool WaitLocalTcp(')[0];
  assert.doesNotMatch(workerFn, /StopStartedXrayLocked/);
  assert.match(workerFn, /FinishXrayStartJob\(job, true/);
  const stopOwnedFn = native.split('napi_value StopXrayOwned(')[1].split('napi_value StopXray(')[0];
  assert.doesNotMatch(stopOwnedFn, /return StopXray\(/);
  assert.match(stopOwnedFn, /XrayAcquireStopPermit/);
  assert.match(native, /XrayRunPermittedStop\(g_xrayCore, job->permit/);
  assert.match(native, /xray stop still in flight/);
  const vpnSrc = readFileSync(new URL('../../entry/src/main/ets/vpn/TunnelVpnAbility.ets', import.meta.url), 'utf8');
  assert.match(vpnSrc, /stopStartedXray\(coreResult\)/);
  assert.doesNotMatch(vpnSrc, /stopNativeXray\(\);\s*\n\s*this\.requestCleanup\('stale after xray start'/);
  const fateSrc = fileURLToPath(new URL('../../tests/xray_start_fate_test.cpp', import.meta.url));
  const fateText = readFileSync(fateSrc, 'utf8');
  assert.doesNotMatch(fateText, /FakeSettle/);
  assert.doesNotMatch(fateText, /ApplyOwnedStop/);
  assert.match(fateText, /XraySettleNotify/);
  assert.match(fateText, /XrayFinalizeDeferred/);
  assert.match(fateText, /XrayFinishStartedJob/);
  assert.match(fateText, /XrayRunPermittedStop/);
  assert.match(fateText, /XrayAcquireStopPermit/);
  assert.match(fateText, /AlreadySettled/);
  assert.match(fateText, /XrayInspectNotifyInject/);
  assert.match(native, /start notify already settled/);
  assert.match(native, /inject file present/);
  assert.doesNotMatch(native, /inject file consumed/);
  assert.match(vpnSrc, /ignore duplicate start command/);
  const lifeSrc = fileURLToPath(new URL('../../entry/src/main/cpp/xray_start_lifecycle.cpp', import.meta.url));
  const fateBin = '/tmp/tongdao-xray-fate';
  execFileSync('c++', ['-std=c++17', '-pthread', '-o', fateBin, fateSrc, lifeSrc]);
  execFileSync(fateBin);
});

await Promise.all(pending);
console.log(`redteam-fixes: ${passed} tests passed`);
