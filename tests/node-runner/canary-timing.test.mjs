import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(fileURLToPath(new URL('../../entry/src/main/ets/net/DataplaneCanary.ets', import.meta.url)), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;

async function replay({ auth = true, failHttp = false } = {}) {
  let clock = 1000;
  let closed = false;
  const responses = auth ? [[5, 2], [1, 0], [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]] :
    [[5, 0], [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]];
  let listener;
  const fake = {
    on(name, callback) { assert.equal(name, 'message'); listener = callback; },
    off() { listener = undefined; },
    async connect() { clock += 7; },
    async send() {
      clock += 3;
      if (responses.length) {
        const bytes = Uint8Array.from(responses.shift());
        listener({ message: bytes.buffer });
      } else if (!failHttp) {
        clock += 200;
        const bytes = Uint8Array.from(Buffer.from('HTTP/1.1 204 No Content\r\n\r\n'));
        listener({ message: bytes.buffer });
      }
    },
    async close() { clock += 11; closed = true; }
  };
  const module = { exports: {} };
  vm.runInNewContext(compiled, {
    exports: module.exports, module,
    require(name) { assert.equal(name, '@kit.NetworkKit'); return { socket: { constructTCPSocketInstance: () => fake } }; },
    Date: { now: () => clock }, setTimeout, clearTimeout, Uint8Array, ArrayBuffer
  });
  const result = await module.exports.socksHttpCanary('127.0.0.1', 12345, 'example.com', 80,
    'example.com', '/', 10, auth ? 'test-user' : '', auth ? 'test-pass' : '');
  assert.ok(closed);
  assert.equal(result.marks.localTcpDone, 7);
  assert.equal(result.marks.closeDone - result.marks.closeStart, 11);
  assert.equal(result.elapsedMs, result.marks.closeDone);
  if (failHttp) {
    assert.equal(result.ok, false);
    assert.equal(result.httpCode, 0);
    assert.equal(result.marks.firstHttpByte, -1);
    assert.equal(result.marks.statusLineDone, -1);
    assert.equal(result.marks.failureStage, 'http');
  } else {
    assert.equal(result.ok, true);
    assert.equal(result.httpCode, 204);
    assert.equal(result.marks.firstHttpByte - result.marks.httpSendStart, 203);
    assert.ok(result.marks.firstHttpByte > result.marks.connectReplyDone);
    assert.equal(result.marks.statusLineDone, result.marks.firstHttpByte);
    assert.equal(result.marks.failureStage, '');
    if (!auth) assert.equal(result.marks.authDone, result.marks.greetingDone);
  }
}

await replay();
await replay({ auth: false });
await replay({ failHttp: true });
console.log('PASS canary cumulative timing: authenticated, no-auth, HTTP timeout, first-byte boundary, close isolation');
