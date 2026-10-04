import assert from 'node:assert/strict';
import {uiMethods} from './helpers/ui-methods.mjs';

async function run(bearer, resultPhase='FORWARDER_RUNNING', syncing=false, health='reachable') {
  const calls=[];
  const page=uiMethods('Index','Index',['restoreConnectionHere'],{
    RecoveryTrace:{begin(){calls.push('freeze-before');return 'incident-report-1.json';},finish(){calls.push('record-after');}},
    CONNECTION_CONTROLLER:{
      async reconcileStatus(){calls.push('inspect');return {phase:'STOP_UNCONFIRMED'};},
      async resumeWithAbsentBearer(){calls.push('resume-pinned');return {phase:resultPhase,lastError:'恢复尚未完成'};},
      async rebuild(){calls.push('rebuild-pinned');return {phase:resultPhase,lastError:'恢复尚未完成'};},
      async start(){calls.push('normal-start');return {phase:resultPhase};}
    },
    StatusStore:{readStrictText:()=>JSON.stringify({bearer}),readStatus:()=>({connectionHealth:health})},
    PROBE_SELF_CHECK:{async checkNow(){calls.push('check-network');return '国内和海外访问已检测';}},
    UiFeedback:{failure(_ctx,_kind,error){return error.message;}},
    PHASE_STOPPED:'STOPPED',PHASE_IDLE:'IDLE',PHASE_ERROR:'ERROR',
    RESTORE_CHECK_FAILED:'连接已启动，但网络检测未通过；请检查当前节点。'
  });
  Object.assign(page,{busy:false,statusSyncing:syncing,context:{},recoveryStep:'',operationError:'',
    refresh(){calls.push('refresh');}});
  await page.restoreConnectionHere();
  return {page,calls};
}

{
  const {page,calls}=await run('absent','FORWARDER_RUNNING',true);
  assert.deepEqual(calls,['freeze-before','inspect','resume-pinned','check-network','record-after','refresh']);
  assert.equal(page.petState,'connecting');assert.equal(page.operationError,'');assert.equal(page.busy,false);
  assert.equal(page.recoveryStep,'');
}
{
  const {calls}=await run('present');
  assert.deepEqual(calls,['freeze-before','inspect','rebuild-pinned','check-network','record-after','refresh']);
}
{
  const {page,calls}=await run('unknown');
  assert.deepEqual(calls,['freeze-before','inspect','record-after','refresh']);
  assert.match(page.operationError,/不能确认系统 VPN 状态/);
}
{
  const {page,calls}=await run('absent','STOP_UNCONFIRMED');
  assert.deepEqual(calls,['freeze-before','inspect','resume-pinned','record-after','refresh']);
  assert.match(page.operationError,/恢复尚未完成/);
}
{
  const {page}=await run('absent','FORWARDER_RUNNING',false,'checking');
  assert.equal(page.operationError,'','a pending check must not claim the new tunnel failed');
}
{
  const {page}=await run('absent','FORWARDER_RUNNING',false,'check-failed');
  assert.match(page.operationError,/网络检测未通过/,'a real failed check stays visible');
}
console.log('PASS homepage recovery uses one click, same-session restart or rebuild, and in-place results');
