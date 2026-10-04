import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

function load(path, deps = {}, extra = {}) {
  const source = readFileSync(new URL('../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, { module, exports: module.exports, Date, setTimeout, clearTimeout,
    require(n) { if (!(n in deps)) throw Error('Unexpected import ' + n); return deps[n]; }, ...extra });
  return module.exports;
}
const parser = load('core/NodeEndpointSpec.ets');
const outbound = { protocol: 'trojan', settings: { servers: [{ address: 'node.test', port: 443, password: 'fixture-password' }] },
  streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: 'cert.test', allowInsecure: false } } };
const payload = JSON.stringify({ v: 3, us: outbound });
const spec = parser.nodeEndpointSpec(payload);
assert.equal(spec.host, 'node.test'); assert.equal(spec.serverName, 'cert.test');
assert.ok(!JSON.stringify(spec).includes('fixture-password'));
assert.equal(parser.nodeEndpointSpec('{broken'), null);
assert.equal(parser.nodeEndpointSpec(JSON.stringify({ ...outbound, protocol: 'unsupported' })), null);
assert.equal(parser.nodeEndpointSpec(JSON.stringify({ ...outbound, streamSettings: {
  ...outbound.streamSettings, tlsSettings: { ...outbound.streamSettings.tlsSettings, allowInsecure: true }
} })), null);

async function replay({ mismatch = false, tlsError = false } = {}) {
  let clock = 1000, tcpCloses = 0, tlsCloses = 0, upgraded = false;
  const writes = [];
  const tcp = {
    connected: false,
    async connect(o) { assert.equal(o.address.address, '203.0.113.10'); clock += 30; this.connected = true; },
    async close() { tcpCloses++; }
  };
  const tls = {
    async connect(o) {
      assert.equal(o.address.address, 'cert.test'); assert.equal(o.skipRemoteValidation, false);
      assert(o.secureOptions.protocols.includes('TLSv1.3'));
      clock += 120; if (tlsError) throw { code: 2303002 };
    },
    async getRemoteAddress() { return { address: mismatch ? '198.51.100.9' : '203.0.113.10' }; },
    async getProtocol() { return 'TLSv1.3'; },
    async close() { clock += 10; tlsCloses++; }
  };
  const module = load('net/NodeEndpointProbe.ets', {
    '@kit.NetworkKit': {
      connection: { async getAddressesByName(host) { assert.equal(host, 'node.test'); clock += 40; return [{ address: '203.0.113.10' }]; } },
      socket: { Protocol: { TLSv12: 'TLSv1.2', TLSv13: 'TLSv1.3' },
        constructTCPSocketInstance() { tcp.connected = false; return tcp; },
        constructTLSSocketInstance(got) { assert.equal(got, tcp); assert(tcp.connected); upgraded = true; return tls; } }
    },
    '../core/NodeEndpointSpec': parser,
    '../services/LatencyProbe': { LATENCY_PROBE: { validRunId(id) { return /^[a-zA-Z0-9_-]{1,64}$/.test(id); } } },
    '../services/StatusStore': { StatusStore: {
      readStatus() { return { generation: 'g1', desiredRunning: true, xrayRunning: true }; },
      writeText(_ctx, file, text) {
        assert.equal(file, 'latency-node-endpoint.json');
        for (const secret of ['fixture-password', 'node.test', 'cert.test', '203.0.113.10']) assert(!text.includes(secret));
        writes.push(JSON.parse(text));
      }
    } }
  }, { Date: { now: () => clock } });
  await module.NODE_ENDPOINT_PROBE.run({}, payload, 'g1', 'endpoint-test');
  const result = writes.at(-1);
  assert.equal(result.complete, true); assert.equal(result.samples.length, 2);
  assert(upgraded); assert.equal(tcpCloses, 0); assert.equal(tlsCloses, 2);
  for (const row of result.samples) {
    assert.equal(row.dnsDoneMs, 40); assert.equal(row.tcpDoneMs, 70);
    assert.equal(row.proxyAuthenticated, false);
    assert.equal(row.ok, !mismatch && !tlsError);
    if (tlsError) { assert.equal(row.failureStage, 'tls'); assert.equal(row.tlsVerified, false); }
    else { assert.equal(row.tlsDoneMs, 190); assert.equal(row.peerMatchesResolvedNode, !mismatch); }
  }
}
await replay(); await replay({ mismatch: true }); await replay({ tlsError: true });
console.log('PASS node endpoint: credential exclusion, CA verification, phase timing, TCP upgrade ownership, peer validation, TLS failure');

const runtime = load('core/XrayRuntime.ets', {
  './CoreInfo': { DEBUG_ACCESS: true },
  '../native/TunnelNative': { createNativeSocksSession() { throw Error('not needed'); } },
  './OutboundReady': load('core/OutboundReady.ets'),
  './UserRuleMap': load('core/UserRuleMap.ets'),
  './LineHealth': load('core/LineHealth.ets'),
  './AppRoutePayload': { parseAppRoutePayload() { return { config: { enabled: false, rules: [] }, nodes: [] }; } }
});
const fixture = JSON.stringify({ v: 4, single: outbound });
const socks = { host: '127.0.0.1', port: 12345, user: 'fixture', pass: 'fixture' };
const normal = JSON.parse(runtime.buildRuntimeXrayConfig(fixture, socks, '/private'));
const trace = JSON.parse(runtime.buildRuntimeXrayConfig(fixture, socks, '/private', '', true));
assert.equal(normal.log.loglevel, 'warning'); assert.equal(normal.log.error, undefined);
assert.equal(trace.log.loglevel, 'info'); assert.equal(trace.log.error, '/private/xray-timing.log');
delete normal.log; delete trace.log; assert.deepEqual(trace, normal);
assert.equal(JSON.parse(runtime.buildRuntimeXrayConfig(fixture, socks, '', '', true)).log.loglevel, 'warning');
console.log('PASS outbound trace: explicit opt-in only; routing, nodes and data-plane configuration unchanged');

const ruleCfg = JSON.parse(runtime.buildRuntimeXrayConfig(JSON.stringify({
  v: 4, single: outbound, routeMode: 'rule'
}), socks, '/private'));
assert.equal(ruleCfg.dns.tag, 'dns-internal');
assert.equal(ruleCfg.outbounds.some((o) => o.tag === 'dns-query-direct'), false);
const ruleDnsProxy = ruleCfg.routing.rules.find((r) => r.inboundTag && r.inboundTag[0] === 'dns-internal' && r.ip);
const ruleDnsDirect = ruleCfg.routing.rules.find((r) => r.inboundTag && r.inboundTag[0] === 'dns-internal' && !r.ip);
assert.equal(ruleDnsProxy.outboundTag, 'proxy');
assert.equal(ruleDnsDirect.outboundTag, 'direct');
assert.deepEqual(ruleDnsProxy.ip, ['1.1.1.1', '8.8.8.8']);
const dnsOutRule = ruleCfg.outbounds.find((o) => o.tag === 'dns-out');
assert.equal(dnsOutRule.streamSettings.sockopt.dialerProxy, 'proxy');
assert.equal(dnsOutRule.settings.address, '1.1.1.1');

const directCfg = JSON.parse(runtime.buildRuntimeXrayConfig(JSON.stringify({
  v: 4, single: outbound, routeMode: 'direct'
}), socks, '/private'));
assert.equal(directCfg.dns.tag, 'dns-internal');
assert.equal(directCfg.outbounds[0].tag, 'proxy', 'direct mode must not invent a new first outbound');
const directInternal = directCfg.routing.rules.filter((r) => r.inboundTag && r.inboundTag[0] === 'dns-internal');
assert.equal(directInternal.length, 1);
assert.equal(directInternal[0].outboundTag, 'direct');
assert.equal(directInternal[0].ip, undefined);
const tunDirect = directCfg.routing.rules.find((r) => r.inboundTag && r.inboundTag[0] === 'tun-in' && r.port !== '53');
assert.equal(tunDirect.outboundTag, 'direct');
const dnsOutDirect = directCfg.outbounds.find((o) => o.tag === 'dns-out');
assert.equal(dnsOutDirect.streamSettings.sockopt.dialerProxy, 'direct');
assert.equal(dnsOutDirect.settings.address, '223.5.5.5');
assert.equal(directCfg.routing.rules.some((r) => r.inboundTag && r.inboundTag[0] === 'dns-internal' && r.outboundTag === 'proxy'), false,
  'direct internal DNS must not depend on proxy');
const globalCfg = JSON.parse(runtime.buildRuntimeXrayConfig(JSON.stringify({
  v: 4, single: outbound, routeMode: 'global'
}), socks, '/private'));
assert.ok(globalCfg.routing.rules.some((r) => r.domain && r.domain.includes('geosite:cn')) === false);
assert.ok(globalCfg.routing.rules.some((r) => r.inboundTag && r.inboundTag[0] === 'dns-internal' && r.outboundTag === 'proxy'));
console.log('PASS runtime DNS: direct uses existing direct egress for internal DNS; rule/global keep split DNS and no invented outbounds');

const timing = load('core/OutboundTiming.ets');
const events = timing.outboundTimingEvents([
  '2026/09/06 18:00:01.123456 [Info] [12] transport/internet/tcp: dialing TCP to tcp:secret-node.test:443',
  '2026/09/06 18:00:01.523456 [Info] [12] proxy/trojan: tunneling request to tcp:chatgpt.com:443 via tcp:secret-node.test:443',
  '2026/09/06 18:00:01.623456 [Info] [13] transport/internet/tcp: dialing TCP to tcp:secret-node.test:443',
  '2026/09/06 18:00:01.923456 [Info] [13] proxy/trojan: tunneling request to tcp:private.test:443',
  '2026/09/06 18:00:01.923456 [Info] [14] proxy/trojan: tunneling request to tcp:chatgpt.com:443evil',
  'unknown private data'
].join('\n'));
assert.equal(events.length, 2); assert.equal(events[0].stage, 'node-dial-start');
assert.equal(events[1].stage, 'node-tls-ready'); assert.equal(events[1].target, 'chatgpt-https-head');
for (const excluded of ['secret', 'private', 'unknown', 'via']) assert(!JSON.stringify(events).includes(excluded));
console.log('PASS outbound timing export: exact allowlisted targets, same-session pairing, private data exclusion');
const appEvents = timing.chatAppTimingEvents([
  '2026/09/07 03:00:01.100 [Info] [20] app/dispatcher: taking detour [proxy] for [tcp:android.chat.openai.com:443]',
  '2026/09/07 03:00:01.110 [Info] [20] transport/internet/tcp: dialing TCP to tcp:secret-node.test:6021',
  '2026/09/07 03:00:01.500 [Info] [20] proxy/trojan: tunneling request to tcp:android.chat.openai.com:443 via tcp:secret-node.test:6021',
  '2026/09/07 03:00:10.500 [Warning] [20] failed: timeout secret-token',
  '2026/09/07 03:00:01.500 [Info] [21] proxy/trojan: tunneling request to tcp:chatgpt.com.evil.test:443',
  '2026/09/07 03:00:01.500 [Info] [22] proxy/trojan: tunneling request to tcp:private.test:443'
].join('\n'));
assert.equal(appEvents.length, 4);
assert.equal(appEvents[0].route, 'proxy');
assert.equal(appEvents[2].host, 'android.chat.openai.com');
assert.equal(appEvents[3].stage, 'timeout');
assert(!/secret|private|evil/.test(JSON.stringify(appEvents)));
console.log('PASS App trace: domain/route/stage whitelist, no raw messages or credentials');

let resolveCalls = 0;
let answers = [{address:'203.0.113.15'},{address:'2001:db8::1'},{address:'203.0.113.15'}];
const dnsDiagnostic = load('net/NodeAddressResolver.ets', {
  '@kit.NetworkKit': { connection: { async getAddressesByName(host) {
    assert.equal(host, 'node.test'); resolveCalls++; return answers;
  } } }
});
const originalConfig = JSON.parse(runtime.buildRuntimeXrayConfig(fixture, socks, '/private'));
function restoreDnsComparison(actual, original) {
  assert.equal(actual.dns.queryStrategy,'UseIP');
  for(let i=0;i<actual.dns.servers.length;i++) {
    assert.equal(actual.dns.servers[i].queryStrategy,'UseIPv4','website DNS retains IPv4 policy');
    delete actual.dns.servers[i].queryStrategy;
    if(typeof original.dns.servers[i]==='string') actual.dns.servers[i]=actual.dns.servers[i].address;
  }
  actual.dns.queryStrategy=original.dns.queryStrategy;
}
const resolvedConfig = JSON.parse(await dnsDiagnostic.withSystemResolvedNodes(JSON.stringify(originalConfig)));
for (let i = 0; i < originalConfig.outbounds.length; i++) {
  const original = originalConfig.outbounds[i];
  if (original.tag !== 'proxy' && original.tag !== 'proxy-yt') continue;
  assert.equal(resolvedConfig.outbounds[i].settings.servers[0].address, 'node.test');
  assert.equal(resolvedConfig.outbounds[i].streamSettings.tlsSettings.serverName, 'cert.test');
  assert.equal(resolvedConfig.outbounds[i].streamSettings.sockopt.domainStrategy, 'ForceIP');
  assert.deepEqual(resolvedConfig.outbounds[i].streamSettings.sockopt.happyEyeballs,
    {prioritizeIPv6:false,tryDelayMs:250,interleave:1,maxConcurrentTry:2});
  delete resolvedConfig.outbounds[i].streamSettings.sockopt;
}
assert.deepEqual(resolvedConfig.dns.hosts, {'node.test':['203.0.113.15','2001:db8::1']});
delete resolvedConfig.dns.hosts;
restoreDnsComparison(resolvedConfig,originalConfig);
assert.equal(resolveCalls, 1); assert.deepEqual(resolvedConfig, originalConfig);
answers=[{address:'203.0.113.16'}];
const refreshed=JSON.parse(await dnsDiagnostic.withSystemResolvedNodes(JSON.stringify(originalConfig)));
assert.equal(resolveCalls,2);assert.deepEqual(refreshed.dns.hosts,{'node.test':['203.0.113.16']});
for(const protocol of ['shadowsocks','vmess','vless']) {
  const c=JSON.parse(JSON.stringify(originalConfig));
  for(const o of c.outbounds.filter(o=>o.tag==='proxy'||o.tag==='proxy-yt')) {
    o.protocol=protocol;
    if(protocol!=='shadowsocks'){o.settings.vnext=o.settings.servers;delete o.settings.servers;}
    o.streamSettings.network='ws';o.streamSettings.wsSettings={path:'/kept',headers:{Host:'web.test'}};
    o.streamSettings.sockopt={tcpKeepAliveIdle:30};
  }
  const r=JSON.parse(await dnsDiagnostic.withSystemResolvedNodes(JSON.stringify(c)));
  for(const o of r.outbounds.filter(o=>o.tag==='proxy'||o.tag==='proxy-yt')) {
    assert.equal(o.streamSettings.sockopt.domainStrategy,'ForceIP');
    assert.equal(o.streamSettings.sockopt.tcpKeepAliveIdle,30);
    delete o.streamSettings.sockopt.domainStrategy;
    delete o.streamSettings.sockopt.happyEyeballs;
  }
  delete r.dns.hosts;restoreDnsComparison(r,c);assert.deepEqual(r,c);
}
answers=[{address:'2001:db8::1'}];
const ipv6only=JSON.parse(await dnsDiagnostic.withSystemResolvedNodes(JSON.stringify(originalConfig)));
assert.deepEqual(ipv6only.dns.hosts,{'node.test':['2001:db8::1']});
const literal=JSON.parse(JSON.stringify(originalConfig));literal.outbounds[0].settings.servers[0].address='2001:db8::1';
const literalResult=JSON.parse(await dnsDiagnostic.withSystemResolvedNodes(JSON.stringify(literal)));
assert.equal(literalResult.outbounds[0].settings.servers[0].address,'2001:db8::1');
assert.equal(literalResult.outbounds[0].streamSettings.tlsSettings.serverName,'cert.test');
answers=[];
await assert.rejects(dnsDiagnostic.withSystemResolvedNodes(JSON.stringify(originalConfig)),/没有可用的 IPv4 或 IPv6/);
console.log('PASS dual-stack production: IPv4-first bounded native race, AAAA-only and literal IPv6, fresh DNS, deduplication, endpoint/SNI/transport/credentials/routing preservation');

let connectAddresses=[], closed=0, noAnswers=false;
const familyCanary=load('net/DataplaneCanary.ets',{
 '@kit.NetworkKit':{
  connection:{async getAddressesByName(){return noAnswers?[]:[{address:'203.0.113.15'},{address:'2001:db8::1'}];}},
  socket:{constructTCPSocketInstance(){return {
   off(){},
   async connect(o){connectAddresses.push(o.address);if(o.address.family===1)throw Error('fixture-v4-unreachable');},
   async close(){closed++;}
  };}}
 }
});
assert.equal((await familyCanary.tcpConnectCanary('dual.test',443,100)).ok,true);
assert.deepEqual(connectAddresses.map(a=>a.family),[1,2]);assert.equal(closed,2);
connectAddresses=[];
assert.equal((await familyCanary.tcpConnectCanary('[2001:db8::1]',443,100)).ok,true);
assert.equal(connectAddresses[0].address,'2001:db8::1');assert.equal(connectAddresses[0].family,2);
noAnswers=true;assert.equal((await familyCanary.tcpConnectCanary('empty.test',443,100)).ok,false);
console.log('PASS automatic node ranking TCP helper: literal IPv6, IPv4 failure -> IPv6, no-address error, every attempt socket closed');
