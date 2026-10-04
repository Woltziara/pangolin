import {legacyBoundary} from './helpers/legacy-boundaries.mjs';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source=n=>readFileSync(new URL(`../../entry/src/main/ets/${n}`,import.meta.url),'utf8');
const ctx={filesDir:'/fixture'},files=new Map(),handles=new Map();let now=1_800_000_000_000,fd=0;
const clock=class extends Date{static now(){return now;}};
const basename=p=>p.split('/').at(-1);
const fs={OpenMode:{WRITE_ONLY:1,CREATE:2,APPEND:4},accessSync:p=>files.has(basename(p)),
 readTextSync:p=>files.get(basename(p)),statSync:p=>({size:files.get(basename(p)).length}),
 openSync(p){const n=basename(p);if(!files.has(n))files.set(n,'');handles.set(++fd,n);return {fd};},
 writeSync(f,s){const n=handles.get(f);files.set(n,files.get(n)+s);return s.length;},
 fsyncSync(){},closeSync:f=>handles.delete(f),unlinkSync:p=>files.delete(basename(p)),
 renameSync(a,b){files.set(basename(b),files.get(basename(a)));files.delete(basename(a));}};
function load(src,deps){const module={exports:{}};vm.runInNewContext(ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
 {module,exports:module.exports,Date:clock,JSON,Array,Object,Math,Number,isFinite,console,require(n){if(!(n in deps)){const b=legacyBoundary(n);if(b!==undefined)return b;throw Error(n);}return deps[n];}});return module.exports;}
const J=load(source('services/RuntimeJournal.ets'),{'@kit.CoreFileKit':{fileIo:fs}}).RuntimeJournal;
let status={generation:'1800000000000',sessionRevision:1,phase:'UNPROVEN',at:now,vpnCreated:true,xrayRunning:true,payloadDigest:'12345678',
 lastCanary:'Google health=foreign.private.invalid direct=203.0.113.28:443',lastError:'connect [2001:db8::1234]:443 failed'};
let native={generation:status.generation,at:now,xrayRunning:true,tunRunning:true,protectTimeout:3,
 hevDiagnostics:JSON.stringify({rxErrors:2,tunRegResult:0,tunCounts:Array(13).fill(1),tunFd:123,host:'private.invalid'}),
 appRouting:{enabled:true,active:true,ownerQueryFailed:5,pending:2},protectDiagnostics:{apiRejected:7},secret:'do-not-export'};
J.sample(ctx,status,native);now+=31_000;status={...status,generation:'1800000031000',at:now};native={...native,generation:status.generation,at:now};J.sample(ctx,status,native);
files.set('native-stats.json',JSON.stringify(native));
files.set('applied-policy.json',JSON.stringify({generation:status.generation,payloadDigest:status.payloadDigest,channelMode:'single',routeMode:'rule',at:now,userRules:['private.invalid'],secret:'do-not-export'}));
const ledger={generation:status.generation,seq:70,events:Array.from({length:70},(_,i)=>({seq:i+1,kind:'tick',at:now,cookie:'credential-sentinel',
 direct:{message:'lookup foreign.private.invalid at 203.0.113.28:443 failed'},lastCanary:status.lastCanary}))};
const Store={readStatus:()=>status,readText:(_c,n)=>files.get(n)||'',writeText(_c,n,v){files.set(n,v);},listNames:()=>[...files.keys()],removeFile:(_c,n)=>files.delete(n)};
const D=load(source('services/DiagnosticReport.ets'),{
 './SystemExitEvidence':{SystemExitEvidence:{read:()=>[{eventName:'APP_KILLED',time:now-1000,reason:'LowMemoryKill'}]}},
 '../core/UserFacingCopy':{redactDiagnosticText:t=>t},'./UiFeedback':{UI_FEEDBACK_FILE:'ui-feedback.json'},
 '@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:1},async getBundleInfoForSelf(){return {versionName:'fixture'};}}},
 './EventStore':{EventStore:{load:()=>ledger}},'./NodeStore':{NodeStore:{maskEndpointAddress:()=> 'masked'}},
 './StatusStore':{StatusStore:Store},'./RuntimeJournal':{RuntimeJournal:J},'../net/DataplaneStatus':{serializeStatus:JSON.stringify}
}).DiagnosticReport;
let report=await D.build(ctx,[{name:'DNS',ok:false,skipped:false,verdict:'lookup foreign.private.invalid failed',advice:'203.0.113.28:443 timeout'}]);
assert.equal(report.runtimeJournal.count,2);assert.equal(report.runtimeSnapshot['n.protectTimeout'],3);
assert.equal(report.systemExitEvents[0].reason,'LowMemoryKill');
assert.equal(report.runtimeSnapshot['n.hev.rxErrors'],2);assert.equal(report.runtimeSnapshot['n.appRouting.ownerQueryFailed'],5);
assert.equal(report.runtimeSnapshot['n.protectDiagnostics.apiRejected'],7);
assert.equal(report.events.length,50);assert.equal(report.eventWindow.available,70);
assert.equal(report.snapshotFreshness.nativeMatchesSession,true);assert.equal(report.appliedPolicy.matchesSession,true);
assert(!JSON.stringify(report).includes('credential-sentinel'));assert(!JSON.stringify(report).includes('do-not-export'));assert(!JSON.stringify(report).includes('private.invalid'));
assert(!JSON.stringify(report).includes('203.0.113.28'));assert(!JSON.stringify(report).includes('2001:db8::1234'));
report.incident={reportedAt:now};const firstPath=D.write(ctx,report,true),saved=files.get(basename(firstPath));
status={...status,generation:'1800000999999'};await D.build(ctx,[]);
assert.equal(files.get(basename(firstPath)),saved,'later status cannot overwrite captured incident');
for(let i=0;i<6;i++){now++;D.write(ctx,report,true);}
assert.equal([...files.keys()].filter(n=>/^incident-report-\d+\.json$/.test(n)).length,5);
assert(D.latestIncident(ctx).endsWith(`${now}.json`));
files.set('native-stats.json','null');assert.equal((await D.build(ctx,[])).snapshotFreshness.nativeMatchesSession,false);
const vpn=source('vpn/TunnelVpnAbility.ets'),ui=source('pages/Diagnostics.ets');
assert(vpn.includes('RuntimeJournal.sample(this.context'));assert(vpn.includes('RuntimeJournal.event(this.context'));
assert(vpn.includes("native['appRouting'] = this.appRoutes?.diagnostics()"));
const incidentBody=ui.slice(ui.indexOf('private async saveIncident'),ui.indexOf('private async exportReport'));
assert(incidentBody.includes('DiagnosticReport.write(ctx, doc, true)'));assert(!/runChecks|startVpn|requestRecover|probeHttp/.test(incidentBody));
assert(ui.includes('StatusStore.readText(ctx, this.incidentName)'));
console.log('PASS actual journal + report: live native/HEV/AppRoute metrics, cross-session history, frozen incident, privacy, five-report retention, null/corrupt sidecar boundary, passive capture and VPN wiring');
