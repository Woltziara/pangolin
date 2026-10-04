import {makeLoader,Clock,flush} from './ets-loader.mjs';
export function fixture() {
 const clock=new Clock(),files=new Map(),events=[];let owner,loader,nonce=0;
 const f={clock,files,events,bearer:'absent',permission:true,stopAction:async()=>{},systemStopAction:async()=>{},startAction:async()=>{},snapshotRead:null,prepared:0,
  processRows:[{pid:10,uid:20,processName:'com.oscarwoltz.tongdao',bundleNames:['com.oscarwoltz.tongdao']}]};
 const mocks={
  'native/TunnelNative.ets':{systemBootId:()=>f.bootId||'',monotonicMillis:()=>clock.now},
  '@kit.AbilityKit':{appManager:{getRunningProcessInformation:async()=>f.processRows}},'@kit.BasicServicesKit':{},
  '@kit.ArkTS':{process:{pid:10,uid:20},util:{generateRandomUUID:()=>`fixture-${++nonce}`}},
  '@kit.NetworkKit':{connection:{NetBearType:{BEARER_VPN:4},getAllNets:async()=>f.bearer==='present'?[{}]:[],getNetCapabilities:async()=>({bearerTypes:[4]})},vpnExtension:{
    stopVpnExtensionAbility:async()=>{events.push('system-stop');return f.systemStopAction();},
    startVpnExtensionAbility:async want=>{events.push({start:want});
      if(want.parameters?.command==='stop'){events.push('owner-stop');return f.stopAction(want);}
      return f.startAction(want);}}},
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
  'services/BackgroundProbeHost.ets':{BACKGROUND_PROBE_HOST:{start(){events.push('probe-start');},stop(){events.push('probe-stop');}}},
  'services/AppRouteCapability.ets':{AppRouteCapability:{async current(){if(!f.permission)throw Error('permission-denied');}}},
  'services/RunningSnapshot.ets':{RunningSnapshot:{async read(_c,id=''){if(!f.snapshotRead)throw Error('no-snapshot');return f.snapshotRead(id);}}},
  'services/ConnectionPolicy.ets':{CONNECTION_POLICY:{mode:()=> 'single'}},
  'services/HuksSecretStore.ets':{HuksSecretStore:{protectOutbound:async()=>{},readOutbound:async()=>JSON.stringify({v:4,singleNodeId:'original-id'})}},
  'services/NodeStore.ets':{NodeStore:{loadNodes:()=>[]}},
  'services/SettingsStore.ets':{SELECT_MANUAL:'manual',SettingsStore:{load:()=>({selectionMode:'auto'}),update(){throw Error('settings mutation forbidden');}}},
  'services/SplitRouter.ets':{PREPARE_HINT_FILE:'prepare-hint.json',prepareSingleProxy:async()=>{f.prepared++;return 'prepared';}},
  'vpn/VpnConstants.ets':{BUNDLE_NAME:'com.oscarwoltz.tongdao',MODE_FULL:'full',createStartWant:(mode,generation)=>({parameters:{mode,generation}}),
    createStopWant:generation=>({parameters:{command:'stop',generation}}),createVpnAbilityWant:()=>({})},
  'services/StatusStore.ets':{StatusStore:{
    readOwnerStatus:()=>structuredClone(owner),
    readStatus:()=>loader('net/OwnerTerminal.ets').projectControl(structuredClone(owner),files.get('connection-control.json')||'',files.get('owner-terminal.json')||'',files.get('system-observation.json')||''),
    readText:(_c,n)=>files.get(n)||'',readStrictText:(_c,n)=>files.get(n)||'',
    compareText:(_c,n,expected,value)=>{if((files.get(n)||'')!==expected)return false;files.set(n,value);return true;},writeText:(_c,n,v)=>{files.set(n,v);events.push({write:n});},
    removeFile:(_c,n)=>files.delete(n),readNodeMeta:()=>({name:'same-name',region:'美国'}),
    writeStatus(){throw Error('UI attempted to write native owner state');}
  }}
 };
 loader=makeLoader(mocks,clock.globals());const D=loader('net/DataplaneStatus.ets').DataplaneStatus;
 owner={...new D(),generation:'old',sessionRevision:1,phase:'UNPROVEN',at:clock.now,desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,payloadDigest:'abc12345'};
 f.setOwner=s=>{owner={...owner,...s};};f.owner=()=>structuredClone(owner);f.load=loader;
 f.proveStopped=()=>{owner={...owner,phase:'STOPPED',desiredRunning:false,vpnCreated:false,tunFdValid:false,xrayRunning:false,forwarderOk:false,at:clock.now};
  files.set('owner-terminal.json',JSON.stringify({writer:'vpn-owner',generation:owner.generation,at:clock.now,resourcesReleased:true,xrayRunning:false,tunRunning:false,xrayStarting:false,xrayOwnerSeq:0,xrayStopPending:false,protectPending:0,vpnCreatePending:0,vpnDestroyed:true,poisoned:false}));};
 f.connectedStart=want=>{if(want.parameters.command)return;f.setOwner({generation:want.parameters.generation,phase:'UNPROVEN',at:clock.now,desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,sessionRevision:1});};
 f.controller=new (loader('services/ConnectionController.ets').ConnectionController)();return f;
}
