import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import vm from 'node:vm';import ts from 'typescript';
import {etsRoot} from './ets-loader.mjs';
export function uiMethods(file,name,wanted,globals){
 const path=resolve(etsRoot,'pages',file+'.ets');
 const text=readFileSync(path,'utf8').replace('struct '+name+' {','class '+name+' {');
 const ast=ts.createSourceFile(path,text,ts.ScriptTarget.Latest,true);
 const cls=ast.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text===name);
 if(!cls)throw Error('missing production UI '+name);
 const bodies=wanted.map(k=>{const m=cls.members.find(n=>n.name?.getText(ast)===k);if(!m)throw Error(k);return m.getText(ast);}).join('\n');
 const context={console,Date,Promise,setTimeout,clearTimeout,...globals};
 vm.runInNewContext(ts.transpileModule('class Page{'+bodies+'}globalThis.Page=Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);
 return new context.Page();
}
