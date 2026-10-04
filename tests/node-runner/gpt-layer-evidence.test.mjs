import assert from 'node:assert/strict';
import {makeLoader} from './helpers/ets-loader.mjs';
const load=makeLoader();const {LayerEvidence,rebuildEvidence,safeLayerRecord}=load('net/LayerEvidence.ets');
const {DataplaneStatus}=load('net/DataplaneStatus.ets');let now=1800000000000;
const s={...new DataplaneStatus(),generation:'g',sessionRevision:1,at:now,desiredRunning:true,phase:'UNPROVEN',
  vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,probePending:true,evidenceRid:'rid',probeIssuedAt:now-100};
const native={xrayRunning:true,tunRunning:true,poisoned:false,xrayStarting:false,xrayStopPending:false};
const receipt=(ok,at=now)=>JSON.stringify({generation:'g',revision:1,rid:'rid',at,bundle:'fixture',source:'entry-background',googleHttp:ok?204:0,directHttp:ok?200:0,dnsOk:ok});
const e=new LayerEvidence();e.reset('g',1);e.noteSocks(true,now);let r=e.sample(s,native,receipt(false),'fixture',now);
assert.equal(r.throughTun,'failure');assert.equal(r.bypassSocks,'success');assert.equal(r.rebuildAllowed,false);
now+=20000;s.tunTxBytes=500;s.tunDropped=1;r=e.sample(s,native,receipt(false),'fixture',now);
assert.equal(r.tunProgress,'stalled-with-input');assert.equal(r.rebuildAllowed,true);assert(rebuildEvidence(JSON.stringify(r),s,now));
assert(!rebuildEvidence(JSON.stringify(r),s,now+25001));
// Bypass success cannot reset transparent-path failures.
e.noteSocks(true,++now);r=e.sample(s,native,receipt(false),'fixture',now);assert(r.throughFailureReceipts>=2);assert(r.rebuildAllowed);
// One cached receipt cannot count as multiple failures; idle never proves stall.
const idle=new LayerEvidence();idle.reset('g',1);idle.noteSocks(true,now);const failed=receipt(false);
idle.sample(s,native,failed,'fixture',now);r=idle.sample(s,native,failed,'fixture',now+20000);assert.equal(r.throughFailureReceipts,1);assert.equal(r.rebuildAllowed,false);
// A new business failure does not authorize network changes; fresh tunnel succeeds.
const business=JSON.stringify({generation:'g',revision:1,at:now,scope:'chatgpt-application',source:'explicit-user-action',outcome:'user-reported-failure',secret:'MUST_NOT_EXPORT'});
r=e.sample(s,native,receipt(true),'fixture',++now,business);assert.equal(r.targetBusiness,'user-reported-failure');assert.equal(r.rebuildAllowed,false);
// Missing runtime fields are unknown, not true. Old business is not reattributed.
r=e.sample({...s,generation:'new'}, {},receipt(true),'fixture',++now,business);assert.equal(r.native,'unknown');assert.equal(r.targetBusiness,'not-observed');assert.equal(r.rebuildAllowed,false);
const safe=safeLayerRecord(JSON.stringify({...r,token:'SECRET',targetBusiness:'arbitrary-url-secret'}));assert(!JSON.stringify(safe).includes('SECRET'));assert.equal(safe.targetBusiness,undefined);
console.log('PASS 8 production layer-evidence cases: SOCKS/TUN mismatch, stale evidence, repeated receipt, idle, business isolation, missing stats, generation, export whitelist');
