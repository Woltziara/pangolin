import assert from 'node:assert/strict';
import {makeLoader} from './helpers/ets-loader.mjs';

let disk='';
const load=makeLoader({
 '@kit.AbilityKit':{},
 'services/Revocations.ets':{Revocations:{revoke(){}}},
 'core/ShareLinkParser.ets':{formatOutboundJsonToShareLink(){return '';},ParsedNode:class{}},
 'services/StatusStore.ets':{StatusStore:{readJsonFile(){return disk;},writeJsonAtomic(_context,_name,value){disk=value;}}}
});
const Store=load('services/NodeStore.ets').NodeStore;
const outbound=password=>JSON.stringify({protocol:'trojan',tag:'proxy',settings:{servers:[{address:'edge.example',port:443,password}]},
  streamSettings:{network:'tcp',security:'tls',tlsSettings:{allowInsecure:false}}});
const makeStored=(id,source,password)=>({id,name:'美国 FW-US2',region:'美国',server:'edge.example',port:443,
  protocol:'trojan',outboundJson:outbound(password),rawLink:'',sourceId:source,favorite:true,group:'primary',customName:'我选的线路',
  addedAt:1,updatedAt:1,latencyMs:41,latencyText:'41ms',latencyAt:2});
const diskNode=node=>{const copy={...node,outbound:JSON.parse(node.outboundJson)};delete copy.outboundJson;return copy;};
const makeParsed=(password,stream={network:'tcp',security:'tls',tlsSettings:{allowInsecure:false}})=>({name:'美国 FW-US2',region:'美国',server:'edge.example',port:443,
  protocol:'trojan',outboundJson:JSON.stringify({protocol:'trojan',tag:'proxy',settings:{servers:[{address:'edge.example',port:443,password}]},streamSettings:stream}),rawLink:''});

disk=JSON.stringify({v:2,nodes:[diskNode(makeStored('fixed-us2','sub-old','previous')),diskNode(makeStored('other-source','sub-other','previous'))]});
let changed=Store.mergeRuntime({},[makeParsed('rotated')],'sub-old');
let nodes=Store.loadNodes({});
assert.equal(changed.updated,1);assert.equal(changed.added,0);assert.equal(nodes.length,2);
const pinned=nodes.find(n=>n.id==='fixed-us2');assert(pinned);assert.equal(JSON.parse(pinned.outboundJson).settings.servers[0].password,'rotated');
assert.equal(pinned.favorite,true);assert.equal(pinned.group,'primary');assert.equal(pinned.customName,'我选的线路');
assert.equal(pinned.latencyMs,-1,'old TCP timing cannot remain fresh after credentials rotate');
assert.equal(nodes.find(n=>n.id==='other-source').sourceId,'sub-other');

disk=JSON.stringify({v:2,nodes:[diskNode(makeStored('fixed-us2','sub-old','previous'))]});
changed=Store.mergeRuntime({},[makeParsed('rotated',{network:'ws',security:'tls',tlsSettings:{allowInsecure:false}})],'sub-old');
assert.equal(changed.updated,0,'transport changes cannot silently inherit pinned authorization');
assert(!Store.loadNodes({}).some(n=>n.id==='fixed-us2'),'normal source pruning still applies to an unambiguous replacement');

disk=JSON.stringify({v:2,nodes:[diskNode(makeStored('fixed-us2','sub-old','previous'))]});
changed=Store.mergeRuntime({},[makeParsed('new-a'),makeParsed('new-b')],'sub-old');
assert.equal(changed.rotationAmbiguous,true);assert(Store.loadNodes({}).some(n=>n.id==='fixed-us2'),
  'ambiguous same-name rotations retain the old pinned node instead of silently choosing one');
console.log('PASS actual subscription merge keeps a unique pinned ID through credential rotation, isolates sources and refuses ambiguous replacement');
