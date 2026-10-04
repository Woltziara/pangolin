import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const text = readFileSync(new URL('../../entry/src/main/ets/services/SubscriptionManager.ets', import.meta.url), 'utf8');
const source = { id: 'offline-source', url: 'https://example.com/sub', nodeCount: 0, lastUpdateAt: 0, lastError: '' };
const calls = [];
const nodes = [{ name: 'one' }, { name: 'two' }];
const module = { exports: {} };
const dependencies = {
  '@kit.NetworkKit': { http: {} },
  '@kit.ArkTS': { util: {} },
  '../core/Encoding': {},
  '../core/IdnUrl': { toIdnUrl: (url) => url },
  '../core/UserFacingCopy': {},
  '../core/ShareLinkParser': {},
  '../core/SubscriptionParser': {},
  './NodeStore': { NodeStore: {
    mergeRuntime(_ctx, incoming, id, prune) { calls.push({ incoming, id, prune }); },
    loadNodes() { return nodes; },
    filterBySource(all, id) { assert.equal(id, source.id); return all; }
  } },
  './SubscriptionStore': { SubscriptionStore: {
    add(_ctx, _name, url) { assert.equal(url, source.url); return source; },
    findById(_ctx, id) { assert.equal(id, source.id); return source; },
    update(_ctx, record) { assert.equal(record, source); }
  } },
  './StatusStore': {}, '../vpn/VpnConstants': {}, './ProbeSelfCheck': {}
};
vm.runInNewContext(ts.transpileModule(text, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText, { module, exports: module.exports, require: (id) => {
  if (!(id in dependencies)) throw Error(`unexpected import ${id}`);
  return dependencies[id];
}, console, Error, Object, Array, Number, Date });

const manager = module.exports.SubscriptionManager;
assert.throws(() => manager.commitOfflineSubscription({}, 'http://example.com/sub', nodes), /HTTP/);
assert.equal(calls.length, 0);
const result = manager.commitOfflineSubscription({}, source.url, nodes);
assert.equal(result.sourceId, source.id);
assert.equal(result.nodeCount, 2);
assert.deepEqual(calls.map(({ id, prune, incoming }) => ({ id, prune, count: incoming.length })),
  [{ id: source.id, prune: false, count: 2 }]);
assert.equal(source.lastUpdateAt, 0, 'offline import must not claim a successful online refresh');
assert.match(source.lastError, /在线更新尚未确认/);
console.log('PASS offline source saves nodes without pruning or claiming an online refresh');
