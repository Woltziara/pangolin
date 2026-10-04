import assert from 'node:assert/strict';
import {vpnFixture} from './helpers/vpn-fixture.mjs';
import {makeLoader,flush} from './helpers/ets-loader.mjs';
// A failure after beginning recovery must not implicitly bootstrap the same start again.
{
 const f=vpnFixture();f.v.onCreate(f.want('bounded'));await flush(250);const starts=f.events.filter(e=>e==='core-start').length;
 f.load('services/AppRouteRuntime.ets').AppRouteRuntime.prepare=async()=>{throw Error('injected config failure');};
 await f.v.recover();await flush(350);assert.equal(f.events.filter(e=>e==='core-start').length,starts);
 assert.equal(f.v.desiredRunning,false);assert.equal(f.v.status.phase,'STOPPED');assert.equal(f.v.status.endReason,'recovery-failed');
}
// Explicit revocations are relative to the authorization captured at user start,
// never to the current wall clock or a changed catalog alone.
{
 const files=new Map(),catalog=[{id:'n',sourceId:'s',region:'美国',outboundJson:'{}'}];
 const payload=JSON.stringify({v:4,channelMode:'single',singleNodeId:'n'});
 const load=makeLoader({'@kit.AbilityKit':{},'services/StatusStore.ets':{StatusStore:{readStrictText:(_c,k)=>files.get(k)||'',compareText(_c,k,a,b){if((files.get(k)||'')!==a)return false;files.set(k,b);return true;}}},
  'services/NodeStore.ets':{NodeStore:{loadNodes:()=>catalog}},'services/HuksSecretStore.ets':{},'services/SettingsStore.ets':{},'services/AppRouteCapability.ets':{}});
 const R=load('services/Revocations.ets').Revocations,S=load('services/RunningSnapshot.ets').RunningSnapshot;
 const birth=R.revision({});S.assertAuthorized({},payload,{authorizedRevision:birth});R.revoke({},['source:s']);
 assert.throws(()=>S.assertAuthorized({},payload,{authorizedRevision:birth}),/删除/);
 const explicitNewStart=R.revision({});assert.doesNotThrow(()=>S.assertAuthorized({},payload,{authorizedRevision:explicitNewStart}));
 R.revoke({},['node:unrelated']);assert.doesNotThrow(()=>S.assertAuthorized({},payload,{authorizedRevision:explicitNewStart}));
 R.revoke({},['node:n']);assert.throws(()=>S.assertAuthorized({},payload,{authorizedRevision:explicitNewStart}));
}
console.log('PASS real owner recovery cannot bypass budget through cleanup; real source/node revocations apply to original session authorization');
