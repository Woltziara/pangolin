import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { nodeSpeedHint } = require('./build/NodeSpeedHint.js');
const samples = [{ id: 'a', label: '美国 US1', milliseconds: 80 },
  { id: 'b', label: '美国 US2', milliseconds: 30 }, { id: 'c', label: '失败节点', milliseconds: -1 }];
assert.equal(nodeSpeedHint('a', '美国', samples, true, 'measured').recommendedId, 'b');
assert.equal(nodeSpeedHint('a', '美国', samples, false, 'running').recommendedId, '');
assert.equal(nodeSpeedHint('b', '美国', samples, true, 'measured').recommendedId, '');
assert.equal(nodeSpeedHint('a', '美国', samples, true, 'connection-changed').recommendedId, '');
assert.equal(nodeSpeedHint('a', '美国', [{...samples[0],milliseconds:-1}], true, 'measured').recommendedId, '');
assert.match(nodeSpeedHint('c', '美国', samples, true, 'measured').current, /未连通/);
assert.equal(nodeSpeedHint('a', '美国', [samples[0],{...samples[1],milliseconds:80}], true, 'measured').recommendedId, '');

// Execute the actual page methods, not a parallel simulation of click behavior.
const source = readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8').replace('struct Index {','class Index {');
const ast = ts.createSourceFile('Index.ts', source, ts.ScriptTarget.Latest, true);
const cls = ast.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'Index');
const names = ['refreshNodeSpeed','useFasterNode','selectRole','applyConnection','shortName','testSelectedNode'];
const methods = names.map(name => cls.members.find(n => n.name?.getText(ast) === name).getText(ast)).join('\n');
let now = 100000, raw = '', updated = 0, startedTests = [];
const context = { Date: { now: () => now }, nodeSpeedHint, NodeSpeedEntry: class {}, NODE_LATENCY_FILE: 'node-latency-test.json',
  StatusStore: { readText: () => raw }, NodeStore: { displayName: n => n.name },
  SettingsStore: { update(ctx, fn) { updated++; fn(ctx.settings); } },
  CONNECTION_CONTROLLER: { beginStartIntent: () => 1, isStartIntentLive: () => true },
  NODE_LATENCY_TEST: { async begin(ctx, id) { startedTests.push(id); return 'run'; } }
};
vm.createContext(context);
vm.runInContext(ts.transpileModule(`class UI { ${methods} } globalThis.UI = UI;`,{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);
function page(running = false) {
  now = 100000;
  const ui = new context.UI();
  const settings = { singleNodeId:'a',failoverEnabled:false };
  Object.assign(ui,{settings,context:{settings},configuredNodes:samples.map(s=>({id:s.id,name:s.label,region:'美国'})),
    dualChannel:false,busy:false,statusSyncing:false,running,nodeSpeedRunning:false,nodeSpeedSelectedId:'a',
    nodeSpeedStartedAt:now,nodeSpeedRunId:'run',nodeSpeedText:'',nodeSpeedTip:'',nodeSpeedRecommendedId:'',pageRevision:0,
    refresh(){},events:[],async stopTunnel(){this.events.push('stop');this.running=false;},
    async startTunnel(){this.events.push('start');this.running=true;}});
  raw = JSON.stringify({runId:'run',region:'美国',samples,complete:true,outcome:'measured'});
  ui.nodeSpeedRunning = true; ui.refreshNodeSpeed();
  return ui;
}
let ui = page(false);
assert.equal(ui.nodeSpeedRecommendedId,'b'); await ui.useFasterNode();
assert.equal(ui.settings.singleNodeId,'b'); assert.equal(ui.events.length,0,'offline selection must not start VPN');
ui = page(true); await ui.useFasterNode();
assert.equal(ui.settings.singleNodeId,'b'); assert.deepEqual(ui.events,['stop','start']); assert.equal(ui.settings.failoverEnabled,false);
ui = page(); ui.settings.singleNodeId='c'; const before = updated; await ui.useFasterNode(); assert.equal(updated,before,'old recommendation cannot replace a newly selected node');
ui = page(); now += 95000; ui.refreshNodeSpeed(); assert.equal(ui.nodeSpeedRecommendedId,'b','finished result is not a running-test timeout');
now += 30000; await ui.useFasterNode(); assert.equal(ui.settings.singleNodeId,'a'); assert.match(ui.nodeSpeedText,/过期/);
ui = page(); raw = JSON.stringify({runId:'other',samples,complete:true,outcome:'measured'}); await ui.useFasterNode(); assert.equal(ui.settings.singleNodeId,'a');
ui = page(); await ui.testSelectedNode(); assert.equal(startedTests.at(-1),'a','home dispatch must scope the selected node, not all regions');
console.log('PASS home node speed: selected TCP result, same-run recommendation, ties/errors/expiry, real one-tap selection, connected stop/start and offline no-start');
