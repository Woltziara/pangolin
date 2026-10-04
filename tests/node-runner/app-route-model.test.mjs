import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '../../entry/src/main/ets/core/AppRouteModel.ets'), 'utf8');
const js = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext }
}).outputText;
const model = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

const rule = (overrides = {}) => ({
  id: 'route-1', bundleName: 'com.example.player', label: 'Player', nodeId: 'node-us-1',
  enabled: true, createdAt: 10, updatedAt: 11, ...overrides
});
const config = (overrides = {}) => JSON.stringify({ version: 1, enabled: true, rules: [rule()], ...overrides });

const normalized = model.normalizeAppRoutingConfig(config());
assert.equal(normalized.rules.length, 1);
assert.equal(normalized.rules[0].bundleName, 'com.example.player');
assert.throws(() => model.normalizeAppRoutingConfig(config({ rules: [rule(), rule({ id: 'route-2' })] })), /重复/);
assert.throws(() => model.normalizeAppRoutingConfig(config({ rules: [rule({ bundleName: 'not-a-bundle' })] })), /bundleName/);
assert.throws(() => model.normalizeAppRoutingConfig(config({ rules: Array.from({ length: 65 }, (_, i) => rule({ id: `route-${i}`, bundleName: `com.example.app${i}` })) })), /64/);
assert.throws(() => model.normalizeAppRoutingConfig('{"version":1,"enabled":true,"rules":[null]}'), /对象/);

const reversed = model.normalizeAppRoutingConfig(JSON.stringify({ version: 1, enabled: true, rules: [
  rule({ id: 'route-b', bundleName: 'com.example.zebra' }), rule({ id: 'route-a', bundleName: 'com.example.alpha' })
] }));
assert.deepEqual(reversed.rules.map((item) => item.bundleName), ['com.example.alpha', 'com.example.zebra']);
const changedCosmetics = model.normalizeAppRoutingConfig(config({ rules: [rule({ label: 'New label', createdAt: 99, updatedAt: 100 })] }));
assert.equal(model.appRoutingFingerprint(normalized), model.appRoutingFingerprint(changedCosmetics));
assert.notEqual(model.appRoutingFingerprint(normalized), model.appRoutingFingerprint(model.normalizeAppRoutingConfig(config({ rules: [rule({ nodeId: 'node-us-2' })] }))));

// The receipt is only current when the app-routing snapshot that native accepted
// equals the stored policy. Old payloads intentionally mean disabled + no rules.
const policySource = readFileSync(join(here, '../../entry/src/main/ets/services/AppliedPolicy.ets'), 'utf8');
const policyJs = ts.transpileModule(policySource, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
}).outputText;
const files = {};
let storedConfig = model.normalizeAppRoutingConfig(JSON.stringify({ version: 1, enabled: false, rules: [] }));
const policyModule = { exports: {} };
vm.runInNewContext(policyJs, {
  module: policyModule, exports: policyModule.exports, JSON, Date, Error,
  require(name) {
    const deps = {
      '../core/OutboundCommit': { digestText: (text) => `digest:${text}`, RUNNING_DIGEST_FILE: 'running-digest.json' },
      './StatusStore': { StatusStore: {
        writeJsonAtomic(_ctx, file, text) { files[file] = text; }, writeText(_ctx, file, text) { files[file] = text; },
        readJsonFile(_ctx, file) { return files[file] || ''; },
        readStatus() { return { xrayRunning: true, vpnCreated: true, at: Date.now(), generation: 'g', payloadDigest: files.liveDigest }; }
      } },
      './UserRuleStore': { UserRuleStore: { enabledRoutes() { return []; } } },
      './SettingsStore': { SettingsStore: { load() { return { routeMode: 'rule', singleNodeId: 'node-us-1', chatgptNodeId: '', generalNodeId: '' }; } } },
      './ConnectionPolicy': { CONNECTION_POLICY: { mode() { return 'single'; } } },
      '../core/ChannelPolicy': { routesForChannel(routes) { return routes; } },
      '../core/AppRouteModel': model,
      './AppRouteStore': { AppRouteStore: { load() { return storedConfig; } } }
    };
    if (!(name in deps)) { throw new Error(`unexpected dependency ${name}`); }
    return deps[name];
  }
});
const legacyPayload = JSON.stringify({ routeMode: 'rule', channelMode: 'single', singleNodeId: 'node-us-1', userRules: [] });
files.liveDigest = `digest:${legacyPayload}`;
policyModule.exports.AppliedPolicy.record({}, legacyPayload, 'g');
assert.equal(policyModule.exports.AppliedPolicy.matches({}), true, 'old payload is disabled/empty App routing');
const activeConfig = model.normalizeAppRoutingConfig(config());
const activePayload = JSON.stringify({ routeMode: 'rule', channelMode: 'single', singleNodeId: 'node-us-1', userRules: [], appRouting: { config: activeConfig, nodes: [] } });
storedConfig = activeConfig;
files.liveDigest = `digest:${activePayload}`;
policyModule.exports.AppliedPolicy.record({}, activePayload, 'g');
assert.equal(JSON.parse(files['applied-policy.json']).appRoutingFingerprint, model.appRoutingFingerprint(activeConfig));
assert.equal(policyModule.exports.AppliedPolicy.matches({}), true);
storedConfig = model.normalizeAppRoutingConfig(config({ rules: [rule({ nodeId: 'node-us-2' })] }));
assert.equal(policyModule.exports.AppliedPolicy.matches({}), false, 'changed App node must await a reconnect');
console.log('app route model tests ok');
