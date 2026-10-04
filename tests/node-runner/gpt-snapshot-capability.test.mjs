import assert from 'node:assert/strict';
import {makeLoader,Clock,deferred,flush} from './helpers/ets-loader.mjs';
const clock=new Clock(),files=new Map();let catalog,config,permission=true,uid=101,sourceWrites=0,revoked=[];
const outbound={protocol:'trojan',settings:{servers:[{address:'fixture.invalid',port:443,password:'synthetic-fixture'}]},streamSettings:{network:'tcp',security:'tls',tlsSettings:{allowInsecure:false}}};
const payload=JSON.stringify({v:4,channelMode:'single',singleNodeId:'id-a',single:outbound,singleRegion:'美国',routeMode:'rule',userRules:[{domain:'example.invalid',action:'proxy'}]});
catalog=[{id:'id-a',name:'same-name',sourceId:'source-a',region:'美国',outboundJson:JSON.stringify(outbound)}];config={version:1,enabled:false,rules:[]};
const mocks={
 'services/Revocations.ets':{Revocations:{keys:()=>revoked,revision:()=>0}},
 '@kit.AbilityKit':{bundleManager:{async getBundleNameByUid(id){if(!permission)throw Error('201');return id===101?'native.a':'native.b';}}},
 'services/NodeStore.ets':{NodeStore:{loadNodes:()=>structuredClone(catalog)}},
 'services/SettingsStore.ets':{SettingsStore:{load:()=>({singleNodeId:'id-a',chatgptNodeId:'',generalNodeId:'',failoverEnabled:false,routeMode:'rule'})}},
 'services/StatusStore.ets':{StatusStore:{readStrictText:(_c,k)=>files.get(k)||'',listNames:()=>[...files.keys()],removeFile:(_c,k)=>files.delete(k),readText:(_c,k)=>files.get(k)||'',writeText(_c,k,v){files.set(k,v);sourceWrites++;}}},
 'services/AppRouteStore.ets':{AppRouteStore:{load:()=>config}},
 'services/AppCatalog.ets':{AppCatalog:{async resolve(bundle){if(!permission)throw Error('201');return {uid:bundle==='native.b'?102:uid};}}},
 'services/HuksSecretStore.ets':{HuksSecretStore:{async writeLocalRecord(_c,k,text,guard){if(guard())files.set(k,text);},async readLocalRecord(_c,k){return files.get(k)||'';},async readOutbound(){return payload;}}}
};
const load=makeLoader(mocks,clock.globals()),{RunningSnapshot}=load('services/RunningSnapshot.ets');
const {AppRouteCapability}=load('services/AppRouteCapability.ets');const status={generation:'g1',sessionRevision:1};
await RunningSnapshot.record({},payload,status);const before=files.get('running-recovery-g1-1.huks');const snap=await RunningSnapshot.read({});
assert.equal(snap.payload,payload);assert.deepEqual(JSON.parse(JSON.stringify(snap.allowedRegions)),['美国']);
// Frozen authenticated payload does not depend on a later mutable catalog.
const originalCatalog=structuredClone(catalog);
for(const changed of [[],[{...catalog[0],id:'id-b',sourceId:'source-b'}],[{...catalog[0],region:'日本',outboundJson:'{}'}]]) {
 catalog=changed;assert.equal((await RunningSnapshot.read({})).payload,payload);
}
revoked=['node:id-a'];await assert.rejects(RunningSnapshot.read({}),/删除/);
revoked=['source:source-a'];await assert.rejects(RunningSnapshot.read({}),/删除/);
revoked=[];catalog=originalCatalog;
assert.equal(files.get('running-recovery-g1-1.huks'),before);assert.equal(sourceWrites,1);
await assert.rejects(RunningSnapshot.read({},'g2-1'));
const rule=(bundle,nodeId='id-a')=>({id:bundle,bundleName:bundle,label:bundle,nodeId,enabled:true,createdAt:1,updatedAt:1});
config={version:1,enabled:true,rules:[rule('native.a')]};permission=false;await assert.rejects(AppRouteCapability.current({}),/当前安装身份/);
permission=true;await AppRouteCapability.current({});
config.rules=[rule('com.openai.chatgpt')];await assert.rejects(AppRouteCapability.current({}),/共用一个应用身份|共用宿主|宿主边界/);
config.rules=[rule('com.google.android.gms')];await assert.rejects(AppRouteCapability.current({}),/共用一个应用身份|宿主/);
// Same UID and mismatching reverse identity must not be applied.
config.rules=[rule('native.a')];uid=102;await assert.rejects(AppRouteCapability.current({}),/可靠确认/);uid=101;
assert.equal(files.get('running-recovery-g1-1.huks'),before);
// Exercise actual HUKS local-record commit code with only cryptographic SDK
// calls substituted. A late encryption completion may not commit old data.
const hm={...mocks};delete hm['services/HuksSecretStore.ets'];hm['@kit.ArkTS']={util:{generateRandomUUID:()=> 'encrypted-record-id'}};hm['@kit.UniversalKeystoreKit']={huks:{}};hm['@kit.PerformanceAnalysisKit']={hilog:{warn(){}}};
const H=makeLoader(hm,clock.globals())('services/HuksSecretStore.ets').HuksSecretStore;
H.b64encode=b=>Buffer.from(b).toString('base64');H.isAvailable=async()=>true;H.ensureKey=async()=>{};H.randomNonce=()=>new Uint8Array(12);H.encode=t=>new TextEncoder().encode(t);
const gate=deferred();H.cipher=()=>gate.promise;H.envelopeJson=()=> 'synthetic-encrypted-envelope';H.unwrapEnvelope=async()=>{throw Error('invalid test envelope');};
let valid=true;const pending=H.writeLocalRecord({},'running-recovery-g1-1.huks','OLD',()=>valid);await flush();valid=false;gate.resolve(new Uint8Array([1]));await assert.rejects(pending,/invalid test envelope/);
assert.equal(files.get('running-recovery-g1-1.huks'),before);
console.log('PASS 12 production snapshot/capability scenarios: exact payload, cross-source names, missing nodes, changed region/config, snapshot ID, permission, shared host, reverse identity, late encrypted commit fence');
