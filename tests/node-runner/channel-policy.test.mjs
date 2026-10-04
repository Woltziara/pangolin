import assert from 'node:assert/strict';
import { effectiveChannelMode, payloadForFailover, routesForChannel, runtimeMayPromoteBackup, singleChannelPayload } from './build/ChannelPolicy.js';

const routes = [{ domain: 'proxy.example', action: 'proxy' }, { domain: 'group.example', action: 'group', groupTag: 'saved' }];
const split = { v: 3, channelMode: 'dual', yt: { protocol: 'trojan', fixture: 'general' },
  us: { protocol: 'trojan', fixture: 'chatgpt' }, yt2: { protocol: 'trojan', fixture: 'backup' },
  ytName: 'General', routeMode: 'rule', userRules: routes,
  appRouting: { config: { version: 1, enabled: true, rules: [] }, nodes: [] } };

assert.equal(effectiveChannelMode('dual'), 'dual');
assert.equal(effectiveChannelMode('anything-else'), 'single');
assert.deepEqual(routesForChannel(routes, 'single'), [routes[0]]);
assert.deepEqual(routesForChannel(routes, 'dual'), routes);
const single = JSON.parse(singleChannelPayload(JSON.stringify(split)));
assert.equal(single.v, 4); assert.deepEqual(single.single, split.yt); assert.deepEqual(single.single2, split.yt2);
assert.equal(single.channelMode, 'single'); assert.deepEqual(single.userRules, [routes[0]]);
assert.deepEqual(single.appRouting, split.appRouting);
assert.equal(runtimeMayPromoteBackup(true, false), true);
assert.equal(runtimeMayPromoteBackup(false, false), false);
assert.equal(runtimeMayPromoteBackup(true, true), false);
assert.equal(payloadForFailover(JSON.stringify(split), true), JSON.stringify(split));
const disabled = JSON.parse(payloadForFailover(JSON.stringify({ ...split, yt2Id: 'backup-id' }), false));
assert.equal(disabled.yt2, undefined);
assert.equal(disabled.yt2Id, undefined);
assert.deepEqual(disabled.yt, split.yt);
assert.equal(disabled.ytFailedOver, false);
console.log('PASS channel policy: local channel selection, compatible single conversion, and user-controlled backup promotion');
