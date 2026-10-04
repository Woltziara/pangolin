import assert from 'node:assert/strict';
import { uiMethods } from './helpers/ui-methods.mjs';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

function applyFixture(bearer) {
  const calls = []; let active = 0; let stopped = false;
  const page = uiMethods('Index', 'Index', ['applyConnection'], {
    PHASE_STOPPED: 'STOPPED',
    CONNECTION_CONTROLLER: {
      beginStartIntent() { calls.push('intent'); return ++active; },
      isStartIntentLive(epoch) { return epoch === active; },
      async preflight() { calls.push('preflight'); },
      async reconcileStatus() { calls.push('reconcile'); return { phase: 'STOP_UNCONFIRMED' }; },
      async recoverStoppedOwner() { calls.push('prove-owner-exit'); ++active; stopped = true; return { phase: 'STOPPED' }; }
    },
    StatusStore: { readStrictText() { return JSON.stringify({ bearer }); } },
    UiFeedback: { failure(_ctx, _action, error) { return error.message; } }
  });
  Object.assign(page, { context: {}, busy: false, running: true, needsSystemAction: true, pageRevision: 0,
    refresh() { if (stopped) this.running = false; },
    async stopTunnel() { calls.push('stop-old'); },
    async startTunnel(epoch) { assert.equal(epoch, active); calls.push('start-selection'); }
  });
  return { page, calls };
}
{
  const f = applyFixture('absent'); await f.page.applyConnection();
  assert.deepEqual(f.calls, ['intent', 'preflight', 'reconcile', 'prove-owner-exit', 'intent', 'start-selection']);
  assert.equal(f.page.busy, false);
}
{
  const f = applyFixture('present'); await f.page.applyConnection();
  assert.deepEqual(f.calls, ['intent', 'preflight', 'reconcile']);
  assert.match(f.page.operationError, /尚未释放/);
}
function autoFixture(phase) {
  const calls = []; const plane = { phase };
  const page = uiMethods('Index', 'Index', ['maybeAutoConnect'], {
    autoConnectAttempted: false, PHASE_IDLE: 'IDLE', PHASE_STOPPED: 'STOPPED', PHASE_ERROR: 'ERROR',
    SettingsStore: { load() { return { autoConnectOnLaunch: true }; } },
    StatusStore: { readStatus() { return plane; } },
    AppliedPolicy: { savedSelectionChanged() { return true; } },
    UiFeedback: { failure() { return 'failed'; } }
  });
  Object.assign(page, { context: {}, busy: false, statusSyncing: false, running: true,
    needsSystemAction: false, configPending: false,
    async startTunnel() { calls.push('connect'); }, async applyConnection() { calls.push('apply-selection'); }
  });
  return { page, plane, calls };
}
{
  const f = autoFixture('FORWARDER_RUNNING'); f.page.maybeAutoConnect();
  f.plane.phase = 'STOPPED'; f.page.running = false; f.page.maybeAutoConnect(); f.page.maybeAutoConnect();
  assert.deepEqual(f.calls, ['connect'], 'waiting for status must not consume the launch attempt');
}
{
  const f = autoFixture('STOP_UNCONFIRMED');
  // The display can still be stale. The persisted applied-policy receipt is
  // the independent source for whether a new selection must be applied.
  f.page.needsSystemAction = false; f.page.configPending = false;
  f.page.maybeAutoConnect(); f.page.maybeAutoConnect();
  assert.deepEqual(f.calls, ['apply-selection']);
}
{
  let raw = JSON.stringify({ generation: 'old', payloadDigest: 'old-digest', channelMode: 'single', intendedSingleNodeId: 'old-node' });
  const settings = { singleNodeId: 'new-node' };
  const source = readFileSync(new URL('../../entry/src/main/ets/services/AppliedPolicy.ets', import.meta.url), 'utf8');
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, { module, exports: module.exports, Date, require(id) {
    if (id === './StatusStore') return { StatusStore: { readJsonFile: () => raw, readStatus: () => ({ at: 1, xrayRunning: false, vpnCreated: false }) } };
    if (id === './SettingsStore') return { SettingsStore: { load: () => settings } };
    if (id === './ConnectionPolicy') return { CONNECTION_POLICY: { mode: () => 'single' } };
    return {};
  } });
  const policy = module.exports.AppliedPolicy;
  assert.equal(policy.current({}), null, 'expired owner does not produce a current running receipt');
  assert.equal(policy.savedSelectionChanged({}), true, 'saved intent still identifies the explicit new choice');
  settings.singleNodeId = 'old-node'; assert.equal(policy.savedSelectionChanged({}), false);
  raw = '{}'; assert.equal(policy.savedSelectionChanged({}), false, 'missing commit cannot authorize replacement');
}
console.log('PASS selected route applies only after owner-exit proof; stale receipt preserves intent without claiming live state; auto-connect preserves its eligible attempt');
