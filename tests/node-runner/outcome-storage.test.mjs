import assert from 'node:assert/strict';
import {makeLoader,deferred,flush} from './helpers/ets-loader.mjs';
const files=new Map(),fds=new Map();let fd=0,lease=false,ioError='',casConflict=false,writeLimit=-1,keyGate=null,failDest='';
const context={filesDir:'/data'};
const name=p=>p.split('/').at(-1);
const fs={OpenMode:{WRITE_ONLY:1,CREATE:2,TRUNC:4},accessSync:p=>files.has(name(p)),readTextSync(p){if(name(p)===ioError)throw Error('permission');return files.get(name(p));},listFileSync:()=>[...files.keys()],
 openSync(p){const n=++fd;fds.set(n,name(p));files.set(name(p),'');return {fd:n};},writeSync(n,value){const text=typeof value==='string'?value:new TextDecoder().decode(value);const b=new TextEncoder().encode(text);const count=writeLimit<0?b.length:writeLimit;files.set(fds.get(n),text.slice(0,count));return count;},fsyncSync(){},closeSync(n){fds.delete(n.fd??n);},unlinkSync:p=>files.delete(name(p))};
const util={generateRandomUUID:()=>`temp-${++fd}`,TextEncoder:class{encodeInto(s){return new TextEncoder().encode(s);}}};
const native={acquireUserDataLease(){if(lease)return 0;lease=true;return 1;},releaseUserDataLease(){lease=false;return true;},compareReplaceText(p,expected,value){if(casConflict||(files.get(name(p))||'')!==expected)return {ok:false,message:'conflict'};files.set(name(p),value);return {ok:true,message:'ok'};},atomicReplaceFile(tmp,dest){if(name(dest)===failDest)throw Error('injected replace failure');files.set(name(dest),files.get(name(tmp)));files.delete(name(tmp));return {ok:true};}};
const mocks={'@kit.AbilityKit':{},'@kit.ArkTS':{util},'@kit.CoreFileKit':{fileIo:fs},'native/TunnelNative.ets':native,
 'core/XrayRuntime.ets':{DATAPLANE_STATUS_FILE:'dataplane-status.json',NODE_META_FILE:'node-meta.json',XRAY_CONFIG_FILE:'xray-config.json',parseNodeMeta:()=>({})},
 'services/PlatformOperations.ets':{PLATFORM_OPERATIONS_FILE:'platform-operations-v2.json'},
 'services/HuksSecretStore.ets':{HuksSecretStore:{async removeProtected(){if(keyGate)await keyGate.promise;}}},
 'services/UiFeedback.ets':{UI_FEEDBACK_FILE:'ui-feedback.json'},'services/RuntimeJournal.ets':{JOURNAL_FILES:[]},
 'services/EventStore.ets':{EVENTS_FILE:'events.json',EVENT_HEAD_FILE:'head.json',EVENT_SNAPSHOT_FILE:'snap.json'}};
const load=makeLoader(mocks),S=load('services/StatusStore.ets').StatusStore,N=load('services/NodeStore.ets').NodeStore,D=load('services/DataManagement.ets').DataManagement;
const Gate=load('services/LifecycleGate.ets').LIFECYCLE_GATE;
const node={id:'node-original',name:'kept',region:'美国',server:'fixture.invalid',port:443,protocol:'trojan',outbound:{protocol:'trojan',settings:{servers:[{address:'fixture.invalid',port:443,password:'SYNTHETIC'}]}},sourceId:'sub-original',favorite:true,customName:'保留名称',group:'group-A'};
const raw=JSON.stringify({v:2,nodes:[node]});files.set('nodes.json',raw);
for(const bad of ['{bad','{"v":99,"nodes":[]}','{"v":2,"nodes":[{}]}']){files.set('nodes.json',bad);assert.throws(()=>N.upsertNodes(context,[],'new'));assert.equal(files.get('nodes.json'),bad);}
files.set('nodes.json',raw);ioError='nodes.json';assert.throws(()=>N.upsertNodes(context,[],'new'));assert.equal(files.get('nodes.json'),raw);ioError='';
const original=N.loadNodes(context);assert(original[0].favorite);assert.equal(original[0].sourceId,'sub-original');
files.set('nodes.json',raw+' ');assert.throws(()=>N.saveNodes(context,original),/另一操作/);assert.equal(files.get('nodes.json'),raw+' ');
N.loadNodes(context);N.saveNodes(context,original);assert.equal(N.loadNodes(context)[0].id,'node-original');
files.set('missing.json.a.tmp','{"valid":true}');assert.throws(()=>S.readJsonFile(context,'missing.json'),/未提交/);assert(!files.has('missing.json'));assert(files.has('missing.json.a.tmp'));
files.set('short.txt','ORIGINAL');writeLimit=1;assert.throws(()=>S.writeText(context,'short.txt','中文'));assert.equal(files.get('short.txt'),'ORIGINAL');assert.equal(fds.size,0);writeLimit=-1;
const releasePrep=Gate.beginPreparation();await assert.rejects(D.wipeAll(context),/连接操作/);releasePrep();
lease=true;assert.throws(()=>N.toggleFavorite(context,'node-original'),/写入|正在|占用|提交/);lease=false;
// While async destructive cleanup owns the data lease, new connects and subscription writes cannot enter.
keyGate=deferred();const wipe=D.clearNodesAndSubscriptions(context);await flush();assert.throws(()=>Gate.beginPreparation(),/清理/);assert.throws(()=>N.saveNodes(context,original));
keyGate.reject(Error('injected key failure'));await assert.rejects(wipe);assert.equal(lease,false);assert.equal(JSON.parse(files.get('connection-control.json')).state,'pending');
await assert.rejects(D.wipeAll(context),/先前/);keyGate=null;await D.clearNodesAndSubscriptions(context);assert.equal(JSON.parse(files.get('connection-control.json')).state,'confirmed');
// A subscription cleanup preserves other sources and survives failure after nodes were removed.
files.delete('connection-control.json');
const short={...node,id:'node-short',sourceId:'sub-short'};
files.set('nodes.json',JSON.stringify({v:2,nodes:[node,short]}));
files.set('subscriptions.json',JSON.stringify([{id:'sub-original',name:'long',url:'https://long.invalid/sub'},{id:'sub-short',name:'short',url:'https://short.invalid/sub'}]));
files.set('settings.json',JSON.stringify({v:1,channelMode:'single',singleNodeId:node.id,manualNodeId:short.id,chatgptNodeId:node.id,generalNodeId:node.id,failoverEnabled:false}));
failDest='settings.json';assert.throws(()=>D.removeSubscriptionAndNodes(context,'sub-short'),/injected/);
assert.equal(D.pendingSubscriptionRemoval(context),'sub-short');
assert.deepEqual(JSON.parse(files.get('nodes.json')).nodes,[node]);
assert.throws(()=>D.removeSubscriptionAndNodes(context,'sub-original'),/先前/);
failDest='';assert.equal(D.removeSubscriptionAndNodes(context,'sub-short'),1);
assert.equal(D.pendingSubscriptionRemoval(context),'');
assert.deepEqual(JSON.parse(files.get('nodes.json')).nodes,[node]);
assert.deepEqual(JSON.parse(files.get('subscriptions.json')).map(s=>s.id),['sub-original']);
assert.equal(JSON.parse(files.get('settings.json')).singleNodeId,node.id);
assert.equal(JSON.parse(files.get('settings.json')).manualNodeId,node.id);
assert(JSON.parse(files.get('recovery-revocations-v1.json')).keys.includes('source:sub-short'));
console.log('PASS production storage and maintenance: corrupt/future/error never overwritten, CAS conflict, pure read, short write fd cleanup, preservation, shared gate/lease, interrupted exact-action resume');
