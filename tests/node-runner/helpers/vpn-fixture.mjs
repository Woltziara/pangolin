import {makeLoader,Clock} from './ets-loader.mjs';
export function vpnFixture() {
 const clock=new Clock(),files=new Map(),events=[];
 const native={xrayRunning:false,tunRunning:false,xrayStarting:false,xrayStopPending:false,xrayOwnerSeq:0,protectPending:0,poisoned:false,
  uploadBytes:0,downloadBytes:0,tunFound:true,tunRxBytes:0,tunTxBytes:0,protectQueued:0,protectAcked:0,protectTimeout:0};
 const f={clock,files,events,native,create:async()=>7,destroy:async()=>{},coreStop:()=>true,transparent:null,snapshotError:false,canary:async()=>({ok:true,message:'ok',elapsedMs:1})};
 let loader;
 const node={protocol:'trojan',settings:{servers:[{address:'fixture.invalid',port:443,password:'SYNTHETIC'}]},streamSettings:{network:'tcp',security:'tls',tlsSettings:{serverName:'fixture.invalid',allowInsecure:false}}};
 f.payload=JSON.stringify({v:4,channelMode:'single',singleNodeId:'n-original',singleName:'original',singleRegion:'美国',single:node,routeMode:'rule',routingProfile:'chatgpt-general'});
 const N={getNativeStats:()=>({...native}),abortPoisonedNative(){events.push('isolated-owner-exit');},
  stopNativeXray(){events.push('core-stop');if(!f.coreStop())return {ok:false,poisoned:true,message:'stop failed'};native.xrayRunning=false;native.xrayOwnerSeq=0;return {ok:true,message:'stopped',poisoned:false};},
  stopNativeXrayOwned(seq){events.push({stopOwner:seq});return N.stopNativeXray();},
  startNativeXray:async()=>{events.push('core-start');native.xrayRunning=true;native.xrayOwnerSeq=11;return {ok:true,message:'started',ownerSeq:11,poisoned:false};},
  stopNativeHevTun(){events.push('hev-stop');native.tunRunning=false;return {ok:true,message:'stopped',poisoned:false};},
  startNativeHevTun(){events.push('hev-start');native.tunRunning=true;return {ok:true,message:'started',poisoned:false};},
  setProtectCallback(cb){f.protectCallback=cb;return 1;},clearProtectCallback(){events.push('clear-protect');},claimProtectFd:()=>1,ackProtectFd:(fd,rc,t)=>events.push({ack:fd,rc,t})};
 const mocks={
 'services/Revocations.ets':{Revocations:{revision:()=>0,keys:()=>[]}},
 '@kit.AbilityKit':{},'@kit.BasicServicesKit':{},'@ohos.app.ability.Want':{},
 '@kit.ArkTS':{util:{generateRandomUUID:()=> '12345678-0000'}},
 '@kit.NetworkKit':{VpnExtensionAbility:class{},connection:{createNetConnection:()=>({on(){},register(cb){cb({});},unregister(cb){cb({});}})}},
 '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
 'services/RuntimeJournal.ets':{RuntimeJournal:{sample(){},event(){}}},
 'services/AppliedPolicy.ets':{AppliedPolicy:{record(){events.push('policy-record');},noteRunning(){}}},
 'services/RunningSnapshot.ets':{RunningSnapshot:{assertAuthorized(){},async record(_c,_p,_s,_i,allowed){events.push('snapshot-save');if(f.snapshotError)throw Error('disk');if(!allowed())throw Error('stale');},async read(){return f.snapshot;}}},
 'services/AppRouteRuntime.ets':{AppRouteRuntime:{async prepare(){return {ports:[],install(){},stop(){},diagnostics:()=>({enabled:false,active:false})};}}},
 'services/ConnectionPolicy.ets':{CONNECTION_POLICY:{autoFailoverEnabled:()=>false,enforcePayload:(_c,p)=>p}},
 'services/HuksSecretStore.ets':{HuksSecretStore:{readOutbound:async()=>f.payload,restorePrevious:()=>true}},
 'services/SettingsStore.ets':{SettingsStore:{load:()=>({singleNodeId:'n-original',chatgptNodeId:'',generalNodeId:'',failoverEnabled:false,failoverGroup:'',routeMode:'rule'})}},
 'services/StatusStore.ets':{OUTBOUND_FILE:'outbound.json',StatusStore:{
  readText:(_c,k)=>files.get(k)||'',writeText:(_c,k,v)=>{files.set(k,v);events.push({file:k});},removeFile:(_c,k)=>files.delete(k),destExistsNonempty:()=>false,
  readNodeMeta:()=>({name:'original',region:'美国'}),writeNodeMeta(_c,v){files.set('node-meta.json',v);},
  readStatus:()=>loader('net/DataplaneStatus.ets').parseStatus(files.get('dataplane-status.json')||''),
  writeStatus(_c,s){files.set('dataplane-status.json',loader('net/DataplaneStatus.ets').serializeStatus(s));}}},
 'services/EventStore.ets':{EventStore:{append(){}}},
 'net/ProcNet.ets':{readVpnTunCounters:()=>({found:true,rxBytes:native.downloadBytes,txBytes:native.uploadBytes,rxPackets:1,txPackets:1,txDropped:0})},
 'net/DataplaneCanary.ets':{tcpConnectCanary:async()=>({ok:true,message:'ok'}),socksHttpCanary:async()=>f.canary()},
 'net/NodeAddressResolver.ets':{withSystemResolvedNodes:async s=>s},
 'native/TunnelNative.ets':N,
 'core/XrayRuntime.ets':{SocksSession:class{constructor(){this.host='127.0.0.1';this.port=18082;this.user='u';this.pass='p';}},newSocksSession:()=>({host:'127.0.0.1',port:18082,user:'u',pass:'p'}),buildRuntimeXrayConfig:()=> '{}',NODE_META_FILE:'node-meta.json',parseNodeMeta:()=>({name:'original',region:'美国'})},
 'services/NodeLatencyTest.ets':{},'services/LatencyProbe.ets':{},'net/NodeEndpointProbe.ets':{},
 'vpn/VpnConstants.ets':{MODE_FULL:'full',MODE_PROBE_SELF:'probe-self',MODE_PROBE_BROWSER:'probe-browser',VPN_COMMAND_KEY:'command',VPN_COMMAND_STOP:'stop',VPN_GENERATION_KEY:'generation',VPN_MODE_KEY:'mode',BUNDLE_NAME:'fixture',VPN_MTU:1500,trustedAppsForMode:()=>[],createTunnelVpnConfig:()=>({})},
 };
 const conn={protectProcessNet:async()=>{},protect:async()=>{},create:async()=>{events.push('vpn-create');return f.create();},destroy:async()=>{events.push('vpn-destroy');return f.destroy();}};
 mocks['@kit.NetworkKit'].vpnExtension={createVpnConnection:()=>conn};
 loader=makeLoader(mocks,clock.globals());f.load=loader;
 f.v=new (loader('vpn/TunnelVpnAbility.ets').default)();f.v.context={filesDir:'/fixture'};f.conn=conn;
 f.want=(gen='new')=>{files.set('connection-control.json',JSON.stringify({kind:'start',intentId:gen,generation:gen,state:'pending'}));return {parameters:{generation:gen,mode:'full',controlIntentId:gen}};};
 f.cancel=(gen='new')=>{files.set('connection-control.json',JSON.stringify({kind:'stop',intentId:gen,generation:gen,state:'pending'}));f.v.onDestroy();};
 return f;
}
