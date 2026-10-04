import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
import {classifyImport,parseSubscriptionContent} from './build/SubscriptionParser.js';
const source=readFileSync(new URL('../../entry/src/main/ets/pages/Import.ets',import.meta.url),'utf8');
const methods=source.slice(source.indexOf('  private runTextPreview('),source.indexOf('  private showPreview('));
let keyboardStops=0,toasts=[],fail=false;
const code=ts.transpileModule('class Harness { '+methods+' }; globalThis.Harness=Harness;',{
  compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
const box={SubscriptionManager:{importFromText(_ctx,text){
  if(fail)throw Error('fixture parser error');
  const parsed=parseSubscriptionContent(text);
  return {kind:classifyImport(text),nodes:parsed.nodes,failures:parsed.failures};
}},UiFeedback:{failure(_ctx,_op,_error,fallback){return fallback;}},promptAction:{showToast(x){toasts.push(x.message);}},SOURCE_IMPORT:'import'};
vm.runInNewContext(code,box);
const h=new box.Harness();h.context={};h.pasteController={stopEditing(){keyboardStops++;}};
h.showPreview=()=>{h.previewVisible=true;h.previewKind='nodes';};
h.runTextPreview('https://example.com/subscription');
assert.equal(h.previewVisible,true);assert.equal(h.previewKind,'subscription-url');assert.equal(h.lastError,'');assert.equal(keyboardStops,1);
h.runTextPreview('not-a-link');assert.equal(h.previewVisible,false);assert(h.lastError.length>0);assert.equal(toasts.at(-1),h.lastError);
fail=true;assert.doesNotThrow(()=>h.runTextPreview('https://example.com/subscription'));assert.equal(h.previewVisible,false);assert.match(h.lastError,/识别未完成/);
h.context=null;h.runTextPreview('https://example.com/subscription');assert.match(h.lastError,/尚未准备好/);
assert(source.includes('.bindSheet($$this.previewVisible, this.ImportResultSheet()'));
assert(source.indexOf('this.PreviewSection()')<source.indexOf("Text('手动添加')"),'results must be in the modal builder, not after the manual form');
console.log('PASS actual import handler: URL result, invalid input, thrown parser, missing context, keyboard dismissal; result bound to visible sheet');
