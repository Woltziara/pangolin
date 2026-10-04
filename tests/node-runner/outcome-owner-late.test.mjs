import assert from 'node:assert/strict';
import {vpnFixture} from './helpers/vpn-fixture.mjs';
import {deferred,flush} from './helpers/ets-loader.mjs';

{
  const f=vpnFixture(),w=f.want('B'); f.v.onCreate(w); await flush(250);
  const before={desired:f.v.desiredRunning,cancelled:f.v.cancelled,epoch:f.v.commandEpoch,
    latest:f.v.latestCommand,core:f.native.xrayOwnerSeq};
  f.v.onRequest({parameters:{command:'stop',generation:'A'}},2); await flush(100);
  assert.deepEqual({desired:f.v.desiredRunning,cancelled:f.v.cancelled,epoch:f.v.commandEpoch,
    latest:f.v.latestCommand,core:f.native.xrayOwnerSeq},before);
  assert.equal(f.v.generation,'B'); assert(f.native.tunRunning);
}
{
  const f=vpnFixture(),gate=deferred();f.destroy=()=>gate.promise;
  f.v.onCreate(f.want('B')); await flush(250); f.cancel('B');
  await f.clock.advance(4100); assert.equal(f.v.destroyInFlight,true);
  assert.notEqual(f.v.status.phase,'STOPPED');assert(!f.files.has('owner-terminal.json'));
  gate.resolve(); await flush(300);
  assert.equal(f.v.destroyInFlight,false);assert.equal(f.v.status.phase,'STOPPED');
  assert(f.load('net/OwnerTerminal.ets').terminalProven(f.files.get('owner-terminal.json'),'B',0,f.clock.now));
}
console.log('PASS production owner: stale STOP has zero mutation; late destroy success converges');
