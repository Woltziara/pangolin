import assert from 'node:assert/strict';
import {fixture} from './helpers/controller-fixture.mjs';
let count=0;
{
 const f=fixture();const original=f.owner();
 const result=await f.controller.reconcileStatus({},true);
 assert.equal(result.phase,'STOP_UNCONFIRMED','fresh old heartbeat cannot override live OS absence');
 assert.deepEqual(f.owner(),original,'absence must not invent released native resources');
 assert(result.xrayRunning);assert(!f.events.some(e=>e.start||e==='system-stop'));
 f.setOwner({at:f.clock.now+1});assert.equal(f.load('services/StatusStore.ets').StatusStore.readStatus().phase,'UNPROVEN','later owner status supersedes old observation');
 count++;
}
{
 const f=fixture();f.setOwner({phase:'VPN_CREATED'});await f.controller.reconcileStatus({},true);
 assert.equal(f.load('services/StatusStore.ets').StatusStore.readStatus().phase,'VPN_CREATED','creation in progress is not a missing established bearer');count++;
}
// Legacy ticket consistency replay, not proof of the historical interrupt. An unrecorded platform call cannot be ordered by a fresh stop.
{
 const f=fixture();f.proveStopped();f.setOwner({at:f.clock.now-30000});
 f.files.set('connection-control.json',JSON.stringify({kind:'stop',state:'pending',generation:'old',requestedAt:f.clock.now-100,platformPending:true}));
 const result=await f.controller.reconcileStatus({},true);
 assert.equal(result.phase,'STOP_UNCONFIRMED');
 assert(!f.events.includes('system-stop'),'inspection cannot stop an ability');
 const stop=f.controller.stop({});await f.clock.advance(10100);
 assert.equal((await stop).phase,'STOP_UNCONFIRMED');
 assert.equal(JSON.parse(f.files.get('connection-control.json')).inheritedUnresolved,true);count++;
}
// Supersedes the old OS-absence=>native-false assertion: UI must preserve actual
// owner resources. This uses the entire production controller, not AST mocks.
{
 const f=fixture();f.setOwner({at:f.clock.now-30000});const original=f.owner();
 const p=f.controller.reconcileStatus({});await f.clock.advance(14000);const result=await p;
 assert.equal(result.phase,'STOP_UNCONFIRMED');assert(result.xrayRunning);assert.deepEqual(f.owner(),original);count++;
 assert(!f.events.some(e=>e.start),'absent OS VPN must not launch an empty diagnostic extension');
}
{
 const f=fixture();f.setOwner({at:f.clock.now-30000});f.stopAction=async()=>f.proveStopped();
 const p=f.controller.reconcileStatus({},true);await f.clock.advance(4000);
 assert.equal((await p).phase,'STOP_UNCONFIRMED');assert(!f.events.includes('owner-stop'));count++;
}
{
 const f=fixture();f.setOwner({at:f.clock.now-100,phase:'STOPPED',desiredRunning:false,vpnCreated:false,xrayRunning:false,forwarderOk:false});
 const original=f.owner();assert.deepEqual(await f.controller.reconcileStatus({},true),original);count++;
}
{
 const f=fixture();await f.controller.reconcileStatus({});assert.equal(f.events.length,0);count++;
}
{
 const f=fixture();f.bearer='present';f.setOwner({at:f.clock.now-30000});f.startAction=async()=>f.setOwner({generation:'new',at:f.clock.now});
 const result=await f.controller.reconcileStatus({});assert.equal(result.generation,'new');assert.equal(f.owner().generation,'new');count++;
}
{
 const f=fixture();f.bearer='present';f.setOwner({at:f.clock.now-30000});f.startAction=async()=>f.setOwner({at:f.clock.now,connectionHealth:'check-failed'});
 const result=await f.controller.reconcileStatus({});assert.equal(result.phase,'UNPROVEN');assert.equal(result.connectionHealth,'check-failed');count++;
}
console.log(`PASS ${count} production reconciliation scenarios: preserve resource facts, old stopped migration, fresh skip, racing owner and live-owner refresh`);
