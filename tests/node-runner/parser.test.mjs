// 穿山 import-layer Node 单元测试。运行：npm test（先 npm install）。
// Fixtures 全部为合成数据（example.com / 127.0.0.1 / 假 UUID），无任何真实凭据。
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, '../fixtures/import');
const parser = require('./build/ShareLinkParser.js');
const sub = require('./build/SubscriptionParser.js');
const dedupe = require('./build/NodeDedupe.js');
const region = require('./build/RegionGuess.js');

const read = (name) => readFileSync(join(fixtures, name), 'utf8').trim();
const UUID = '00000000-0000-4000-8000-000000000000';

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log(`ok - ${name}`);
}

test('vmess base64 JSON link', () => {
  const node = parser.parseShareLink(read('vmess.txt'));
  assert.ok(node);
  assert.equal(node.protocol, 'vmess');
  assert.equal(node.server, 'hk1.example.com');
  assert.equal(node.port, 443);
  assert.equal(node.region, '中国香港');
  const outbound = JSON.parse(node.outboundJson);
  assert.equal(outbound.settings.vnext[0].users[0].id, UUID);
  assert.equal(outbound.streamSettings.network, 'ws');
  assert.equal(outbound.streamSettings.wsSettings.headers.Host, 'cdn.example.com');
  assert.equal(outbound.streamSettings.security, 'tls');
  assert.equal(outbound.streamSettings.tlsSettings.serverName, 'cdn.example.com');
});

test('vless + reality link', () => {
  const node = parser.parseShareLink(read('vless_reality.txt'));
  assert.ok(node);
  assert.equal(node.protocol, 'vless');
  assert.equal(node.server, 'us1.example.com');
  assert.equal(node.name, '美国 测试');
  assert.equal(node.region, '美国');
  const outbound = JSON.parse(node.outboundJson);
  const user = outbound.settings.vnext[0].users[0];
  assert.equal(user.id, UUID);
  assert.equal(user.flow, 'xtls-rprx-vision');
  assert.equal(outbound.streamSettings.security, 'reality');
  assert.equal(outbound.streamSettings.realitySettings.publicKey, 'FAKE_PUBLIC_KEY_EXAMPLE');
  assert.equal(outbound.streamSettings.realitySettings.shortId, 'ab');
});

test('trojan link defaults to tls', () => {
  const node = parser.parseShareLink(read('trojan.txt'));
  assert.ok(node);
  assert.equal(node.protocol, 'trojan');
  assert.equal(node.port, 8443);
  const outbound = JSON.parse(node.outboundJson);
  assert.equal(outbound.settings.servers[0].password, 'fake-password-123');
  assert.equal(outbound.streamSettings.security, 'tls');
  assert.equal(outbound.streamSettings.tlsSettings.allowInsecure, false);
});

test('ss SIP002 and legacy produce identical server/method/password', () => {
  const sip = parser.parseShareLink(read('ss_sip002.txt'));
  const legacy = parser.parseShareLink(read('ss_legacy.txt'));
  assert.ok(sip);
  assert.ok(legacy);
  const sipServer = JSON.parse(sip.outboundJson).settings.servers[0];
  const legacyServer = JSON.parse(legacy.outboundJson).settings.servers[0];
  assert.equal(sip.protocol, 'shadowsocks');
  assert.equal(sipServer.method, 'aes-128-gcm');
  assert.equal(sipServer.password, 'fake-ss-password');
  assert.equal(sipServer.address, 'sg1.example.com');
  assert.equal(sipServer.port, 8388);
  assert.equal(legacyServer.method, 'aes-256-gcm');
  assert.equal(legacyServer.password, 'fake-legacy-pass');
  assert.equal(legacyServer.address, '127.0.0.1');
  assert.equal(legacyServer.port, 18388);
});

test('hy2 link', () => {
  const node = parser.parseShareLink(read('hy2.txt'));
  assert.ok(node);
  assert.equal(node.protocol, 'hysteria2');
  assert.equal(node.region, '韩国');
  const server = JSON.parse(node.outboundJson).settings.servers[0];
  assert.equal(server.password, 'fake-hy2-auth');
  assert.equal(server.sni, 'kr1.example.com');
  assert.equal(server.insecure, true);
  assert.equal(server.obfsPassword, 'fake-obfs');
});

test('mixed batch: 2 nodes + 1 unsupported failure, junk line ignored', () => {
  const result = parser.parseShareLinksDetailed(read('mixed_batch.txt'));
  assert.equal(result.nodes.length, 2);
  assert.equal(result.failures.length, 1);
  assert.ok(result.failures[0].line.startsWith('snell://'));
  assert.match(result.failures[0].reason, /暂只支持/);
});

test('invalid link returns null and Chinese reason', () => {
  assert.equal(parser.parseShareLink('vless://@example.com:443'), null);
  const result = parser.parseShareLinksDetailed('vless://@example.com:443');
  assert.equal(result.nodes.length, 0);
  assert.equal(result.failures.length, 1);
  assert.match(result.failures[0].reason, /缺少用户 ID/);
});

test('whole-blob base64 subscription', () => {
  const outcome = sub.parseSubscriptionContent(read('subscription_base64.txt'));
  assert.equal(outcome.nodes.length, 2);
  assert.ok(outcome.format.startsWith('base64'));
  const protocols = outcome.nodes.map((n) => n.protocol).sort();
  assert.deepEqual(protocols, ['trojan', 'vless']);
});

test('minimal Clash YAML with 2 proxies', () => {
  const outcome = sub.parseSubscriptionContent(read('clash_min.yaml'));
  assert.equal(outcome.format, 'clash-yaml');
  assert.equal(outcome.nodes.length, 2);
  const ssNode = outcome.nodes.find((n) => n.protocol === 'shadowsocks');
  const trojanNode = outcome.nodes.find((n) => n.protocol === 'trojan');
  assert.ok(ssNode);
  assert.ok(trojanNode);
  assert.equal(ssNode.name, '香港 Clash SS');
  assert.equal(ssNode.region, '中国香港');
  const ssServer = JSON.parse(ssNode.outboundJson).settings.servers[0];
  assert.equal(ssServer.method, 'aes-128-gcm');
  assert.equal(ssServer.address, 'hk2.example.com');
  const trojanOutbound = JSON.parse(trojanNode.outboundJson);
  assert.equal(trojanOutbound.streamSettings.security, 'tls');
  assert.equal(trojanOutbound.streamSettings.tlsSettings.serverName, 'us2.example.com');
});

test('Clash YAML bare list markers preserve every proxy and nested ALPN', () => {
  const yaml = `# subscription-url: https://example.com/sub?token=fixture
proxies:
  -
    name: first
    type: trojan
    server: first.example.com
    port: 443
    password: fixture-one
    alpn:
      - h2
      - http/1.1
  -
    name: second
    type: trojan
    server: second.example.com
    port: 443
    password: fixture-two
    alpn:
      - h2
`;
  const result = sub.parseSubscriptionContent(yaml);
  assert.equal(result.nodes.length, 2);
  assert.deepEqual(result.nodes.map((n) => n.name), ['first', 'second']);
  const first = JSON.parse(result.nodes[0].outboundJson);
  assert.deepEqual(first.streamSettings.tlsSettings.alpn, ['h2', 'http/1.1']);
});

test('garbage input yields zero nodes, unknown format', () => {
  const outcome = sub.parseSubscriptionContent(read('garbage.txt'));
  assert.equal(outcome.nodes.length, 0);
  assert.equal(outcome.format, 'unknown');
});

test('classifyImport distinguishes node vs subscription', () => {
  assert.equal(sub.classifyImport(read('trojan.txt')), 'single-node');
  assert.equal(sub.classifyImport(read('mixed_batch.txt')), 'subscription-content');
  assert.equal(sub.classifyImport(read('subscription_base64.txt')), 'subscription-content');
  assert.equal(sub.classifyImport(read('clash_min.yaml')), 'subscription-content');
  assert.equal(sub.classifyImport('https://example.com/api/v1/sub?token=fake'), 'subscription-url');
  assert.equal(sub.classifyImport(read('garbage.txt')), 'unknown');
  assert.equal(sub.classifyImport('   '), 'unknown');
});

test('reverse export round-trips trojan and vless', () => {
  const trojan = parser.parseShareLink(read('trojan.txt'));
  const link = parser.formatOutboundJsonToShareLink(trojan.outboundJson, trojan.name);
  assert.ok(link.startsWith('trojan://'));
  const reparsed = parser.parseShareLink(link);
  assert.ok(reparsed);
  assert.equal(reparsed.server, trojan.server);
  assert.equal(reparsed.port, trojan.port);
  assert.equal(reparsed.protocol, 'trojan');

  const vless = parser.parseShareLink(read('vless_reality.txt'));
  const vlessLink = parser.formatOutboundJsonToShareLink(vless.outboundJson, vless.name);
  const vlessReparsed = parser.parseShareLink(vlessLink);
  assert.ok(vlessReparsed);
  const outbound = JSON.parse(vlessReparsed.outboundJson);
  assert.equal(outbound.streamSettings.security, 'reality');
  assert.equal(outbound.streamSettings.realitySettings.publicKey, 'FAKE_PUBLIC_KEY_EXAMPLE');
});

test('dedupe key ignores node name, keeps credentials', () => {
  const a = parser.parseShareLink(read('trojan.txt'));
  const same = read('trojan.txt').replace(encodeURIComponent('日本 trojan'), encodeURIComponent('改名'));
  const b = parser.parseShareLink(same);
  assert.ok(b);
  assert.equal(
    dedupe.nodeDedupeKey(a.protocol, a.outboundJson),
    dedupe.nodeDedupeKey(b.protocol, b.outboundJson)
  );
  const other = parser.parseShareLink(read('ss_sip002.txt'));
  assert.notEqual(
    dedupe.nodeDedupeKey(a.protocol, a.outboundJson),
    dedupe.nodeDedupeKey(other.protocol, other.outboundJson)
  );
});

test('region guesser keyword map', () => {
  assert.equal(region.guessRegion('香港 01', ''), '中国香港');
  assert.equal(region.guessRegion('HK Relay', ''), '中国香港');
  assert.equal(region.guessRegion('United States West', ''), '美国');
  assert.equal(region.guessRegion('JP-Tokyo', ''), '日本');
  assert.equal(region.guessRegion('Singapore SG', ''), '新加坡');
  assert.equal(region.guessRegion('台湾 节点', ''), '中国台湾');
  assert.equal(region.guessRegion('KR-Seoul', ''), '韩国');
  assert.equal(region.guessRegion('UK London', ''), '英国');
  assert.equal(region.guessRegion('DE Frankfurt', ''), '德国');
  assert.equal(region.guessRegion('火星节点', 'mars.example.com'), '其他');
  assert.equal(region.guessRegion('ukraine relay', ''), '其他'); // 词边界：uk 不命中 ukraine
});

console.log(`\n${passed} tests passed`);
