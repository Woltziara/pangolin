import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import {publicFailure} from './build/UserFacingCopy.js';
const source=readFileSync(new URL('../../entry/src/main/ets/services/SubscriptionManager.ets',import.meta.url),'utf8');
const ua=/export const APP_USER_AGENT: string = '([^']+)'/.exec(source)[1];
assert(ua.startsWith('mihomo/'));assert(ua.includes('Pangolin'));assert(/^[\x20-\x7e]+$/.test(ua));
assert.match(publicFailure('HTTP 403','fallback'),/服务器拒绝访问.*HTTP 403/);
assert(!publicFailure('HTTP 403','fallback').includes('网络不通'));
assert.match(publicFailure('HTTP 429','fallback'),/请求频率/);
assert.match(publicFailure('HTTP 404','fallback'),/地址未找到/);
const storeSource=readFileSync(new URL('../../entry/src/main/ets/services/SubscriptionStore.ets',import.meta.url),'utf8');
let disk='[]',ids=0;
const module={exports:{}};vm.runInNewContext(ts.transpileModule(storeSource,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,{
 module,exports:module.exports,console,require(n){
  if(n==='@kit.ArkTS')return {util:{generateRandomUUID(){return String(++ids);}}};
  if(n==='./StatusStore')return {StatusStore:{readJsonFile(){return disk;},writeJsonAtomic(_c,_f,v){disk=v;}}};
  throw Error(n);
 }
});
const store=module.exports.SubscriptionStore;
const a=store.add({},'Fixture','https://example.com/sub');
const b=store.add({},'',' https://example.com/sub ');
assert.equal(a.id,b.id);assert.equal(JSON.parse(disk).length,1);assert.equal(ids,1);
a.enabled=false;store.update({},a);assert.throws(()=>store.add({},'','https://example.com/sub'),/已关闭/);
console.log('PASS subscription compatibility: ASCII interoperable UA with real client suffix; precise HTTP errors; repeated import reuses source rather than duplicates');
