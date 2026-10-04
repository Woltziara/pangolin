import assert from 'node:assert/strict';
import {fixture} from './helpers/controller-fixture.mjs';
import {deferred,flush} from './helpers/ets-loader.mjs';
import {uiMethods} from './helpers/ui-methods.mjs';
let count=0;
function page(f,keep=async()=>true,name='Index'){
 const p=uiMethods(name,name,name==='Index'?['startTunnel','stopTunnel','applyConnection','repairConnection']:['reconnectNow'],{
 ...f.clock.globals(),CONNECTION_CONTROLLER:f.controller,MODE_FULL:'full',PHASE_ERROR:'ERROR',PHASE_STOPPED:'STOPPED',
 RecoveryTrace:{begin(){return '';},finish(){},currentRouteAlreadyFailed(){return false;}},
 BACKGROUND_KEEP_ALIVE:{ensure:keep},BACKGROUND_PROBE_HOST:{start(){},stop(){}},
 UiFeedback:{failure:(_c,_k,e)=>String(e)},isConnectionEstablished:s=>s.phase==='UNPROVEN',
 StatusStore:{readStatus:()=>f.owner()},promptAction:{showToast(){}},router:{back(){}}
 });
 Object.assign(p,{context:{},busy:false,running:true,statusSyncing:false,pageRevision:0,embedded:true,
 reload(){},canStart:()=>true,shortStatus:s=>s.phase,makeHint:()=>'',isConnected:()=>f.owner().vpnCreated,
 refresh(){p.running=f.owner().vpnCreated||f.owner().xrayRunning;}});
 return p;
}
{
 const f=fixture();f.setOwner({phase:'STOPPED',desiredRunning:false,vpnCreated:false,xrayRunning:false,forwarderOk:false});
 const keep=deferred(),p=page(f,()=>keep.promise);p.running=false;
 const start=p.startTunnel();await p.stopTunnel();keep.resolve(true);await start;
 assert(!f.events.some(e=>e.start));assert(!p.busy);count++;
 f.startAction=async w=>f.connectedStart(w);await p.startTunnel();assert(f.events.some(e=>e.start));count++;
}
{
 const f=fixture();f.stopAction=async()=>f.proveStopped();const p=page(f);p.statusSyncing=true;await p.stopTunnel();
 assert(f.events.includes('system-stop'));assert.equal(f.owner().phase,'STOPPED');count++;
}
for(const name of ['Index','Settings','Rules']){
 const f=fixture(),gate=deferred();f.stopAction=async()=>{await gate.promise;f.proveStopped();};f.startAction=async w=>f.connectedStart(w);
 const p=page(f,async()=>true,name),applying=name==='Index'?p.applyConnection():p.reconnectNow();
 await flush();assert(f.events.includes('owner-stop'),name+' reached real owner stop consumer');
 const cancelled=f.controller.stop({});await flush();gate.resolve();await flush();await f.clock.advance(10100);await Promise.all([applying,cancelled]);
 assert(!f.events.some(e=>e.start&&!e.start.parameters.command),name+' late apply must not override new cancel');count++;
}
for(const name of ['Index','Settings','Rules']){
 const f=fixture();f.stopAction=async()=>f.proveStopped();f.startAction=async w=>f.connectedStart(w);const p=page(f,async()=>true,name);
 await(name==='Index'?p.applyConnection():p.reconnectNow());assert(f.events.some(e=>e.start&&!e.start.parameters.command),name+' normal reconnect retained');count++;
}
{
 const f=fixture();f.permission=false;const p=page(f);await p.applyConnection();assert(!f.events.includes('system-stop'));assert(p.operationError.length);count++;
}
{
 const f=fixture();const p=page(f);await p.repairConnection();assert(!f.events.includes('system-stop'));assert(p.operationError.length);count++;
}
console.log(`PASS ${count} real UI methods + full controller scenarios: earliest cancellation, syncing stop, three reconnect entrances, permission gate and no business-only VPN rebuild`);
