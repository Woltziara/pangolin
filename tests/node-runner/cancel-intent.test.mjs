import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

function methods(path, name, wanted) {
  const source = readFileSync(path, 'utf8').replace('struct Index {', 'class Index {');
  const ast = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true);
  const cls = ast.statements.find((n) => ts.isClassDeclaration(n) && n.name?.text === name);
  if (!cls) {
    throw new Error('class not found ' + name);
  }
  return wanted.map((k) => {
    const m = cls.members.find((n) => n.name?.getText(ast) === k);
    if (!m) {
      throw new Error(k);
    }
    return m.getText(ast);
  }).join('\n');
}

const root = new URL('../../', import.meta.url);
const ctl = methods(fileURLToPath(new URL('entry/src/main/ets/services/ConnectionController.ets', root)),
  'ConnectionController',
  ['enqueueStatus', 'beginStartIntent', 'isStartIntentLive', 'requestCancel', 'startIntentExpired', 'start', 'stop',
    'startLocked', 'errorMessage']);
const ui = methods(fileURLToPath(new URL('entry/src/main/ets/pages/Index.ets', root)), 'Index',
  ['startTunnel', 'stopTunnel', 'applyConnection', 'repairConnection']);
const events = [];
let release;
const keep = new Promise((resolve) => {
  release = resolve;
});
const ctx = {
  console, events, Date, MODE_FULL: 'full', PHASE_ERROR: 'ERROR', PHASE_STOPPED: 'STOPPED',
  LOG_DOMAIN: 0, LOG_TAG: 'test',
  vpnExtension: {
    stopVpnExtensionAbility: async () => events.push('system-stop'),
    startVpnExtensionAbility: async () => events.push('system-start')
  },
  createVpnAbilityWant: () => ({}),
  createStartWant: () => ({}),
  hilog: { warn() {}, error() {}, info() {} },
  BACKGROUND_KEEP_ALIVE: { ensure: () => keep },
  BACKGROUND_PROBE_HOST: { start() {}, stop() {} },
  UiFeedback: { failure: () => '' }
};
vm.createContext(ctx);
const code = `class Controller { chain=Promise.resolve(); cancelRequested=false; startEpoch=0; ${ctl} }
class UI { ${ui} }
globalThis.C=Controller;globalThis.U=UI;`;
vm.runInContext(ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, ctx);
const c = new ctx.C();
ctx.CONNECTION_CONTROLLER = c;
c.prepareCore = async () => ({ phase: 'PREPARED' });
c.waitPhase = async () => ({ phase: 'CONNECTED' });
c.stopLocked = async () => {
  events.push('stop-complete');
  return { phase: 'STOPPED' };
};
const u = new ctx.U();
Object.assign(u, {
  context: {}, busy: false, statusSyncing: false, running: false,
  canStart: () => true, refresh() {}, shortStatus: () => '', makeHint: () => ''
});
const oldStart = u.startTunnel();
await u.stopTunnel();
release(true);
await oldStart;
assert.equal(events.includes('system-start'), false, 'late start must not start VPN after stop');
assert.ok(events.indexOf('stop-complete') >= 0);
u.statusSyncing = true;
events.length = 0;
await u.stopTunnel();
assert.ok(events.indexOf('system-stop') >= 0, 'statusSyncing must not swallow stop');
console.log(JSON.stringify({ events, oldStartAcceptedAfterStop: false }));
console.log('PASS actual UI/Controller: cancel during earliest keep-alive does not resurrect start');

u.statusSyncing = false;
u.busy = false;
u.running = false;
events.length = 0;
await u.startTunnel();
assert.ok(events.includes('system-start'), 'fresh start after cancel still connects');
console.log('PASS actual UI/Controller: new start after cancel is accepted');

function makeApplyFixture() {
  const local = [];
  let releaseStop;
  const stopGate = new Promise((resolve) => { releaseStop = resolve; });
  let stops = 0;
  const applyCtx = {
    console, events: local, Date, MODE_FULL: 'full', PHASE_ERROR: 'ERROR', PHASE_STOPPED: 'STOPPED',
    LOG_DOMAIN: 0, LOG_TAG: 'test',
    vpnExtension: {
      stopVpnExtensionAbility: async () => local.push('system-stop'),
      startVpnExtensionAbility: async () => local.push('system-start')
    },
    createVpnAbilityWant: () => ({}),
    createStartWant: () => ({}),
    hilog: { warn() {}, error() {}, info() {} },
    BACKGROUND_KEEP_ALIVE: { ensure: async () => true },
    BACKGROUND_PROBE_HOST: { start() {}, stop() {} },
    UiFeedback: { failure: () => '' }
  };
  vm.createContext(applyCtx);
  vm.runInContext(ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, applyCtx);
  const controller = new applyCtx.C();
  applyCtx.CONNECTION_CONTROLLER = controller;
  controller.prepareCore = async () => ({ phase: 'PREPARED' });
  controller.waitPhase = async () => ({ phase: 'CONNECTED' });
  controller.stopLocked = async () => {
    const n = ++stops;
    local.push('stop-locked-' + n);
    if (n === 1) {
      await stopGate;
    }
    local.push('stop-done-' + n);
    return { phase: 'STOPPED' };
  };
  const page = new applyCtx.U();
  Object.assign(page, {
    context: {}, busy: false, statusSyncing: false, running: true, configPending: true, pageRevision: 0,
    canStart: () => true, refresh() { page.running = false; }, shortStatus: () => '', makeHint: () => ''
  });
  return { page, local, releaseStop, controller };
}

{
  const fx = makeApplyFixture();
  const applying = fx.page.applyConnection();
  for (let i = 0; i < 20 && !fx.local.includes('stop-locked-1'); i++) {
    await Promise.resolve();
  }
  const cancelling = fx.page.stopTunnel();
  for (let i = 0; i < 6; i++) {
    await Promise.resolve();
  }
  fx.local.push('user-cancel-issued');
  fx.releaseStop();
  await Promise.all([applying, cancelling]);
  const late = fx.local.indexOf('system-start') > fx.local.indexOf('user-cancel-issued');
  console.log(JSON.stringify({ events: fx.local, oldApplyStartsAfterNewCancel: late }));
  assert.equal(late, false, 'apply/reconnect must not start after a later user cancel');
  assert.equal(fx.local.includes('system-start'), false);
}
console.log('PASS actual applyConnection: later cancel is not overwritten by reconnect start');

{
  const fx = makeApplyFixture();
  fx.releaseStop();
  await fx.page.applyConnection();
  assert.ok(fx.local.includes('system-start'), 'reconnect without cancel still starts');
}
console.log('PASS actual applyConnection: reconnect without cancel still starts');

{
  const fx = makeApplyFixture();
  fx.releaseStop();
  await fx.page.repairConnection();
  assert.ok(fx.local.includes('system-stop'), 'repair must use the verified stop path');
  assert.ok(fx.local.includes('system-start'), 'repair must rebuild the connection');
}
console.log('PASS repairConnection reuses the verified reconnect chain');

{
  const settingsText = readFileSync(fileURLToPath(new URL('entry/src/main/ets/pages/Settings.ets', root)), 'utf8');
  const rulesText = readFileSync(fileURLToPath(new URL('entry/src/main/ets/pages/Rules.ets', root)), 'utf8');
  const indexText = readFileSync(fileURLToPath(new URL('entry/src/main/ets/pages/Index.ets', root)), 'utf8');
  for (const [name, text, marker] of [
    ['Index', indexText, 'applyConnection'],
    ['Settings', settingsText, 'reconnectNow'],
    ['Rules', rulesText, 'reconnectNow']
  ]) {
    const body = text.slice(text.indexOf(marker));
    const begin = body.indexOf('beginStartIntent');
    const stop = body.indexOf('stop(') >= 0 ? body.indexOf('stop(') : body.indexOf('stopTunnel(');
    assert.ok(begin >= 0 && stop >= 0 && begin < stop, name + ' must take intent before first stop await');
    assert.match(body.slice(0, 1200), /stop(?:Tunnel)?\([^\)]*false/);
  }
}
console.log('PASS Settings/Rules/Index reconnect consume the same pre-await intent');
