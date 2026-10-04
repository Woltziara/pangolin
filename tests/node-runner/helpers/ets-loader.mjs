import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
export const etsRoot = fileURLToPath(new URL('../../../entry/src/main/ets/', import.meta.url));
export const flush = async (n=25) => { for(let i=0;i<n;i++) await Promise.resolve(); };
export function deferred() { let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject}; }
export class Clock {
  now=1_800_000_000_000;next=1;timers=new Map();
  setTimeout=(fn,ms=0)=>{const id=this.next++;this.timers.set(id,{fn,at:this.now+ms,repeat:0});return id;};
  setInterval=(fn,ms)=>{const id=this.next++;this.timers.set(id,{fn,at:this.now+ms,repeat:ms});return id;};
  clearTimeout=id=>this.timers.delete(id);clearInterval=id=>this.timers.delete(id);
  globals() { const self=this;return {Date:class extends Date{static now(){return self.now;}},setTimeout:this.setTimeout,clearTimeout:this.clearTimeout,setInterval:this.setInterval,clearInterval:this.clearInterval}; }
  async advance(ms) {const end=this.now+ms;await flush();let turns=0;
    while(true){let id,item;for(const [k,v] of this.timers){if(v.at<=end&&(!item||v.at<item.at)){id=k;item=v;}}
      if(!item)break;if(++turns>20000)throw Error('unbounded fake timer loop');this.now=item.at;
      if(item.repeat)item.at+=item.repeat;else this.timers.delete(id);item.fn();await flush();}
    this.now=end;await flush();}
}
/** Full production modules; only explicitly named platform/storage boundaries
 * are substituted. There is no alternate implementation of the tested logic. */
export function makeLoader(mocks={},globals={}, {realLogging=false}={}) {
  const cache=new Map();const root=etsRoot;
  function load(path) {
    const key=path.startsWith(root)?path:resolve(root,path);const file=key.endsWith('.ets')?key:key+'.ets';
    if(cache.has(file))return cache.get(file).exports;
    const rel=file.slice(root.length).replace(/^\//,'');
    if(rel in mocks)return mocks[rel];
    if(!realLogging && rel==='services/AppLog.ets' && !('@kit.PerformanceAnalysisKit' in mocks)) return {AppLog:{info(){},debug(){},warn(){},error(){},fatal(){}}};
    // Existing decision fixtures explicitly isolate the persistence collaborator.
    // error-journal.test.mjs opts in to the production logger and tests its boundaries.
    if(!realLogging && rel==='services/ErrorJournal.ets')return {ERROR_JOURNAL_FILES:[],ErrorJournal:{start(){},record(){},error(){},read(){return {};}}};
    const source=readFileSync(file,'utf8');
    const result=ts.transpileModule(source,{reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}});
    const syntax=(result.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
    if(syntax.length)throw Error(ts.formatDiagnosticsWithColorAndContext(syntax,{getCanonicalFileName:x=>x,getCurrentDirectory:()=>root,getNewLine:()=> '\n'}));
    const module={exports:{}};cache.set(file,module);
    vm.runInNewContext(result.outputText,{module,exports:module.exports,console,Date,Map,Set,Promise,URL,
      Uint8Array,ArrayBuffer,TextEncoder,TextDecoder,setTimeout,clearTimeout,setInterval,clearInterval,...globals,
      require(n) {if(n in mocks)return mocks[n];if(n.startsWith('.'))return load(resolve(dirname(file),n));
        throw Error('Unmocked platform import '+n+' from '+rel);}
    },{filename:file});return module.exports;
  }
  return load;
}
