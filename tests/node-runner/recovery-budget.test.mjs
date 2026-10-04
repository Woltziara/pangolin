import assert from 'node:assert/strict';
import {vpnFixture} from './helpers/vpn-fixture.mjs';
import {deferred,flush} from './helpers/ets-loader.mjs';
async function fixture(){
 const f=vpnFixture();f.v.onCreate(f.want('budget'));await flush(250);f.v.startInFlight=false;
 f.v.automaticRecoveries=2;f.v.recoveryWindowAt=f.clock.now;
 f.calls=0;f.v.recover=async()=>{f.calls++};return f;
}
const f=await fixture();
f.canary=async()=>({ok:false,message:'unreachable',elapsedMs:1});
await f.v.runCanaryCycle();f.v.requestRecover('latest-network');await flush();
assert.equal(f.calls,0,'failed checks must not reopen an exhausted budget');
assert.equal(f.v.automaticRecoveries,2);
f.canary=async()=>({ok:true,message:'ok',elapsedMs:1});
await f.v.runCanaryCycle();
assert.equal(f.v.automaticRecoveries,0,'fresh successful verification ends the failed-recovery streak');
assert.equal(f.v.status.lastError,'','obsolete pause warning clears after proven recovery');
f.v.requestRecover('latest-network');await flush();assert.equal(f.calls,1);
f.v.requestRecover('supervisor');await flush();f.v.requestRecover('supervisor');await flush();
assert.equal(f.calls,2,'two consecutive unverified attempts still exhaust the budget');
const old=await fixture(),gate=deferred();old.canary=()=>gate.promise;
const pending=old.v.runCanaryCycle();await flush();old.v.status.networkEpoch++;
gate.resolve({ok:true,message:'old network',elapsedMs:1});await pending;
assert.equal(old.v.automaticRecoveries,2,'a late success from the prior network cannot reset the budget');
const poisoned=await fixture();poisoned.v.status.nativePoisoned=true;await poisoned.v.runCanaryCycle();
assert.equal(poisoned.v.automaticRecoveries,2,'poisoned native state cannot be cleared by HTTP success');
console.log('PASS verified recovery resets budget; failures, late epochs, and poisoned native state do not');
