import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {nodeSpeedHint}=require('./build/NodeSpeedHint.js');
const samples=[{id:'a',label:'美国 US1',milliseconds:80},{id:'b',label:'美国 US2',milliseconds:30},{id:'c',label:'失败节点',milliseconds:-1}];
const candidate=nodeSpeedHint('a','美国',samples,true,'measured');
assert.match(candidate.current,/TCP 可达/);assert.match(candidate.tip,/端口能连仍可能无法代理上网/);
assert.equal(candidate.recommendedId,'','a faster port alone cannot authorize or recommend a route change');
assert.equal(nodeSpeedHint('a','美国',samples,false,'running').recommendedId,'');
assert.equal(nodeSpeedHint('a','美国',samples,true,'connection-changed').recommendedId,'');
assert.match(nodeSpeedHint('c','美国',samples,true,'measured').current,/未连通/);

const source=readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets',import.meta.url),'utf8').replace('struct Index {','class Index {');
const ast=ts.createSourceFile('Index.ts',source,ts.ScriptTarget.Latest,true);
const cls=ast.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='Index');
assert(!cls.members.some(n=>n.name?.getText(ast)==='useFasterNode'), 'old TCP-only switch handler must be removed');
const methods=['refreshNodeSpeed','shortName','testSelectedNode'].map(name=>cls.members.find(n=>n.name?.getText(ast)===name).getText(ast)).join('\n');
let now=100000,raw='',started=[];
const scope={Date:{now:()=>now},nodeSpeedHint,NodeSpeedEntry:class{},NODE_LATENCY_FILE:'node-latency-test.json',
 StatusStore:{readText:()=>raw},NodeStore:{displayName:n=>n.name},NODE_LATENCY_TEST:{async begin(_ctx,id){started.push(id);return 'run';}}};
vm.createContext(scope);
vm.runInContext(ts.transpileModule(`class Page{${methods}}globalThis.Page=Page;`,{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,scope);
const page=new scope.Page();Object.assign(page,{context:{},configuredNodes:samples.map(s=>({id:s.id,name:s.label,region:'美国'})),settings:{singleNodeId:'a'},dualChannel:false,
 nodeSpeedRunning:true,nodeSpeedStartedAt:now,nodeSpeedSelectedId:'a',nodeSpeedRunId:'run',nodeSpeedText:'',nodeSpeedTip:'',busy:false});
raw=JSON.stringify({runId:'run',region:'美国',samples,complete:true,outcome:'measured'});page.refreshNodeSpeed();
assert.match(page.nodeSpeedText,/TCP 可达/);assert.match(page.nodeSpeedTip,/无法代理上网/);
assert.equal(page.settings.singleNodeId,'a');
await page.testSelectedNode();assert.equal(started.at(-1),'a');
console.log('PASS live page treats TCP timing as port-only evidence and offers no credential-blind route recommendation');
