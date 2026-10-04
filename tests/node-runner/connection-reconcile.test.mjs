import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function load(path,deps={},extra={}){
  const src=readFileSync(new URL('../../entry/src/main/ets/'+path,import.meta.url),'utf8');
  const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports,Date,setTimeout,clearTimeout,
    require(n){if(!(n in deps))throw Error('Unexpected import '+n);return deps[n];},...extra});return module.exports;
}
const statuses=load('net/DataplaneStatus.ets'),health=load('net/ConnectionHealth.ets');
let now=100000,state,writes=0,requests=0,ownerReply=false;
function reset(age=60000){state=Object.assign(new statuses.DataplaneStatus(),{generation:'g',sessionRevision:1,phase:'UNPROVEN',
  at:now-age,desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,nodeName:'preserved'});writes=0;requests=0;}
const deps={
  './ConnectionPolicy':{},
  '@kit.NetworkKit':{vpnExtension:{async startVpnExtensionAbility(w){
    requests++;assert.equal(w.parameters.command,'diagnose-connection-status');assert.equal(w.parameters.statusGeneration,'g');
    if(ownerReply)state={...state,at:now,connectionHealth:'check-failed'};
  }}},'@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
  '../net/DataplaneStatus':statuses,'../net/ConnectionHealth':health,
  '../vpn/VpnConstants':{MODE_FULL:'full',createVpnAbilityWant(){return {bundleName:'test',abilityName:'vpn'};}},
  './HuksSecretStore':{},'./NodeStore':{},'./SettingsStore':{},'./SplitRouter':{},
  './StatusStore':{StatusStore:{readStatus(){return Object.assign(new statuses.DataplaneStatus(),state);},writeStatus(_ctx,s){state={...s};writes++;}}}
};
const Controller=load('services/ConnectionController.ets',deps,{Date:{now:()=>now},
  setTimeout(fn,ms){now+=ms;queueMicrotask(fn);return 1;}}).ConnectionController;
reset();let c=new Controller();c.boundedVpnBearerState=async()=> 'absent';await c.reconcileStatus({});
assert.equal(state.phase,'STOPPED');assert.equal(writes,1);assert.equal(requests,0);
for(const k of ['vpnCreated','tunFdValid','xrayRunning','forwarderOk','desiredRunning'])assert.equal(state[k],false);
assert.equal(state.nodeName,'preserved');
reset(10);c=new Controller();c.boundedVpnBearerState=async()=> 'absent';await c.reconcileStatus({},true);
assert.equal(state.phase,'STOPPED','reopening after an update checks even a fresh old connection record');
reset(10);c=new Controller();c.boundedVpnBearerState=async()=>{throw Error('fresh periodic read should skip');};await c.reconcileStatus({});assert.equal(writes,0);
reset();c=new Controller();let checks=0;c.boundedVpnBearerState=async()=>{if(++checks===2)state={...state,generation:'new',at:now};return 'absent';};
await c.reconcileStatus({});assert.equal(state.generation,'new');assert.equal(writes,0,'never overwrite a racing new session');
reset();ownerReply=true;c=new Controller();c.boundedVpnBearerState=async()=> 'present';await c.reconcileStatus({});
assert.equal(requests,1);assert.equal(writes,0);assert(health.isConnectionEstablished(state,now));assert.equal(state.connectionHealth,'check-failed');
reset();ownerReply=false;c=new Controller();c.boundedVpnBearerState=async()=> 'unknown';
await assert.rejects(c.reconcileStatus({}),/connection-owner-not-responding/);assert.equal(writes,0,'unknown system state cannot fabricate STOPPED');
console.log('PASS actual reconciliation: stale and post-update records, double system absence, concurrent-session protection, live owner refresh independent of failed health, bounded unresponsive service');
