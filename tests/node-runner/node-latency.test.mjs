import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const source=readFileSync(new URL('../../entry/src/main/ets/services/NodeLatencyTest.ets',import.meta.url),'utf8');
const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
let now=100000,live=true,sockets=0,active=0,maxActive=0,writes=[],wants=[];
const nodes=Array.from({length:9},(_,i)=>({id:'id'+i,server:i===8?'ipv6-only.test':'node.test',port:443,outboundJson:'PRIVATE_FIXTURE_PASSWORD'}));
const deps={
  '@kit.NetworkKit':{connection:{NetBearType:{BEARER_VPN:4},async getAllNets(){return [];},async getNetCapabilities(){return {bearerTypes:[]};},
    async getAddressesByName(host){return [{address:host==='ipv6-only.test'?'2001:db8::1':'203.0.113.10'}];}},
    socket:{constructTCPSocketInstance(){sockets++;active++;maxActive=Math.max(maxActive,active);return {
      async connect(options){assert(['203.0.113.10','2001:db8::1'].includes(options.address.address));assert.equal(options.address.family,options.address.address.includes(':')?2:1);now+=25;},
      async close(){now+=500;active--;}};}},vpnExtension:{async startVpnExtensionAbility(want){wants.push(want);}}},
  './NodeStore':{NodeStore:{loadNodes(){return nodes;}}},
  './StatusStore':{StatusStore:{readStatus(){return {generation:'g',desiredRunning:live};},writeText(_ctx,file,text){
    assert.equal(file,'node-latency-test.json');for(const secret of ['PRIVATE_FIXTURE_PASSWORD','node.test','203.0.113.10'])assert(!text.includes(secret));writes.push(JSON.parse(text));}}},
  '../net/ConnectionHealth':{isConnectionEstablished(s){return s.desiredRunning;}},
  '../vpn/VpnConstants':{createVpnAbilityWant(){return {bundleName:'fixture',abilityName:'vpn'};}}
};
const module={exports:{}};vm.runInNewContext(compiled,{module,exports:module.exports,Date:{now:()=>now},setTimeout,clearTimeout,
  require(n){if(!(n in deps))throw Error(n);return deps[n];}});
const test=module.exports.NODE_LATENCY_TEST;
const isolated=await test.sample(nodes[0]);assert.equal(isolated.milliseconds,25,'socket teardown is excluded from reported delay');
const before=sockets;const runId=await test.begin({});assert.equal(sockets,before,'connected UI does not measure through its own VPN path');
assert.equal(wants.length,1);assert.equal(wants[0].parameters.command,'diagnose-node-latency');assert.equal(wants[0].parameters.generation,'g');
await test.run({},runId,'g');const batch=writes.at(-1);assert.equal(batch.complete,true);assert.equal(batch.outcome,'measured');
assert.equal(batch.samples.length,9);assert.equal(batch.samples[8].milliseconds,25);assert(maxActive<=4);
const literalSample=await test.sample({id:'literal',server:'[2001:db8::1]',port:443});assert.equal(literalSample.milliseconds,25);
const completedSockets=sockets;await test.run({},runId,'g');assert.equal(sockets,completedSockets);
live=false;await test.run({},'stopped-g','g');assert.equal(sockets,completedSockets);assert.equal(writes.at(-1).outcome,'connection-changed');
await test.run({},'../invalid','');assert.equal(sockets,completedSockets);
assert.equal(active,0);console.log('PASS node latency: protected-owner dispatch, IPv4 + AAAA-only + literal IPv6, teardown-excluded timing, bounded parallelism, incremental complete results, no credentials, duplicate/stale-run guards');
nodes.forEach((n,i)=>{n.region=i===0||i===2?'美国':'香港';});
await test.run({},'same-region','','id2');
assert.deepEqual(writes.at(-1).samples.map(s=>s.id),['id2','id0']);
assert.equal(writes.at(-1).region,'美国'); assert.equal(writes.at(-1).selectedNodeId,'id2');
const scopedSockets=sockets; await test.run({},'missing-node','','missing');
assert.equal(sockets,scopedSockets); assert.equal(writes.at(-1).outcome,'selected-node-missing');
nodes[2].region=''; await test.run({},'unknown-region','','id2');
assert.deepEqual(writes.at(-1).samples.map(s=>s.id),['id2'],'unknown region must not broaden into all regions');
live=true; await test.begin({},'id2'); assert.equal(wants.at(-1).parameters.selectedNodeId,'id2');
console.log('PASS selected-node scope: selected first, same-region only, missing/unknown region safe, VPN owner gets selected ID');
