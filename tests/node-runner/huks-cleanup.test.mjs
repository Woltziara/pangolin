import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import {legacyBoundary} from './helpers/legacy-boundaries.mjs';
function loadEts(rel){
  const source=readFileSync(new URL('../../entry/src/main/ets/'+rel,import.meta.url),'utf8');
  const module={exports:{}};
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
    {module,exports:module.exports,require(){throw Error('pure');}});
  return module.exports;
}
const oc=loadEts('core/OutboundCommit.ets');
const source=readFileSync(new URL('../../entry/src/main/ets/services/HuksSecretStore.ets',import.meta.url),'utf8');
let exists=false,queryCode=0,generated=0,removed=false;
const huks={
 async deleteKeyItem(){throw {code:exists?12000004:12000011};},
 async isKeyItemExist(){if(queryCode)throw {code:queryCode};if(!exists)throw {code:12000011};return true;},
 async generateKeyItem(){generated++;exists=true;},
 HuksKeyPurpose:{HUKS_KEY_PURPOSE_ENCRYPT:1,HUKS_KEY_PURPOSE_DECRYPT:2},
 HuksTag:{HUKS_TAG_AE_TAG:'tag'},HuksKeyAlg:{},HuksKeySize:{},HuksKeyPadding:{},HuksCipherMode:{}
};
const deps={'@kit.AbilityKit':{common:{}},'@kit.ArkTS':{util:{TextEncoder:class {encodeInto(s){return new TextEncoder().encode(s);}}}},'@kit.PerformanceAnalysisKit':{hilog:{warn(){},info(){},error(){}}},'@kit.UniversalKeystoreKit':{huks},
 '../core/OutboundCommit':oc,
 './StatusStore':{OUTBOUND_FILE:'outbound.json',StatusStore:{listNamesStrict:()=>[],removeFile(){removed=true;},readText(){return '';},writeText(){}}}};
const module={exports:{}};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
 {module,exports:module.exports,require(n){if(n in deps)return deps[n];const boundary=legacyBoundary(n);if(boundary)return boundary;throw Error(n);}});
const H=module.exports.HuksSecretStore;
await H.removeProtected({});assert(removed);
await H.ensureKey();assert.equal(generated,1);
await assert.rejects(H.removeProtected({}),/未能清理/);
exists=false;queryCode=12000005;
await assert.rejects(H.removeProtected({}),/12000005/);
const bytes=Uint8Array.from({length:30},(_,i)=>i);
huks.initSession=async (_alias,{properties})=>{assert.deepEqual(Array.from(properties.find(p=>p.tag==='tag').value),Array.from(bytes.slice(-16)));return {handle:1};};
huks.finishSession=async (_handle,{inData})=>{assert.deepEqual(Array.from(inData),Array.from(bytes.slice(0,-16)));return {outData:new Uint8Array([42])};};
assert.deepEqual(Array.from(await H.cipher(false,new Uint8Array(12),bytes)),[42]);
await assert.rejects(H.cipher(false,new Uint8Array(12),new Uint8Array(10)),/认证标签/);
console.log('PASS actual HUKS: missing-key rejection is idempotent, first key can be created, remaining key and query failures are not hidden');
console.log('PASS actual HUKS GCM: decryption uses separate 16-byte auth tag and ciphertext; truncated ciphertext rejected');

function loadProtect(failAt) {
  const data = {};
  const aPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"a.example","port":443,"password":"aaaaaaaa"}]}}';
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  const aMeta = '{"name":"A"}';
  const aCommit = JSON.stringify(oc.makeCommit(aPlain, aMeta, 'single', 'a', '', '', 1, 1));
  data[oc.ENVELOPE_FILE] = aPlain.split('').reverse().join('');
  data[oc.META_FILE] = aMeta;
  data[oc.COMMIT_FILE] = aCommit;
  data[oc.OUTBOUND_PLAIN_FILE] = bPlain;
  data[oc.META_STAGING_FILE] = '{"name":"B"}';
  const store = {
    StatusStore: {listNamesStrict:()=>[],
      readText(_c, name) { return data[name] || ''; },
      writeText(_c, name, text) {
        if (failAt === name) throw new Error('inject:' + name);
        data[name] = text;
      },
      removeFile(_c, name) {
        if (failAt === 'remove:' + name) throw new Error('inject:remove:' + name);
        delete data[name];
      }
    }
  };
  let lastPlain = new Uint8Array();
  const huks2 = {
    async isKeyItemExist() { return true; },
    async generateKeyItem() {},
    async initSession() { return { handle: 1 }; },
    async finishSession(_h, { inData }) {
      if (inData && inData.length > 20 && lastPlain.length === 0) lastPlain = inData;
      const out = lastPlain.length > 0 ? lastPlain : (inData || new Uint8Array(32));
      return { outData: out };
    },
    async abortSession() {},
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksTag: { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_PURPOSE: 2, HUKS_TAG_KEY_SIZE: 3, HUKS_TAG_PADDING: 4, HUKS_TAG_BLOCK_MODE: 5, HUKS_TAG_NONCE: 6, HUKS_TAG_ASSOCIATED_DATA: 7, HUKS_TAG_AE_TAG: 8 },
    HuksKeyAlg: { HUKS_ALG_AES: 1 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPadding: { HUKS_PADDING_NONE: 0 }, HuksCipherMode: { HUKS_MODE_GCM: 1 }
  };
  const deps2 = {
    '@kit.AbilityKit': { common: {} },
    '@kit.ArkTS': { util: {
      generateRandomBinaryUUID() { return new Uint8Array(16); },
      TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
      TextDecoder: class { decodeToString(b) { return new TextDecoder().decode(b); } },
      Base64Helper: class {
        encodeToStringSync(b) { return Buffer.from(b).toString('base64'); }
        decodeSync(t) { return new Uint8Array(Buffer.from(t, 'base64')); }
      }
    } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {}, error() {} } },
    '@kit.UniversalKeystoreKit': { huks: huks2 },
    '../core/OutboundCommit': oc,
    './StatusStore': store
  };
  const module2 = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText,
    { module: module2, exports: module2.exports, require(n) { if(n in deps2)return deps2[n];const boundary=legacyBoundary(n);if(boundary)return boundary;throw Error(n); } });
  return { H: module2.exports.HuksSecretStore, data, aPlain };
}
for (const failAt of [oc.META_FILE, oc.COMMIT_FILE, 'remove:' + oc.OUTBOUND_PLAIN_FILE, 'remove:' + oc.META_STAGING_FILE]) {
  const { H: HP, data } = loadProtect(failAt);
  const previousEnvelope = data[oc.ENVELOPE_FILE];
  await assert.rejects(HP.protectOutbound({}), /未应用/);
  assert.equal(data[oc.ENVELOPE_FILE], previousEnvelope);
  assert.equal(JSON.parse(data[oc.META_FILE]).name, 'A');
}
console.log('PASS actual HUKS protectOutbound: write-point failures restore previous envelope/commit/meta');

{
  const data = {};
  const bPlain = '{"protocol":"trojan","settings":{"servers":[{"address":"b.example","port":443,"password":"bbbbbbbb"}]}}';
  data[oc.OUTBOUND_PLAIN_FILE] = bPlain;
  data[oc.META_STAGING_FILE] = '{"name":"B"}';
  const failRemoves = new Set(['remove:' + oc.ENVELOPE_NEXT_FILE, 'remove:' + oc.APPLIED_FILE]);
  const store = {
    StatusStore: {listNamesStrict:()=>[],
      readText(_c, name) { return data[name] || ''; },
      writeText(_c, name, text) { data[name] = text; },
      removeFile(_c, name) {
        if (failRemoves.has('remove:' + name)) throw new Error('inject:remove:' + name);
        delete data[name];
      }
    }
  };
  let lastPlain = new Uint8Array();
  const huks2 = {
    async isKeyItemExist() { return true; },
    async generateKeyItem() {},
    async initSession() { return { handle: 1 }; },
    async finishSession(_h, { inData }) {
      if (inData && inData.length > 20 && lastPlain.length === 0) lastPlain = inData;
      const out = lastPlain.length > 0 ? lastPlain : (inData || new Uint8Array(32));
      return { outData: out };
    },
    async abortSession() {},
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksTag: { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_PURPOSE: 2, HUKS_TAG_KEY_SIZE: 3, HUKS_TAG_PADDING: 4, HUKS_TAG_BLOCK_MODE: 5, HUKS_TAG_NONCE: 6, HUKS_TAG_ASSOCIATED_DATA: 7, HUKS_TAG_AE_TAG: 8 },
    HuksKeyAlg: { HUKS_ALG_AES: 1 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPadding: { HUKS_PADDING_NONE: 0 }, HuksCipherMode: { HUKS_MODE_GCM: 1 }
  };
  const deps2 = {
    '@kit.AbilityKit': { common: {} },
    '@kit.ArkTS': { util: {
      generateRandomBinaryUUID() { return new Uint8Array(16); },
      TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
      TextDecoder: class { decodeToString(b) { return new TextDecoder().decode(b); } },
      Base64Helper: class {
        encodeToStringSync(b) { return Buffer.from(b).toString('base64'); }
        decodeSync(t) { return new Uint8Array(Buffer.from(t, 'base64')); }
      }
    } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {}, error() {} } },
    '@kit.UniversalKeystoreKit': { huks: huks2 },
    '../core/OutboundCommit': oc,
    './StatusStore': store
  };
  const module2 = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText,
    { module: module2, exports: module2.exports, require(n) { if(n in deps2)return deps2[n];const boundary=legacyBoundary(n);if(boundary)return boundary;throw Error(n); } });
  const HP = module2.exports.HuksSecretStore;
  await HP.protectOutbound({});
  assert.equal(await HP.readOutbound({}), bPlain);
  assert.ok((data[oc.APPLIED_FILE] || '').length > 8);
  assert.ok((data[oc.ENVELOPE_NEXT_FILE] || '').length > 20);
}
console.log('PASS actual HUKS protectOutbound: empty-store staging cleanup dual-fault keeps applied B readable');
