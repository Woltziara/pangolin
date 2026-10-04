import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import {parseSubscriptionContent} from './build/SubscriptionParser.js';
const source=readFileSync(new URL('../../entry/src/main/ets/services/DataManagement.ets',import.meta.url),'utf8');
let active=false,deletedKey=false,failFile='',files=new Map();
const outbound={protocol:'trojan',settings:{servers:[{address:'node.example.com',port:443,password:'fixture-only'}]},streamSettings:{security:'tls',tlsSettings:{serverName:'node.example.com',allowInsecure:true}}};
const node={name:'Fixture node',outboundJson:JSON.stringify(outbound)};
function reset(){deletedKey=false;failFile='';files=new Map([
 ['nodes.json',JSON.stringify({v:2,nodes:[{name:node.name,outbound}]})],['subscriptions.json','[]'],['user-rules.json','[]'],['settings.json','{"singleNodeId":"fixture"}'],
 ['outbound.json','private-fixture'],['outbound.json.huks','cipher-fixture'],['node-meta.json','{}'],['applied-policy.json','{}'],['node-latency-test.json','{}'],
 ['xray-config.json','private-runtime'],['geoip.dat','public-db'],['future-private-cache.json','private-future']]);}
const deps={
 './RuntimeJournal':{JOURNAL_FILES:['runtime-journal.jsonl','runtime-journal.1.jsonl','runtime-journal.2.jsonl','runtime-journal.3.jsonl']},
 './UiFeedback':{UI_FEEDBACK_FILE:'ui-feedback.json'},'./SettingsStore':{SETTINGS_FILE:'settings.json'},
 './EventStore':{EVENT_HEAD_FILE:'head.json',EVENT_SNAPSHOT_FILE:'snapshot.json',EVENTS_FILE:'events.json'},
 './HuksSecretStore':{HuksSecretStore:{async removeProtected(){deletedKey=true;files.delete('outbound.json.huks');}}},
 './NodeStore':{NodeStore:{loadNodes(){return [node];},displayName(n){return n.name;},saveNodes(){files.set('nodes.json','{"v":2,"nodes":[]}');}}},
 './SubscriptionStore':{SubscriptionStore:{save(){files.set('subscriptions.json','[]');}}},
 './UserRuleStore':{USER_RULES_FILE:'user-rules.json'},
 './StatusStore':{OUTBOUND_FILE:'outbound.json',StatusStore:{readStatus(){return {vpnCreated:active};},readJsonFile(_ctx,n){return files.get(n)||'';},
  writeText(_ctx,n,v){files.set(n,v);},listNames(){return [...files.keys()];},destExists(p){return files.has(p.split('/').at(-1));},removeFile(_ctx,n){if(n===failFile)throw Error('fixture-denied');files.delete(n);}}}
};
const module={exports:{}};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
 {module,exports:module.exports,Date,console:{error(){}},require(n){if(!(n in deps))throw Error(n);return deps[n];}});
const D=module.exports.DataManagement,ctx={filesDir:'/fixture'};
reset();const path=D.exportConfig(ctx),raw=files.get(path.split('/').at(-1)),doc=JSON.parse(raw),parsed=parseSubscriptionContent(raw);
assert.equal(parsed.nodes.length,1);assert.equal(parsed.nodes[0].name,node.name);assert.equal(JSON.parse(parsed.nodes[0].outboundJson).streamSettings.tlsSettings.allowInsecure,true);
assert(doc.nodes&&doc.subscriptions&&doc.userRules&&doc.settings);
active=true;const count=files.size;await assert.rejects(D.wipeAll(ctx),/断开/);assert.equal(files.size,count);active=false;
reset();await D.clearNodesAndSubscriptions(ctx);assert(deletedKey);assert(!files.has('outbound.json.huks'));assert(!files.has('node-meta.json'));assert(files.has('settings.json'));assert(files.has('user-rules.json'));
reset();await D.wipeAll(ctx);assert.deepEqual([...files.keys()],['geoip.dat']);assert(deletedKey);
reset();files.set('ui-feedback.json','diagnostic');failFile='ui-feedback.json';const result=D.clearLogs(ctx);assert.equal(result.failed,1);assert.equal(result.removed,0);
reset();for(const n of ['runtime-journal.jsonl','runtime-journal.1.jsonl','incident-report-1800000000000.json','diagnostic-report-1800000000001.json','native-stats.json'])files.set(n,'diagnostic');
files.set('incident-report-personal.json','unrelated');const logs=D.clearLogs(ctx);assert.equal(logs.removed,5);assert(files.has('incident-report-personal.json'));assert(files.has('nodes.json'));
console.log('PASS actual data manager: exported nodes re-import, original parameters and metadata preserved, active tunnel blocks wipe, key/envelope/runtime traces cleared, settings retained in node-only delete, full personal wipe and truthful failure count');
