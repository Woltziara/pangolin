import assert from 'node:assert/strict';
import {fixture} from './helpers/controller-fixture.mjs';
import {deferred,flush} from './helpers/ets-loader.mjs';
let count=0;
// Actual stopLocked observes absent OS VPN but has no native proof.
{
 const f=fixture();const before=f.owner();const run=f.controller.stop({});await f.clock.advance(10100);const result=await run;
 assert.equal(result.phase,'STOP_UNCONFIRMED');assert.equal(result.xrayRunning,true);assert.deepEqual(f.owner(),before);
 assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'unconfirmed');count++;
}
// Actual owner proof and bearer absence jointly permit stop. No UI status write.
{
 const f=fixture();f.stopAction=async()=>{f.proveStopped();};const result=await f.controller.stop({});
 assert.equal(result.phase,'STOPPED');assert.equal(f.controller.platformUncertain,false);count++;
}
// A never-settling OS stop call cannot hang cancellation or turn into proof.
{
 const f=fixture();f.stopAction=async()=>f.proveStopped();f.systemStopAction=()=>deferred().promise;const p=f.controller.stop({});await f.clock.advance(10100);assert.equal((await p).phase,'STOP_UNCONFIRMED');
 assert.equal(f.controller.platformCalls,1);assert.equal((await f.controller.start({})).phase,'STOP_UNCONFIRMED');count++;
}
// Future or old-generation proofs cannot authorize reuse.
{
 const f=fixture();f.files.set('owner-terminal.json',JSON.stringify({generation:'unrelated',writer:'vpn-owner',at:f.clock.now+100000,resourcesReleased:true}));
 const p=f.controller.stop({});await f.clock.advance(10100);assert.equal((await p).phase,'STOP_UNCONFIRMED');count++;
}
// Application-only failures do not reach either stop or selection.
{
 const f=fixture();await assert.rejects(f.controller.rebuild({}),/no-snapshot/);assert(!f.events.includes('system-stop'));assert.equal(f.prepared,0);count++;
}
function allow(f){f.files.set('connection-layers.json',JSON.stringify({generation:'old',revision:1,at:f.clock.now,rebuildAllowed:true,reason:'tun-stalled'}));}
// Missing/changed catalog snapshot fails before breaking the original connection.
{
 const f=fixture();allow(f);f.snapshotRead=()=>{throw Error('原节点缺失');};await assert.rejects(f.controller.rebuild({}),/原节点缺失/);assert(!f.events.includes('system-stop'));count++;
}
// Full controller rebuild chain uses the same snapshot; zero prepare/selection.
{
 const f=fixture();allow(f);const ids=[];f.snapshotRead=id=>{ids.push(id);return {id:'old-1',generation:'old',revision:1,payloadDigest:'abc12345'};};
 f.stopAction=async()=>f.proveStopped();f.startAction=async want=>f.connectedStart(want);
 const result=await f.controller.rebuild({});assert.equal(result.phase,'UNPROVEN');assert.equal(f.prepared,0);
 assert.deepEqual(ids,['','old-1']);const start=f.events.find(e=>e.start&&!e.start.parameters.command)?.start;assert.equal(start.parameters.recoverySnapshotId,'old-1');assert.equal(start.parameters.controlIntentId,start.parameters.generation);count++;
}
// Cancel while pre-stop snapshot read is delayed: absolutely no stop/start.
{
 const f=fixture();allow(f);const gate=deferred();f.snapshotRead=()=>gate.promise;
 const p=f.controller.rebuild({});await flush();f.controller.requestCancel();gate.resolve({id:'old-1',generation:'old',revision:1,payloadDigest:'abc12345'});await p;
 assert(!f.events.includes('system-stop'));assert(!f.events.some(e=>e.start));count++;
}
// Actual owner admission fence rejects a late OS start once UI has cancelled.
{
 const f=fixture(),{controlAllowsStart}=f.load('net/OwnerTerminal.ets');
 const start=JSON.stringify({kind:'start',intentId:'new-1',generation:'new-1'}),stop=JSON.stringify({kind:'stop',intentId:'new-1',generation:'new-1'});
 assert(controlAllowsStart(start,'new-1','new-1'));assert(!controlAllowsStart(stop,'new-1','new-1'));assert(!controlAllowsStart(start,'new-2','new-2'));count++;
}
// Persistent unresolved system operation survives UI recreation and cannot
// be cleared by the new UI's empty in-memory counters, even with OS absence.
{
 const f=fixture();f.files.set('connection-control.json',JSON.stringify({kind:'start',state:'unconfirmed',generation:'late',requestedAt:f.clock.now,at:f.clock.now,platformPending:true}));
 f.setOwner({phase:'STOPPED',desiredRunning:false,vpnCreated:false,xrayRunning:false,forwarderOk:false});
 assert.equal((await f.controller.start({})).phase,'STOP_UNCONFIRMED');
 f.stopAction=async()=>f.proveStopped();const p=f.controller.stop({});await f.clock.advance(10100);
 assert.equal((await p).phase,'STOP_UNCONFIRMED');assert(f.controller.externalMutationUnconfirmed);count++;
}
// The homepage's same-boot owner-exit path restarts the committed session,
// rather than preparing or selecting a node from today's catalog.
{
 const f=fixture();const ids=[];f.snapshotRead=id=>{ids.push(id);return {id:'old-1',generation:'old',revision:1,payloadDigest:'abc12345'};};
 f.controller.recoverStoppedOwner=async()=>{f.proveStopped();return f.owner();};
 f.startAction=async want=>f.connectedStart(want);
 const result=await f.controller.resumeAfterOwnerExit({});assert.equal(result.phase,'UNPROVEN');
 assert.deepEqual(ids,['','old-1']);assert.equal(f.prepared,0);
 const start=f.events.find(e=>e.start&&!e.start.parameters.command)?.start;
 assert.equal(start.parameters.recoverySnapshotId,'old-1');count++;
}
// A surviving VPN owner with no system bearer uses verified owner-stop and
// pinned rebuild; a vanished owner uses the independent disappearance proof.
{
 const f=fixture(),calls=[];
 f.controller.rebuild=async()=>{calls.push('rebuild');return f.owner();};
 f.controller.resumeAfterOwnerExit=async(_context,pid=-1)=>{calls.push(`owner-exit:${pid}`);return f.owner();};
 f.startAction=async want=>{
   if(want.parameters?.command==='diagnose-process-visibility')
     f.files.set('owner-visibility.json',JSON.stringify({nonce:want.parameters.recoveryNonce,pid:11,
       empty:f.emptyVpn??false,generation:f.owner().generation,ownerInstance:f.owner().ownerInstance}));
 };
 f.processRows.push({pid:11,uid:20,processName:'com.oscarwoltz.tongdao:vpn',bundleNames:['com.oscarwoltz.tongdao']});
 await f.controller.resumeWithAbsentBearer({});assert.deepEqual(calls,['rebuild']);
 f.emptyVpn=true;await f.controller.resumeWithAbsentBearer({});assert.deepEqual(calls,['rebuild','owner-exit:11']);
 f.processRows.pop();await f.controller.resumeWithAbsentBearer({});assert.deepEqual(calls,['rebuild','owner-exit:11','owner-exit:-1']);
 f.processRows.push({pid:12,uid:20,processName:'unknown-process',bundleNames:['com.oscarwoltz.tongdao']});
 await assert.rejects(f.controller.resumeWithAbsentBearer({}),/身份未确认/);
 assert.deepEqual(calls,['rebuild','owner-exit:11','owner-exit:-1']);count++;
}
console.log(`PASS ${count} production controller/owner scenarios: OS-only false-stop, real proof, hung API deadline, stale proof, business isolation, snapshot preflight, pinned rebuild, owner-exit resume, cancellation, late Want fence`);
