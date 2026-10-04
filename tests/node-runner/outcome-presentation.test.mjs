import assert from 'node:assert/strict';
import {TextDecoder} from 'node:util';
import {makeLoader,Clock} from './helpers/ets-loader.mjs';
import {uiMethods} from './helpers/ui-methods.mjs';
const clock=new Clock();
const load=makeLoader({'@kit.AbilityKit':{},'@kit.ArkTS':{util:{TextDecoder:class{decodeToString(b){return new TextDecoder().decode(b);}}}}},clock.globals());
const D=load('net/DataplaneStatus.ets'),P=load('net/ProbeResult.ets'),H=load('net/ConnectionHealth.ets'),C=load('core/UserFacingCopy.ets');
let owner={...new D.DataplaneStatus(),generation:'g',ownerInstance:'o',sessionRevision:1,networkEpoch:3,networkState:'available',payloadDigest:'p',phase:'FORWARDER_RUNNING',desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,at:clock.now};
let receipt={schema:2,generation:'g',ownerInstance:'o',revision:1,networkEpoch:3,policyDigest:'p',rid:'p1',at:clock.now,bundle:'fixture',scope:'pangolin-ui-path',source:'entry-foreground',googleHttp:204,cloudflareHttp:0,directHttp:200,dnsOk:true};
H.updateConnectionHealth(owner,JSON.stringify(receipt),'fixture',clock.now);assert.equal(owner.connectionHealth,'partial');assert(C.connectionCopy(owner.phase,false,true,owner.connectionHealth,true).warning);
receipt.cloudflareHttp=204;receipt.dnsOk=false;H.updateConnectionHealth(owner,JSON.stringify(receipt),'fixture',clock.now);assert.equal(owner.connectionHealth,'partial');
receipt.dnsOk=true;H.updateConnectionHealth(owner,JSON.stringify(receipt),'fixture',clock.now);assert.equal(owner.connectionHealth,'reachable');
let badCatalog=false,inspections=0;
let returnedAt=0;
let traffic={schema:1,generation:'g',ownerInstance:'o',revision:1,at:clock.now,uploadBytes:0,downloadBytes:0};
const Store={readStatus:()=>structuredClone(owner),readText:(_ctx,name)=>name==='traffic-sample.json'?JSON.stringify(traffic):JSON.stringify(receipt),readNodeMeta:()=>({name:'n',ytName:'n',usName:'n'})};
const page=uiMethods('Index','Index',['liveStatus','refresh','refreshSafe','updateTraffic','currentSubscriptionHint'],{...D,...P,...H,...C,...clock.globals(),
 formatBytes:load('services/UiFormat.ets').formatBytes,
 ...load('core/TrafficPresentation.ets'),
 STALE_STATUS_MS:25000,CONNECTION_POLICY:{mode:()=> 'single'},StatusStore:Store,
 RESTORE_CHECK_FAILED:'连接已启动，但网络检测未通过；请检查当前节点。',
 pangolinState:ok=>ok?'connected':'warning',PROBE_SELF_CHECK:{lastReturnAt:()=>returnedAt},
 SettingsStore:{load:()=>({})},NodeStore:{loadNodes(){if(badCatalog)throw Error('I/O');return [];}},AppliedPolicy:{matches:()=>true,current:()=>null}});
Object.assign(page,{context:{},activeTab:3,statusSyncing:false,networkChecking:false,testing:false,busy:false,operationError:'',networkResultIdentity:'',previousTraffic:null,trafficSamples:[],trafficUploadRate:'0 B/s',trafficDownloadRate:'0 B/s',lastReceiveAt:0,refreshCount:0,pageRevision:0,canStart:()=>true,makeHint:()=>'',refreshNodeSpeed(){},makeModeLine:()=>'',makeFailoverText:()=>'',makePrepareHint:()=>'',synchronizeStatus(){inspections++;}});
page.refresh();assert.equal(page.honestLabel,'网络正常');assert.equal(page.petState,'connected');assert(page.networkCheckText.includes('海外'));
page.operationError='连接已启动，但网络检测未通过；请检查当前节点。';
page.refresh();assert.equal(page.operationError,'','a later fresh reachable result clears the stale recovery warning');
await clock.advance(1);owner.at=clock.now;returnedAt=clock.now;page.refresh();
assert.equal(page.honestLabel,'正在确认当前网络','returning to app must hide old green until a fresh check');
returnedAt=0;page.refresh();assert.equal(page.honestLabel,'网络正常');
await clock.advance(2000);owner.at=clock.now;traffic={...traffic,at:clock.now,downloadBytes:6144,uploadBytes:1024};page.refresh();
assert.equal(page.trafficDownloadRate,'3.0 KB/s');assert(page.trafficTotals.includes('6.0 KB'));assert(page.lastReceiveAt>0);const sampleCount=page.trafficSamples.length;
page.refresh();assert.equal(page.trafficSamples.length,sampleCount,'re-reading the same sample must not add a point');
returnedAt=clock.now;owner.probePending=true;await clock.advance(21000);owner.at=clock.now;page.refresh();
assert.equal(page.honestLabel,'正在确认当前网络','an outstanding probe must not briefly claim the check failed');
await clock.advance(40000);owner.at=clock.now;page.refresh();
assert.equal(page.honestLabel,'本次检测未完成','a probe still missing after one minute must request a retry');
owner.probePending=false;returnedAt=0;
owner.at-=26000;page.refresh();assert.equal(inspections,1);assert(!page.honestLabel.includes('网络正常'));assert.equal(page.petState,'warning');assert.equal(page.networkCheckText,'');assert.equal(page.networkHealthText,'正在检查当前连接');
owner.phase='STOP_UNCONFIRMED';page.refresh();assert.equal(page.honestLabel,'需要恢复连接');assert.equal(page.needsSystemAction,true);
assert.equal(page.trafficTotals,'','a dead old session must not show its previous traffic as live');
assert.equal(page.networkCheckText,'','a dead old session must not show its previous green checks');
owner.phase='FORWARDER_RUNNING';owner.at=clock.now;badCatalog=true;page.refresh();assert.equal(page.honestLabel,'需要恢复连接');assert.equal(page.petState,'warning');assert.equal(page.networkCheckText,'');assert(page.operationError.includes('恢复连接'));
// Build source is read from packaged resource, not filesDir. Absence is explicit, not invented.
const B=load('services/BuildIdentity.ets').BuildIdentity;
assert.equal(B.source({}), '');
assert.equal(B.source({resourceManager:{getRawFileContentSync(){return Buffer.from('{}');}}}),'');
const source='a'.repeat(64);assert.equal(B.source({resourceManager:{getRawFileContentSync(){return Buffer.from(JSON.stringify({schema:1,sourceIdentity:source}));}}}),source);
console.log('PASS actual UI methods invalidate green before async inspection; corrupt data never stays green; partial checks visible; packaged build identity');
const sequence=[];let outcome='reachable';
let repeatFailure=false;
const repair=uiMethods('Index','Index',['repairConnection'],{...D,...H,...clock.globals(),
 RecoveryTrace:{begin(){return '';},finish(){},currentRouteAlreadyFailed(){return repeatFailure;}},
 CONNECTION_CONTROLLER:{async rebuild(){sequence.push('reconnect');return {...owner,at:clock.now};}},
 PROBE_SELF_CHECK:{async checkNow(){sequence.push('network-check');return '网络正常';}},
 StatusStore:{readStatus:()=>({...owner,connectionHealth:outcome})},UiFeedback:{failure:()=> '重试'}});
Object.assign(repair,{context:{},busy:false,statusSyncing:false,refresh(){sequence.push('refresh');}});
await repair.repairConnection();assert.deepEqual(sequence,['reconnect','network-check','refresh']);assert.equal(repair.repairFailed,false);assert.equal(repair.busy,false);
outcome='check-failed';sequence.length=0;await repair.repairConnection();assert.equal(repair.repairFailed,true);assert.match(repair.operationError,/选择其他节点/);
repeatFailure=true;sequence.length=0;await repair.repairConnection();
assert.deepEqual(sequence,['refresh'],'the same failed route is not rebuilt indefinitely');
assert.match(repair.operationError,/订阅/);
