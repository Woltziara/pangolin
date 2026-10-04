import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const path = fileURLToPath(new URL('../../entry/src/main/ets/services/BackgroundProbeHost.ets', import.meta.url));
const source = readFileSync(path, 'utf8');
const js = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

const files = new Map();
let desiredRunning = false;
let ensureResult = true;
let ensureCalls = 0;
let starts = 0;
let stops = 0;
const module = { exports: {} };
vm.runInNewContext(js, {
  module,
  exports: module.exports,
  Promise,
  require(name) {
    if (name === '@kit.AbilityKit') return {};
    if (name === './BackgroundKeepAlive') return {
      BACKGROUND_KEEP_ALIVE: {
        async ensure() { ensureCalls += 1; return ensureResult; },
        async stop() {}
      }
    };
    if (name === './ProbeSelfCheck') return {
      PROBE_SELF_CHECK: {
        startLoop() { starts += 1; },
        stopLoop() { stops += 1; }
      }
    };
    if (name === './StatusStore') return {
      StatusStore: {
        readStatus() { return { desiredRunning, phase: desiredRunning ? 'UNPROVEN' : 'STOPPED' }; },
        writeText(_context, key, value) { files.set(key, value); }
      }
    };
    throw new Error(`unexpected import ${name}`);
  }
});

const host = new module.exports.BackgroundProbeHost();
const ctx = {};

host.start(ctx, 'EntryAbility.onCreate');
await Promise.resolve();
assert.equal(ensureCalls, 0, 'a stopped app launch must not create background work');
assert.equal(starts, 0);

host.start(ctx, 'Index.startTunnel');
await Promise.resolve();
await Promise.resolve();
assert.equal(ensureCalls, 1);
assert.equal(starts, 1, 'a successful user start must arm the receipt loop');

desiredRunning = true;
host.start(ctx, 'EntryAbility.onForeground');
await Promise.resolve();
await Promise.resolve();
assert.equal(starts, 2, 'host delegates idempotence to ProbeSelfCheck.startLoop');

ensureResult = false;
host.start(ctx, 'EntryAbility.onBackground');
await Promise.resolve();
await Promise.resolve();
assert.ok(stops >= 1, 'keep-alive failure must stop the probe loop');
assert.ok(files.has('background-keepalive.json'));

host.stop(ctx, 'test');
assert.ok(stops >= 2, 'explicit stop must stop the probe loop');
console.log('background-probe-host: start/stop wiring passed');
