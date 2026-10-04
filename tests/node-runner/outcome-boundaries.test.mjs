import assert from 'node:assert/strict';
import vm from 'node:vm';import {readFileSync} from 'node:fs';
import {makeLoader,Clock,deferred,flush} from './helpers/ets-loader.mjs';
// Manual timeout belonging to an old network must not cancel the new network's work.
const clock=new Clock();let serial=0;
const owner={generation:'g',ownerInstance:'o',sessionRevision:1,networkEpoch:1,payloadDigest:'p',routeMode:'rule',networkState:'available',phase:'FORWARDER_RUNNING',desiredRunning:true,vpnCreated:true,tunFdValid:true,xrayRunning:true,forwarderOk:true,at:clock.now};
const load=makeLoader({'@kit.AbilityKit':{},'@kit.ArkTS':{util:{generateRandomUUID:()=>`batch-${++serial}`}},'@ohos.process':{},'@kit.NetworkKit':{},
 'vpn/VpnConstants.ets':{BUNDLE_NAME:'fixture'},'services/StatusStore.ets':{StatusStore:{readStatus:()=>({...owner,at:clock.now}),readText:()=>''}}},clock.globals());
const p=load('services/ProbeSelfCheck.ets').PROBE_SELF_CHECK,jobs=[];p.runFetch=async()=>{const d=deferred();jobs.push(d);return d.promise;};
p.startLoop({});await flush();const manual=p.checkNow({});await flush();owner.networkEpoch++;const newRun=p.tick({});await flush();const newWork=p.work;
await clock.advance(18010);assert.match(await manual,/超时/);assert.equal(p.work,newWork);assert.equal(newWork.valid,true);
jobs.forEach(d=>d.resolve(true));await newRun;await flush();p.stopLoop();
const summary=load('net/ProbeResult.ets').probeSummary(JSON.stringify({schema:2,generation:'g',ownerInstance:'o',revision:1,networkEpoch:2,policyDigest:'p',rid:'r',source:'entry-background',scope:'pangolin-ui-path',at:clock.now,googleHttp:200,cloudflareHttp:403,directHttp:200,dnsOk:true}),owner,clock.now);
assert(summary.includes('Google 未通过（HTTP 200）'));assert(summary.includes('Cloudflare 未通过（HTTP 403）'));
const text=readFileSync(new URL('../../scripts/huawei-sign-hap.js',import.meta.url),'utf8');const code=text.slice(text.indexOf('function grab('),text.indexOf('function readDirBytes('));const ctx={};vm.runInNewContext(code,ctx);
assert.equal(ctx.grab("keyPassword: 'SYNTHETIC'",'keyPassword'),'SYNTHETIC');assert.equal(ctx.grab('{"keyPassword": "SYNTHETIC"}','keyPassword'),'SYNTHETIC');assert.throws(()=>ctx.grab('{}','keyPassword'));
console.log('PASS late manual timeout isolates new work; 204 semantics consistent; actual private signing-profile parser accepts JSON/JSON5 (no signing performed)');
