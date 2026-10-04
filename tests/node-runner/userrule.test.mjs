// 穿山 Phase C2 用户分流规则 — UserRuleMap 真值测试（编译后的 TS 直接跑，不是镜像）。
// 运行：npm test（build.mjs 会把 entry/src/main/ets/core/UserRuleMap.ets 拷成 .ts 编译）。
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const map = require('./build/UserRuleMap.js');

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log(`ok - ${name}`);
}

const route = (domain, action, groupTag = '') => ({ domain, action, groupTag });

test('bare domain normalizes lowercase', () => {
  const r = map.normalizeDomainInput('  EXAMPLE.com ');
  assert.equal(r.ok, true);
  assert.equal(r.normalized, 'example.com');
});

test('wildcard *. strips to bare domain', () => {
  const r = map.normalizeDomainInput('*.Example.COM');
  assert.equal(r.ok, true);
  assert.equal(r.normalized, 'example.com');
});

test('regexp: passes through untouched', () => {
  const r = map.normalizeDomainInput('regexp:.*\\.googlevideo\\.com$');
  assert.equal(r.ok, true);
  assert.equal(r.normalized, 'regexp:.*\\.googlevideo\\.com$');
});

test('regexp: with empty expression rejected', () => {
  const r = map.normalizeDomainInput('regexp:');
  assert.equal(r.ok, false);
});

test('IPv4 / CIDR / IPv6 rejected with Chinese hint', () => {
  for (const input of ['1.2.3.4', '10.0.0.0/8', '::1', '192.168.1.1/24']) {
    const r = map.normalizeDomainInput(input);
    assert.equal(r.ok, false, input);
    assert.equal(r.error, '暂只支持域名规则', input);
  }
});

test('empty / garbage / no-dot rejected', () => {
  for (const input of ['', '   ', 'exa mple.com', '-bad.com', 'localhost', 'example.c',
    'a..com', '.example.com', 'example.com.']) {
    const r = map.normalizeDomainInput(input);
    assert.equal(r.ok, false, input);
  }
});

test('non-regexp colon prefix rejected', () => {
  const r = map.normalizeDomainInput('domain:example.com');
  assert.equal(r.ok, false);
  assert.equal(r.error, '只支持 regexp: 前缀的高级写法');
});

test('xrayDomainOf emits domain: syntax and regexp passthrough', () => {
  assert.equal(map.xrayDomainOf('example.com'), 'domain:example.com');
  assert.equal(map.xrayDomainOf('regexp:.*\\.x$'), 'regexp:.*\\.x$');
});

test('buildUserRoutingRules maps actions to outbound tags', () => {
  const rules = map.buildUserRoutingRules([
    route('example.com', 'direct'),
    route('openai.com', 'proxy'),
    route('yt.com', 'group', '影视'),
    route('us.com', 'group', '美西'),
    route('gone.com', 'group', '已删除组'),
  ], '影视', '美西');
  assert.equal(rules.length, 4);
  assert.deepEqual(rules[0], { type: 'field', domain: ['domain:example.com'], outboundTag: 'direct' });
  assert.deepEqual(rules[1], { type: 'field', domain: ['domain:openai.com'], outboundTag: 'proxy' });
  assert.equal(rules[2].outboundTag, 'proxy-yt');
  assert.equal(rules[3].outboundTag, 'proxy');
  const err = map.unmappedGroupRuleError([
    route('gone.com', 'group', '已删除组'),
  ], '影视', '美西');
  assert.match(err, /已删除组/);
});

test('unknown action and empty domain dropped', () => {
  const rules = map.buildUserRoutingRules([
    route('a.com', 'bogus'),
    route('', 'proxy'),
    route('b.com', 'direct'),
  ], '', '');
  assert.equal(rules.length, 1);
  assert.equal(rules[0].outboundTag, 'direct');
});

test('emit cap is 200 and truncates', () => {
  assert.equal(map.USER_RULE_MAX_EMIT, 200);
  const many = [];
  for (let i = 0; i < 250; i++) many.push(route(`d${i}.com`, 'proxy'));
  const rules = map.buildUserRoutingRules(many, '', '');
  assert.equal(rules.length, 200);
  assert.equal(rules[199].domain[0], 'domain:d199.com');
});

console.log(`userrule: ${passed} tests passed`);
