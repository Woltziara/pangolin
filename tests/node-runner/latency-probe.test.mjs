import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../../entry/src/main/ets/services/LatencyProbe.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const writes = [];
const requests = [];
let live = true;
const fakeStore = {
  readStatus() { return { generation: 'test-gen', desiredRunning: live, xrayRunning: live, forwarderOk: live, at: Date.now() }; },
  writeText(_ctx, file, text) {
    assert.ok(!text.includes('PRIVATE_PROXY_PASSWORD'));
    assert.ok(!text.includes('PRIVATE_PROXY_USER'));
    assert.ok(!text.includes('PRIVATE_RESPONSE_BODY'));
    assert.ok(!text.includes('PRIVATE_COOKIE'));
    writes.push({ file, data: JSON.parse(text) });
  }
};
const fakeHttp = {
  RequestMethod: { GET: 'GET', HEAD: 'HEAD' }, HttpDataType: { STRING: 1 },
  createHttp() {
    return {
      async request(url, options) {
        requests.push({ url, options });
        return {
          responseCode: 403,
          result: 'PRIVATE_RESPONSE_BODY', header: { 'Set-Cookie': 'PRIVATE_COOKIE' },
          performanceTiming: { dnsTiming: 1, tcpTiming: 2, tlsTiming: 3, firstSendTiming: 4, firstReceiveTiming: 5, totalFinishTiming: 6, totalTiming: 7 },
          connectionExtraInfo: { networkProtocolName: 'HTTP/2', isReusedConnection: false, isCacheHit: false,
            redirectCount: 0, remoteAddress: '127.0.0.1', localAddress: 'DO_NOT_LOG_LOCAL_IP', isProxyConnection: true }
        };
      },
      destroy() {}
    };
  }
};
const module = { exports: {} };
vm.runInNewContext(compiled, {
  exports: module.exports, module, Date, setTimeout, clearTimeout,
  require(name) {
    if (name === '@kit.NetworkKit') return { http: fakeHttp, connection: { Socks5DnsStrategy: { PROXY_MODE: 1 } } };
    if (name.endsWith('/StatusStore')) return { StatusStore: fakeStore };
    if (name.endsWith('/DataplaneCanary')) return { socksHttpCanary() { throw Error('not used'); } };
    if (name.endsWith('/TunnelNative')) return { getNativeStats() {
      return { protectMeasured: 1, protectTotalUs: 100, protectMaxUs: 100, protectTcp4: 1, protectTcp6: 0,
        protectUdp: 0, protectTcp4At: 0, protectTcp6At: 0 };
    } };
    throw Error(`Unexpected dependency: ${name}`);
  }
});
const probe = module.exports.LATENCY_PROBE;
await probe.runHttp({}, '../../invalid');
assert.equal(requests.length, 0);
const socks = { host: '127.0.0.1', port: 12345, user: 'PRIVATE_PROXY_USER', pass: 'PRIVATE_PROXY_PASSWORD' };
await probe.runHttp({}, 'native-test', socks, true);
assert.equal(requests.length, 6);
for (const { options } of requests) {
  assert.equal(options.usingCache, false);
  assert.equal(options.reuseConnections, false);
  assert.equal(options.usingSocks5Proxy.dnsStrategy, 1);
  assert.equal(options.usingSocks5Proxy.password, socks.pass);
  assert.equal(options.usingProxy, undefined);
}
const result = writes.at(-1);
assert.equal(result.file, 'latency-native-socks.json');
assert.equal(result.data.complete, true);
assert.equal(result.data.samples.length, 6);
assert.equal(result.data.samples[0].socksConfirmed, true);
assert.ok(!JSON.stringify(result).includes('DO_NOT_LOG_LOCAL_IP'));
await probe.runHttp({}, 'native-test', socks, true);
assert.equal(requests.length, 6, 'duplicate run must be ignored');
live = false;
await probe.runHttp({}, 'stopped-test');
assert.equal(requests.length, 6, 'stopped VPN must not cause diagnostic fetches');
assert.equal(writes.at(-1).data.outcome, 'session-not-live-or-changed');
console.log('PASS latency probe: bounded fixed targets, explicit SOCKS, fresh connections, no secrets/body/cookies, duplicate and stopped-session guards');
