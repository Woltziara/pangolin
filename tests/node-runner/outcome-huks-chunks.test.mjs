import assert from 'node:assert/strict';
import {createCipheriv,createDecipheriv,randomBytes,randomUUID} from 'node:crypto';
import {makeLoader,flush,deferred} from './helpers/ets-loader.mjs';
const files=new Map(),key=randomBytes(32),sessions=new Map();let id=0;
const tags={HUKS_TAG_ALGORITHM:1,HUKS_TAG_PURPOSE:2,HUKS_TAG_KEY_SIZE:3,HUKS_TAG_PADDING:4,HUKS_TAG_BLOCK_MODE:5,HUKS_TAG_NONCE:6,HUKS_TAG_ASSOCIATED_DATA:7,HUKS_TAG_AE_TAG:8};
const huks={HuksTag:tags,HuksKeyPurpose:{HUKS_KEY_PURPOSE_ENCRYPT:1,HUKS_KEY_PURPOSE_DECRYPT:2},HuksKeyAlg:{HUKS_ALG_AES:1},HuksKeySize:{HUKS_AES_KEY_SIZE_256:256},HuksKeyPadding:{HUKS_PADDING_NONE:0},HuksCipherMode:{HUKS_MODE_GCM:1},
 isKeyItemExist:async()=>true,initSession:async(_a,{properties})=>{const handle=++id;sessions.set(handle,new Map(properties.map(p=>[p.tag,p.value])));return {handle};},
 async finishSession(handle,{inData}){const p=sessions.get(handle);sessions.delete(handle);const enc=p.get(2)===1;
  const c=enc?createCipheriv('aes-256-gcm',key,p.get(6)):createDecipheriv('aes-256-gcm',key,p.get(6));c.setAAD(Buffer.from(p.get(7)));if(!enc)c.setAuthTag(Buffer.from(p.get(8)));
  const out=Buffer.concat([c.update(inData),c.final()]);return {outData:new Uint8Array(enc?Buffer.concat([out,c.getAuthTag()]):out)};},abortSession:async h=>sessions.delete(h)};
const util={generateRandomUUID:randomUUID,generateRandomBinaryUUID:()=>randomBytes(16),TextEncoder:class{encodeInto(s){return new TextEncoder().encode(s);}},TextDecoder:class{decodeToString(b){return new TextDecoder().decode(b);}},Base64Helper:class{encodeToStringSync(b){return Buffer.from(b).toString('base64');}decodeSync(s){return new Uint8Array(Buffer.from(s,'base64'));}}};
const mocks={'@kit.AbilityKit':{},'@kit.ArkTS':{util},'@kit.UniversalKeystoreKit':{huks},'@kit.PerformanceAnalysisKit':{hilog:{warn(){},error(){},info(){}}},'services/StatusStore.ets':{StatusStore:{readStrictText:(_c,k)=>files.get(k)||'',readText:(_c,k)=>files.get(k)||'',writeText:(_c,k,v)=>files.set(k,v)}}};
const H=makeLoader(mocks)('services/HuksSecretStore.ets').HuksSecretStore;
const name='running-recovery-identity-1.huks',text=JSON.stringify({payload:'中文🔐'.repeat(4000),credential:'SYNTHETIC-NOT-A-REAL-CREDENTIAL'});
await H.writeLocalRecord({},name,text);const raw=files.get(name),wrapper=JSON.parse(raw);assert(wrapper.chunks.length>2);assert(!raw.includes('SYNTHETIC'));assert.equal(await H.readLocalRecord({},name),text);
for(const mutate of [w=>w.chunks.reverse(),w=>w.chunks.pop(),w=>{const x=JSON.parse(w.chunks[0]);x.ct=x.ct.slice(0,-6)+'AAAAAA';w.chunks[0]=JSON.stringify(x);}]) {
 const w=JSON.parse(raw);mutate(w);files.set(name,JSON.stringify(w));await assert.rejects(H.readLocalRecord({},name));
}
files.set(name,raw);const second='running-recovery-identity-2.huks';await H.writeLocalRecord({},second,text);
const mixed=JSON.parse(raw);mixed.chunks[1]=JSON.parse(files.get(second)).chunks[1];files.set(name,JSON.stringify(mixed));await assert.rejects(H.readLocalRecord({},name));
files.set(name,raw);let live=true;const original=huks.finishSession,gate=deferred();huks.finishSession=async(...args)=>{await gate.promise;return original(...args);};
const late=H.writeLocalRecord({},name,'late'.repeat(1000),()=>live);await flush();live=false;gate.resolve();await late;assert.equal(files.get(name),raw);assert.equal(sessions.size,0);
console.log('PASS real production HUKS chunk protocol over host AES-GCM: UTF8, auth, reorder, truncate, cross-record splice, late commit fencing (not hardware HUKS verification)');
