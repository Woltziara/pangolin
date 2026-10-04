import assert from 'node:assert/strict';
import {vpnFixture} from './helpers/vpn-fixture.mjs';
import {deferred,flush} from './helpers/ets-loader.mjs';
let count=0;
{
 const f=vpnFixture();
 f.v.onCreate({parameters:{command:'diagnose-connection-status',statusGeneration:'old'}});
 f.v.onRequest({parameters:{command:'stop',generation:'old'}},2);
 await flush(200);
 assert.equal(f.v.status.generation,'');assert.equal(f.v.status.phase,'IDLE');
 assert(!f.events.includes('core-start'));assert(!f.events.includes('vpn-create'));
 assert(!f.files.has('owner-terminal.json'),'replacement owner must never attest old resources');count++;
}
{
 const f=vpnFixture(),w=f.want();f.v.onCreate(w);f.v.onRequest(w,1);await flush(250);
 assert.equal(f.events.filter(e=>e==='core-start').length,1);assert(f.native.tunRunning);assert(f.files.has('connection-layers.json'));
 f.cancel();await flush(150);assert.equal(f.v.status.phase,'STOPPED');
 assert(f.load('net/OwnerTerminal.ets').terminalProven(f.files.get('owner-terminal.json'),'new',0,f.clock.now));count++;
}
{
 const f=vpnFixture(),w=f.want();f.files.set('connection-control.json',JSON.stringify({kind:'stop',generation:'new',intentId:'new'}));
 f.v.onCreate(w);f.v.onRequest(w,1);await flush();assert(!f.events.includes('core-start'));assert(!f.events.includes('vpn-create'));assert.equal(f.v.status.phase,'IDLE');assert(!f.files.has('owner-terminal.json'));count++;
}
{
 const f=vpnFixture(),w=f.want();f.v.onCreate(w);await flush(250);f.native.protectPending=1;
 f.cancel();await f.clock.advance(3000);assert.notEqual(f.v.status.phase,'STOPPED');assert(!f.files.has('owner-terminal.json'));count++;
}
{
 const f=vpnFixture(),w=f.want();f.v.onCreate(w);await flush(250);f.coreStop=()=>false;
 f.cancel();await flush(150);assert.equal(f.v.status.phase,'POISONED');assert(!f.files.has('owner-terminal.json'));assert(!f.events.includes('isolated-owner-exit'),'no unverified process self-termination contract');count++;
}
{
 const f=vpnFixture(),w=f.want();f.v.onCreate(w);await flush(250);f.v.controlIntentId='new';
 const old=f.want('old');f.files.set('connection-control.json',JSON.stringify({kind:'start',generation:'new',intentId:'new'}));
 f.v.onRequest(old,2);await flush();assert.equal(f.v.generation,'new');assert(f.native.xrayRunning);assert.equal(f.events.filter(e=>e==='core-start').length,1);count++;
}
// OS create can resolve after destroy/cancel. No terminal is published while
// that allocation is still pending. Late fd is destroyed by its local owner.
{
 const f=vpnFixture(),gate=deferred();f.create=()=>gate.promise;const w=f.want();f.v.onCreate(w);await flush(200);
 assert(f.events.includes('vpn-create'));f.cancel();await flush(200);
 assert.notEqual(f.v.status.phase,'STOPPED');assert(!f.files.has('owner-terminal.json'));
 gate.resolve(91);await flush(250);assert.equal(f.v.pendingCreates,0);
 assert.equal(f.v.status.phase,'STOPPED');assert(f.files.has('owner-terminal.json'));count++;
}
console.log(`PASS ${count} full production VPN lifecycle cases: start/dedupe/terminal, cancelled Want, pending protect, failed stop quarantine, old Want cannot replace current owner`);
