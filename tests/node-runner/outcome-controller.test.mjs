import assert from 'node:assert/strict';
import {fixture} from './helpers/controller-fixture.mjs';
import {deferred,flush} from './helpers/ets-loader.mjs';
let count=0;
{
 const f=fixture(),d=deferred();f.stopAction=async()=>f.proveStopped();f.systemStopAction=()=>d.promise;
 const a=f.controller.stop({}),b=f.controller.stop({});await f.clock.advance(10200);
 assert.equal((await a).phase,'STOP_UNCONFIRMED');assert.equal((await b).phase,'STOP_UNCONFIRMED');
 assert.equal(f.events.filter(e=>e==='system-stop').length,1);assert(f.controller.operations.unresolvedStop({}));
 d.resolve();await flush(200);assert.equal(f.controller.operations.unresolvedStop({}),false);
 assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'confirmed');
 assert.equal(f.controller.platformUncertain,false);count++;
}
{
 const f=fixture(),d=deferred();f.stopAction=async()=>f.proveStopped();f.systemStopAction=()=>d.promise;
 const first=f.controller.stop({});await f.clock.advance(10100);await first;
 const second=f.controller.stop({});await f.clock.advance(10100);await second;
 assert.equal(f.events.filter(e=>e==='system-stop').length,1,'cannot stack unknown whole-ability stops');
 d.resolve();await flush(100);count++;
}
{
 const f=fixture();f.stopAction=async()=>f.proveStopped();await f.controller.stop({});
 const control=JSON.parse(f.files.get('connection-control.json'));control.state='unconfirmed';control.platformPending=true;
 f.files.set('connection-control.json',JSON.stringify(control));
 const Recreated=f.load('services/ConnectionController.ets').ConnectionController;
 const next=new Recreated();await next.reconcileStatus({},true);
 assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'confirmed','actual completed ledger survives controller recreation');count++;
}
{
 const f=fixture();f.bootId='boot-new';f.files.set('connection-control.json',JSON.stringify({kind:'stop',state:'unconfirmed',generation:'old',bootId:'boot-old',platformPending:true}));
 f.files.set('platform-operations-v2.json',JSON.stringify({schema:2,operations:[{id:'op',operationId:'control',kind:'system-stop',generation:'old',controller:'dead',state:'pending',startedAt:f.clock.now-5000,bootId:'boot-old'}]}));
 const before=f.owner();await f.controller.reconcileStatus({},true);
 assert.equal(f.load('net/OwnerTerminal.ets').projectControl(f.owner(),f.files.get('connection-control.json'),' ',f.files.get('system-observation.json')).phase,'STOPPED');
 assert.deepEqual(f.owner(),before,'reboot is a separate proof, not a manufactured owner terminal');assert(!f.files.has('owner-terminal.json'));count++;
}
{
 const f=fixture();f.files.set('platform-operations-v2.json','{"schema":2,"operations":[{}]}');
 assert.equal((await f.controller.start({})).phase,'ERROR');assert(!f.events.some(e=>e.start));count++;
}
{
 const f=fixture();f.snapshotRead=()=>({id:'old-1',generation:'old',revision:1,payloadDigest:'abc12345'});
 f.stopAction=async()=>f.proveStopped();f.startAction=async w=>f.connectedStart(w);
 assert.equal((await f.controller.rebuild({})).phase,'UNPROVEN');assert.equal(f.prepared,0);count++;
}
{
 const f=fixture(),{projectControl}=f.load('net/OwnerTerminal.ets');
 const live=f.owner();const a=projectControl({...live},JSON.stringify({kind:'stop',state:'pending',generation:'A',requestedAt:f.clock.now}),'');
 assert.equal(a.phase,live.phase);assert.equal(a.desiredRunning,true);
 const empty={...live,desiredRunning:false,vpnCreated:false,xrayRunning:false,forwarderOk:false,phase:'STOPPED'};
 const b=projectControl(empty,JSON.stringify({kind:'stop',state:'pending',generation:'not-yet-admitted',requestedAt:f.clock.now}),'');
 assert.equal(b.phase,'STOP_UNCONFIRMED','outstanding intent must not look disconnected simply because owner has not published');count++;
}
console.log(`PASS ${count} production controller outcome cases; OS behavior is substituted, not device proof`);
// A legacy pending whole-ability call has no lifecycle contract/ledger. A new stop
// cannot manufacture an ordering barrier; the inherited uncertainty survives UI restart.
{
 const f=fixture();f.proveStopped();f.files.set('connection-control.json',JSON.stringify({kind:'stop',state:'pending',generation:'old',requestedAt:f.clock.now,platformPending:true}));
 const stop=f.controller.stop({});await f.clock.advance(10100);assert.equal((await stop).phase,'STOP_UNCONFIRMED');
 assert.equal(JSON.parse(f.files.get('connection-control.json')).inheritedUnresolved,true);
 const C=f.load('services/ConnectionController.ets').ConnectionController;await new C().reconcileStatus({},true);
 assert.notEqual(JSON.parse(f.files.get('connection-control.json')).state,'confirmed');
}
console.log('PASS inherited legacy platform-call uncertainty is not cleared by a replacement controller');
