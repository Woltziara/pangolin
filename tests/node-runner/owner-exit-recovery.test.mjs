import assert from 'node:assert/strict';
import {makeLoader,Clock} from './helpers/ets-loader.mjs';

async function drive(clock,promise,rounds=12) {
  let done=false,error,value;
  promise.then(v=>{done=true;value=v;},e=>{done=true;error=e;});
  for(let i=0;i<rounds&&!done;i++)await clock.advance(500);
  if(!done)throw Error('fixture did not settle');
  if(error)throw error;
  return value;
}

function fixture() {
  const clock=new Clock(),files=new Map(),events=[];
  const state={boot:'boot-a',bearer:'absent',vpnVisible:false,extra:false,omitVpn:false,omitCaller:false,
    mutateOwnerOnDiagnostic:false,failFenceCas:false,nonce:0};
  const owner={generation:'old-generation',ownerInstance:'old-owner',sessionRevision:4,
    phase:'FORWARDER_RUNNING',at:clock.now-30000,desiredRunning:true,vpnCreated:true,
    tunFdValid:true,xrayRunning:true,forwarderOk:true,cleanupPending:false,bootId:'boot-a'};
  const ownerRaw=JSON.stringify(owner),terminalRaw=JSON.stringify({writer:'vpn-owner',generation:'older'});
  files.set('dataplane-status.json',ownerRaw);
  files.set('owner-terminal.json',terminalRaw);
  files.set('connection-control.json',JSON.stringify({schema:2,bootId:'boot-a',operationId:'old-op',
    controllerInstance:'dead-ui',kind:'stop',state:'unconfirmed',generation:owner.generation,
    intentId:owner.generation,requestedAt:clock.now-20000,at:clock.now-10000,
    platformPending:false,inheritedUnresolved:false}));
  files.set('platform-operations-v2.json',JSON.stringify({schema:2,operations:[]}));
  const rows=()=>{
    const result=state.omitCaller?[]:[{pid:10,uid:20,processName:'ui',bundleNames:['com.oscarwoltz.tongdao']}];
    if(state.extra)result.push({pid:30,uid:20,processName:'other',bundleNames:['com.oscarwoltz.tongdao']});
    if(state.vpnVisible&&!state.omitVpn)result.push({pid:40,uid:20,processName:'com.oscarwoltz.tongdao:vpn',bundleNames:['com.oscarwoltz.tongdao']});
    return result;
  };
  const StatusStore={
    readStrictText:(_c,n)=>files.get(n)||'',readText:(_c,n)=>files.get(n)||'',
    readOwnerStatus:()=>structuredClone(owner),
    compareText(_c,n,expected,value){
      if(n==='connection-control.json'&&state.failFenceCas&&JSON.parse(value).state==='pending')return false;
      if((files.get(n)||'')!==expected)return false;files.set(n,value);return true;
    },
    writeText(_c,n,value){files.set(n,value);events.push({write:n});}
  };
  const mocks={
    '@kit.AbilityKit':{appManager:{getRunningProcessInformation:async()=>rows()}},
    '@kit.ArkTS':{process:{pid:10,uid:20},util:{generateRandomUUID:()=>`recovery-${++state.nonce}`}},
    '@kit.NetworkKit':{
      connection:{NetBearType:{BEARER_VPN:4},getAllNets:async()=>state.bearer==='present'?[{id:1}]:[],
        getNetCapabilities:async()=>({bearerTypes:[4]})},
      vpnExtension:{
        async startVpnExtensionAbility(want){
          events.push('diagnostic-start');state.vpnVisible=true;
          files.set('owner-visibility.json',JSON.stringify({nonce:want.parameters.recoveryNonce,pid:40,empty:true,at:clock.now}));
          if(state.mutateOwnerOnDiagnostic)files.set('dataplane-status.json',JSON.stringify({...owner,at:owner.at+1}));
        },
        async stopVpnExtensionAbility(){events.push('system-stop');state.vpnVisible=false;}
      }
    },
    'native/TunnelNative.ets':{systemBootId:()=>state.boot},
    'vpn/VpnConstants.ets':{BUNDLE_NAME:'com.oscarwoltz.tongdao',createVpnAbilityWant:()=>({parameters:{}})},
    'services/StatusStore.ets':{StatusStore}
  };
  const load=makeLoader(mocks,clock.globals());
  const Operations=load('services/PlatformOperations.ets').PlatformOperations;
  return {clock,files,events,state,owner,ownerRaw,terminalRaw,load,operations:new Operations(),
    recover(knownEmptyPid=-1){return load('services/OwnerExitRecovery.ets').OwnerExitRecovery.recover({},this.operations,knownEmptyPid);}};
}

let count=0;

// Successful recovery creates a separate system observation and projection only.
{
  const f=fixture();await drive(f.clock,f.recover());
  const control=JSON.parse(f.files.get('connection-control.json'));
  const observation=JSON.parse(f.files.get('system-observation.json'));
  assert.equal(control.kind,'cancel');assert.equal(control.state,'confirmed');
  assert.equal(observation.kind,'system-owner-disappearance');assert.equal(observation.samples,2);
  assert.equal(f.files.get('dataplane-status.json'),f.ownerRaw);
  assert.equal(f.files.get('owner-terminal.json'),f.terminalRaw);
  const O=f.load('net/OwnerTerminal.ets');
  const projected=O.projectControl(structuredClone(f.owner),JSON.stringify(control),f.terminalRaw,JSON.stringify(observation));
  assert.equal(projected.phase,'STOPPED');assert.equal(projected.operationState,'owner-exit-confirmed');
  assert.equal(O.controlAllowsStart(JSON.stringify(control),f.owner.generation,f.owner.generation),false,
    'late old start stays fenced after recovery');
  assert.deepEqual(f.events.filter(x=>typeof x==='string'),['diagnostic-start','system-stop']);count++;
}

// The positive control must be visible through the same appManager API.
{
  const f=fixture();f.state.vpnVisible=true;
  await drive(f.clock,f.recover(40));
  assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'confirmed');
  assert.equal(f.state.vpnVisible,false,'the verified empty extension is stopped before a new owner starts');count++;
}
// The positive control must be visible through the same appManager API.
{
  const f=fixture();f.state.omitVpn=true;
  await assert.rejects(f.recover(),/未能识别 VPN 进程/);
  assert(f.events.includes('system-stop'),'failed positive canary must be cleaned up');
  assert.equal(f.state.vpnVisible,false);
  assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'pending');
  assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'pending');
  assert(!f.files.has('system-observation.json'));count++;
}

// Initial process and bearer observations fail closed.
{
  const f=fixture();f.state.extra=true;
  await assert.rejects(f.recover(),/后台进程仍在运行/);assert(!f.events.includes('diagnostic-start'));count++;
}
{
  const f=fixture();f.state.bearer='present';
  await assert.rejects(f.recover(),/系统 VPN 仍在运行/);assert(!f.events.includes('diagnostic-start'));count++;
}

// Durable or local pending operations, legacy uncertainty and corrupt ledgers never unlock.
{
  const f=fixture();f.files.set('platform-operations-v2.json',JSON.stringify({schema:2,operations:[{
    id:'pending-stop',operationId:'old-op',kind:'system-stop',generation:f.owner.generation,
    controller:'dead-ui',state:'pending',startedAt:f.clock.now-1000,bootId:'boot-a'}]}));
  await assert.rejects(f.recover(),/还未结束/);assert(!f.events.includes('diagnostic-start'));count++;
}
{
  const f=fixture();f.operations.pending=1;
  await assert.rejects(f.recover(),/还未结束/);count++;
}
{
  const f=fixture();const c=JSON.parse(f.files.get('connection-control.json'));c.inheritedUnresolved=true;
  f.files.set('connection-control.json',JSON.stringify(c));
  await assert.rejects(f.recover(),/无法核实的旧系统操作/);count++;
}
{
  const f=fixture();f.files.set('platform-operations-v2.json','{"schema":2,"operations":[{}]}');
  await assert.rejects(f.recover(),/账本记录损坏/);count++;
}

// Exact CAS and owner-raw stability protect a concurrent/newer state.
{
  const f=fixture();f.state.failFenceCas=true;
  await assert.rejects(f.recover(),/连接已变化/);assert(!f.files.has('system-observation.json'));count++;
}
{
  const f=fixture();f.state.mutateOwnerOnDiagnostic=true;
  await assert.rejects(f.recover(),/恢复期间连接已变化/);
  assert.equal(JSON.parse(f.files.get('connection-control.json')).state,'pending');
  assert(!f.files.has('system-observation.json'));count++;
}

// Boot and caller-list integrity are part of the proof, not optional diagnostics.
{
  const f=fixture();f.state.boot='boot-b';
  await assert.rejects(f.recover(),/无法核实的旧系统操作/);count++;
}
{
  const f=fixture();f.state.omitCaller=true;
  await assert.rejects(f.recover(),/进程清单不完整/);assert(!f.events.includes('diagnostic-start'));count++;
}

// A newly settled operation must survive compaction when sixteen older done rows exist.
{
  const f=fixture(),old=[];
  for(let i=0;i<16;i++)old.push({id:`old-${i}`,operationId:`old-control-${i}`,kind:'diagnostic',
    generation:f.owner.generation,controller:'old-controller',state:'completed',
    startedAt:f.clock.now-20000+i,finishedAt:f.clock.now-10000+i,bootId:'boot-a'});
  f.files.set('platform-operations-v2.json',JSON.stringify({schema:2,operations:old}));
  await f.operations.run({},'diagnostic',f.owner.generation,async()=>{},3000);
  const rows=JSON.parse(f.files.get('platform-operations-v2.json')).operations;
  assert(rows.some(row=>row.controller===f.operations.instance&&row.kind==='diagnostic'&&row.state==='completed'),
    'ledger compaction must retain the operation that just settled');count++;
}

console.log(`PASS ${count} real OwnerExitRecovery/PlatformOperations/OwnerTerminal safety and liveness scenarios`);

{
 const f=fixture();f.files.delete('platform-operations-v2.json');
 await assert.rejects(f.recover(),/记录缺失/);assert(!f.events.includes('diagnostic-start'));
}
console.log('PASS missing operation ledger cannot authorize owner recovery');
