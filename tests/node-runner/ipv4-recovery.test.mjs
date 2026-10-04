import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function load(path,deps={},extra={}){
  const source=readFileSync(new URL('../../entry/src/main/ets/'+path,import.meta.url),'utf8');
  const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports,Date,setTimeout,clearTimeout,
    require(n){if(!(n in deps))throw Error('Unexpected import '+n);return deps[n];},...extra});return module.exports;
}
const status=load('net/DataplaneStatus.ets');
let clock=100000,nativeCalls=[],canaryOk=false,port=12345;
class SocksSession {constructor(){this.host='127.0.0.1';this.port=port;this.user='fixture';this.pass='fixture';}}
const deps={
  '../services/RuntimeJournal':{RuntimeJournal:{sample(){},event(){}}},
  '../services/ConnectionPolicy':{CONNECTION_POLICY:{mode(){return 'dual';},enforcePayload(_c,p){return p;},
    autoFailoverEnabled(){return true;}}},
  '../core/ChannelPolicy':load('core/ChannelPolicy.ets'),
  '@kit.NetworkKit':{VpnExtensionAbility:class {},connection:{}},
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},'@kit.ArkTS':{},
  '../net/DataplaneStatus':status,
  '../core/XrayRuntime':{SocksSession,newSocksSession(){port++;return new SocksSession();},
    buildRuntimeXrayConfig(){return JSON.stringify({outbounds:[{tag:'unresolved'}],dns:{servers:['unchanged']}});}},
  '../native/TunnelNative':{getNativeStats(){return {xrayRunning:true,xrayStarting:false,tunRunning:true};},
    startNativeXray(config){nativeCalls.push(JSON.parse(config));return {ok:nativeCalls.length>1,message:nativeCalls.length>1?'started':'bind busy'};}},
  '../net/DataplaneCanary':{async socksHttpCanary(_h,_p,target){return {ok:target==='www.baidu.com'||canaryOk,elapsedMs:1,message:''};}},
  './VpnConstants':{MODE_FULL:'full',VPN_COMMAND_KEY:'command',VPN_GENERATION_KEY:'generation',VPN_MODE_KEY:'mode'},
  '../services/AppliedPolicy':{AppliedPolicy:{record(){}}},
  '../services/AppRouteRuntime':{AppRouteRuntime:class { static async prepare(){return {ports:[],install(){},stop(){},reallocate(){}};} }},
  '../core/LineHealth':load('core/LineHealth.ets'),
  '../core/OutboundCommit':{META_STAGING_FILE:'node-meta.json.staging',digestText(){return 'd';}}
};
for(const n of ['../core/HevTunConfig','../core/OutboundTiming','../net/NodeAddressResolver','../net/ProcNet',
  '../services/EventStore','../services/HuksSecretStore','../services/NodeCatalog','../services/SettingsStore',
  '../services/LatencyProbe','../services/NodeLatencyTest','../net/ConnectionHealth','../net/NodeEndpointProbe'])deps[n]={};
deps['../services/StatusStore']={StatusStore:{readText(){return '';},writeText(){},readStatus(){return {};},writeStatus(){}}};
const Vpn=load('vpn/TunnelVpnAbility.ets',deps,{Date:{now:()=>clock}}).default;
function instance(){const v=new Vpn();v.context={filesDir:'/private'};v.outboundJson='{"channelMode":"dual"}';v.status.phase='UNPROVEN';v.status.sessionRevision=1;
  v.status.generation='g';v.generation='g';v.desiredRunning=true;
  for(const method of ['refreshCounters','publishAccessSlice','applyLiveEvidence','publish','emit','dispatchLatest'])v[method]=()=>{};
  v.guard=()=>true;return v;}
const v=instance();v.enqueue('start','g','full');assert.equal(v.latestCommand.nodeSystemDns,true);
v.enqueue('start','g','full',false,false);assert.equal(v.latestCommand.nodeSystemDns,true);
v.enqueue('start','g','full',true,false);assert.equal(v.latestCommand.nodeSystemDns,false);
const recovered=[];v.requestRecover=reason=>recovered.push(reason);
v.onNetEvent('available',{netId:1});assert.equal(recovered.length,0);
v.onNetEvent('available',{netId:2});assert.equal(recovered.length,1);
v.onNetEvent('available',{netId:2});assert.equal(recovered.length,1);
v.onNetEvent('lost',{netId:2});v.status.phase='UNPROVEN';v.onNetEvent('available',{netId:2});
assert.equal(recovered.length,2,'health projection cannot erase a pending network recovery');
const first={outbounds:[{tag:'proxy',streamSettings:{sockopt:{domainStrategy:'ForceIPv4'}}}],dns:{hosts:{'fixture.test':['203.0.113.2']}}};
assert.equal((await v.startXrayWithPortRetry(JSON.stringify(first))).ok,true);
assert.deepEqual(nativeCalls[1].outbounds,first.outbounds);assert.deepEqual(nativeCalls[1].dns,first.dns);
const c=instance(),actions=[];c.requestRecover=reason=>actions.push(reason);
c.promoteSecondBest=async()=>{actions.push('promote');return true;};
await c.runCanaryCycle();assert.deepEqual(actions,['node-address-refresh']);
await c.runCanaryCycle();assert.deepEqual(actions,['node-address-refresh','promote','node-failover']);
c.coreRestarts=2;canaryOk=true;await c.runCanaryCycle();assert.equal(c.coreRestarts,0);assert.equal(c.addressRefreshAttempted,false);
const s=instance();let confirmations=0;s.runCanaryCycle=async()=>{confirmations++;};
s.status.healthLastOutcome='failure';s.status.healthCheckedAt=clock;s.superviseOnce();assert.equal(confirmations,0);
s.superviseOnce();assert.equal(confirmations,0,'same receipt is not a second failure');
s.status.healthCheckedAt=++clock;s.superviseOnce();assert.equal(confirmations,1);
s.status.healthCheckedAt=++clock;s.superviseOnce();assert.equal(confirmations,1,'independent checks are throttled');
s.status.healthLastOutcome='success';s.status.healthCheckedAt=++clock;s.superviseOnce();assert.equal(s.healthFailureReceipts,0);
console.log('PASS actual VPN: system node DNS default, trace-only override, network handoff/loss, port retry DNS retention, refresh before failover, successful recovery reset, unique/throttled health verification');

const owner=instance();let published=0;owner.forcePublish=()=>{published++;};
owner.onRequest({parameters:{command:'diagnose-connection-status',statusGeneration:'g'}},1);assert.equal(published,1);
const old={...new status.DataplaneStatus(),generation:'old',at:clock-100,phase:'UNPROVEN',vpnCreated:true};
const emptyDeps={...deps,'../native/TunnelNative':{getNativeStats(){return {xrayRunning:false,xrayStarting:false,tunRunning:false};}},
  '../services/StatusStore':{StatusStore:{readStatus(){return {...old};}}}};
const Empty=load('vpn/TunnelVpnAbility.ets',emptyDeps,{Date:{now:()=>clock}}).default;
const empty=new Empty();empty.context={};empty.enqueue=()=>{throw Error('status query must not start VPN');};
const request={parameters:{command:'diagnose-connection-status',statusGeneration:'old',statusAt:old.at}};
empty.onCreate(request);empty.forcePublish=()=>{published++;};empty.onRequest(request,1);
assert.equal(empty.status.phase,'STOPPED');assert.equal(empty.desiredRunning,false);assert.equal(empty.status.vpnCreated,false);
assert.equal(published,2);console.log('PASS actual VPN owner status: live owner refresh and fresh empty owner do not create a tunnel');
