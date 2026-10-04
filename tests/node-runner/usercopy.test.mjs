import assert from 'node:assert/strict';
import { connectionCopy, publicFailure, redactDiagnosticText } from './build/UserFacingCopy.js';
let count=0;
function test(name, fn) { fn(); console.log('ok - '+name); count++; }
test('stale success never claims online or disconnected',()=>{
 const s=connectionCopy('CANARY_OK',true,true); assert.equal(s.title,'连接状态待确认'); assert(s.needsHelp);
});
test('unproven routing evidence is not falsely called unusable traffic',()=>{
 assert.equal(connectionCopy('UNPROVEN',false,true).title,'正在检查连接');
 assert.equal(connectionCopy('DEGRADED_UNPROVEN',false,true).title,'连接状态待确认');
 assert.equal(connectionCopy('CANARY_OK',false,true).title,'已连接');
});
test('fresh reachability can pass independently of unavailable routing logs',()=>{
 assert.equal(connectionCopy('DEGRADED_UNPROVEN',false,true,'reachable').title,'已连接');
 assert.equal(connectionCopy('UNPROVEN',false,true,'check-failed').title,'连接需检查');
 assert.equal(connectionCopy('CANARY_OK',false,true,'unverified').title,'连接状态待确认');
 assert.equal(connectionCopy('CANARY_OK',false,true,'offline').title,'连接已中断');
});
test('stop error and stale runtime override a remembered success',()=>{
 assert.equal(connectionCopy('STOPPED',false,true,'reachable').title,'已断开');
 assert.notEqual(connectionCopy('ERROR',false,true,'reachable').title,'已连接');
 assert.notEqual(connectionCopy('CANARY_OK',true,true,'reachable').title,'已连接');
});
test('unknown future phase is not silently shown as disconnected',()=>{
 assert.equal(connectionCopy('FUTURE_PHASE',false,true).title,'连接状态待确认');
});
test('empty catalog gives an actionable import instruction',()=>{
 assert.match(connectionCopy('IDLE',false,false).detail,/添加/);
});
test('all runtime phases have customer text without backend diagnostics',()=>{
 for(const phase of ['IDLE','STARTING','VPN_CREATED','PROBE_SNIFFING','CORE_RUNNING','FORWARDER_RUNNING','CANARY_OK','UNPROVEN','DEGRADED_UNPROVEN','DEGRADED','RECONNECTING','ERROR','STOPPED','STALE','POISONED']) {
  const copy=connectionCopy(phase,false,true);
  assert(copy.title && copy.detail);
  assert(!/204|googleProxy|udp53Proxy|DATA_TRANSFER|rid|generation|sessionRevision/.test(copy.title+copy.detail));
 }
});
test('arbitrary raw SDK errors cannot pass into a customer message',()=>{
 const raw='204 已到，访问标签不足 udp53Proxy,googleProxy token=fixture-secret';
 assert.equal(publicFailure(raw,'请查看诊断。'),'请查看诊断。');
});
test('diagnostic rendering removes embedded URLs, UUIDs and key values',()=>{
 const raw='error https://user:fixture-password@example.com/path?token=fixture-token token=fixture-secret uuid=00000000-0000-0000-0000-000000000001';
 const result=redactDiagnosticText(raw);
 for(const value of ['fixture-password','fixture-token','fixture-secret','00000000-0000-0000-0000-000000000001']) assert(!result.includes(value));
});
test('bearer and quoted credentials with spaces stay out of diagnostics',()=>{
 const text=redactDiagnosticText('Authorization: Bearer fixture-bearer password="fixture secret phrase"');
 assert(!text.includes('fixture-bearer')); assert(!text.includes('secret phrase'));
});
console.log(`usercopy: ${count} tests passed`);
