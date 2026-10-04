import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ready = require('./build/OutboundReady.js');

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log(`ok - ${name}`);
}

const trojan = JSON.stringify({
  protocol: 'trojan',
  settings: { servers: [{ address: 'jp.example.com', port: 443, password: 'x' }] },
  streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: 'jp.example.com', allowInsecure: false } },
});
const ss = JSON.stringify({
  protocol: 'shadowsocks',
  settings: { servers: [{ address: '1.2.3.4', port: 8388, method: 'aes-256-gcm', password: 'p' }] },
  streamSettings: { network: 'tcp' },
});
const reality = JSON.stringify({
  protocol: 'vless',
  settings: { vnext: [{ address: 'r.example.com', port: 443, users: [{ id: 'uuid' }] }] },
  streamSettings: {
    network: 'tcp',
    security: 'reality',
    realitySettings: { serverName: 'www.cloudflare.com', publicKey: 'abcd', shortId: '01', allowInsecure: false },
  },
});
const hy2 = JSON.stringify({
  protocol: 'hysteria2',
  settings: { servers: [{ address: 'h.example.com', port: 443, password: 'p' }] },
});
const insecure = JSON.stringify({
  protocol: 'trojan',
  settings: { servers: [{ address: 'jp.example.com', port: 443, password: 'x' }] },
  streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: 'jp.example.com', allowInsecure: true } },
});

test('trojan tls is runnable', () => {
  assert.equal(ready.outboundRunError(trojan), '');
  assert.equal(ready.outboundIsRunnable(trojan), true);
});

test('shadowsocks aead is runnable without tls', () => {
  assert.equal(ready.outboundRunError(ss), '');
});

test('vless reality is runnable', () => {
  assert.equal(ready.outboundRunError(reality), '');
});

test('hysteria2 is parsed but not runnable', () => {
  const err = ready.outboundRunError(hy2);
  assert.match(err, /hysteria2/);
  assert.equal(ready.outboundIsRunnable(hy2), false);
});

test('allowInsecure is rejected', () => {
  assert.match(ready.outboundRunError(insecure), /证书/);
});

console.log(`outboundready: ${passed} tests passed`);
