import { DEBUG_ACCESS } from './CoreInfo';
import { LINE_HEALTH_HOST, LINE_HEALTH_HOST_B } from './LineHealth';
import { createNativeSocksSession } from '../native/TunnelNative';
import { outboundRunError } from './OutboundReady';
import { buildUserRoutingRules, unmappedGroupRuleError, UserRuleRoute } from './UserRuleMap';
import { AppNodePort, parseAppRoutePayload } from './AppRoutePayload';

export const VPN_DATA_SOCKS_HOST: string = '127.0.0.1';
export const VPN_DATA_SOCKS_PORT: number = 18082;
export const METRICS_HOST: string = '127.0.0.1';
export const METRICS_PORT: number = 18086;
export const METRICS_SERVER_URL: string = 'http://127.0.0.1:18086/debug/vars';
export const XRAY_CONFIG_FILE: string = 'xray-config.json';
export const NODE_META_FILE: string = 'node-meta.json';
export const DATAPLANE_STATUS_FILE: string = 'dataplane-status.json';

export interface NodeMeta {
  name: string;
  region: string;
  server: string;
  port: number;
  protocol: string;
  split: boolean;
  hkName: string;
  ytName: string;
  usName: string;
}

export interface SocksInboundSettings {
  udp: boolean;
  auth: string;
}

export interface EmptySettings {
}

class EmptyObject {
}

export class SocksSession {
  host: string = '127.0.0.1';
  port: number = 0;
  user: string = '';
  pass: string = '';
}

export function newSocksSession(): SocksSession {
  const session = new SocksSession();
  let lastError: string = '未分配';
  for (let attempt = 0; attempt < 5; attempt++) {
    const native = createNativeSocksSession();
    if (native.ok && native.port > 0 && native.user.length > 0 && native.pass.length > 0) {
      session.port = native.port;
      session.user = native.user;
      session.pass = native.pass;
      return session;
    }
    lastError = native.message;
  }
  throw new Error(`无法分配本机 SOCKS 端口：${lastError}`);
}

// routeMode（Phase C 新增，可选尾参）：'rule'（默认，保持既有规则链逐字节不变）、
// 'global'（除局域网/DNS/QUIC 封锁等安全规则外全部走代理，去掉国内直连规则）、
// 'direct'（全部直连：保持 VPN 在线但不代理，便于快速切回；IPv6 仍按既有防泄漏
// 设计 blackhole，DNS 劫持仍留在本机）。调用方不传时从 payload 的 routeMode
// 字段读取（SplitRouter 写 payload 时已注入），两者都缺省即 'rule'。
export function buildRuntimeXrayConfig(outboundJson: string, socks: SocksSession, filesDir: string,
  routeMode: string = '', outboundTrace: boolean = false, appPorts: AppNodePort[] = []): string {
  const parsed = JSON.parse(outboundJson) as Record<string, Object>;
  const version = asInt(parsed['v'], 0);
  let outbound: Record<string, Object> = parsed;
  let ytOutbound: Record<string, Object> = parsed;
  let hasYt = false;
  if (version === 4) {
    // v=4 固定节点（Phase C 手动选路）：单个节点同时承担 proxy 与 proxy-yt
    // 两个分流标签，规则链无需任何改动即可工作。
    outbound = cloneOutbound(parsed['single'], '固定节点配置缺少节点');
    ytOutbound = cloneOutbound(parsed['single'], '固定节点配置缺少节点');
    hasYt = true;
  } else if (version === 3) {
    outbound = cloneOutbound(parsed['us'], '分流配置缺少美国节点');
    ytOutbound = cloneOutbound(parsed['yt'], '分流配置缺少 YouTube 节点');
    hasYt = true;
  } else if (version === 2) {
    outbound = cloneOutbound(parsed['us'], '分流配置缺少美国节点');
  }
  const mode: string = resolveRouteMode(routeMode, parsed['routeMode']);
  const appRouting = mode === 'direct' ? parseAppRoutePayload(undefined) : parseAppRoutePayload(parsed['appRouting']);
  const appRules: Array<Record<string, Object>> = [];
  const appOutbounds: Object[] = [];
  const roleRouting: boolean = parsed['routingProfile'] === 'chatgpt-general';
  const generalTag: string = roleRouting && hasYt ? 'proxy-yt' : 'proxy';
  const parsedRoutes = parseUserRuleRoutes(parsed['userRules']);
  if (mode !== 'direct') {
    const groupErr = unmappedGroupRuleError(parsedRoutes, asString(parsed['ytGroup'], ''),
      asString(parsed['usGroup'], ''));
    if (groupErr.length > 0) {
      throw new Error(groupErr);
    }
  }
  const userRuleRoutes: Array<Record<string, Object>> = buildUserRoutingRules(
    parsedRoutes, asString(parsed['ytGroup'], ''), asString(parsed['usGroup'], ''), generalTag);
  outbound['tag'] = 'proxy';
  enforceOutboundReady(outbound);
  if (hasYt) {
    ytOutbound['tag'] = 'proxy-yt';
    enforceOutboundReady(ytOutbound);
  }
  const youtubeTag: string = hasYt ? 'proxy-yt' : 'proxy';

  const config: Record<string, Object> = {};
  const log: Record<string, string> = {};
  log['loglevel'] = 'warning';
  // Explicit diagnostic session only. Never enable payload/debug logging.
  if (outboundTrace && filesDir.length > 0) {
    log['loglevel'] = 'info';
    log['error'] = `${filesDir}/xray-timing.log`;
  }
  if (DEBUG_ACCESS && filesDir.length > 0) {
    log['access'] = `${filesDir}/xray-access.log`;
  }
  config['log'] = log;

  const dns: Record<string, Object> = {};
  dns['queryStrategy'] = 'UseIPv4';
  dns['tag'] = 'dns-internal';
  const foreignDns: Record<string, Object> = {};
  foreignDns['address'] = '1.1.1.1';
  foreignDns['domains'] = [
    'geosite:geolocation-!cn',
    'geosite:google',
    'geosite:youtube',
    'geosite:openai',
    'domain:openai.com',
    'domain:chatgpt.com',
    'domain:oaistatic.com',
    'domain:oaiusercontent.com',
    'domain:challenges.cloudflare.com'
  ];
  const cnDns: Record<string, Object> = {};
  cnDns['address'] = '223.5.5.5';
  cnDns['domains'] = ['geosite:cn'];
  cnDns['expectIPs'] = ['geoip:cn'];
  const dnsServers: Object[] = [foreignDns, cnDns, '1.1.1.1', '8.8.8.8'];
  dns['servers'] = dnsServers;
  config['dns'] = dns;

  const socksSettings: Record<string, Object> = {};
  socksSettings['udp'] = true;
  socksSettings['auth'] = 'password';
  const account: Record<string, string> = {};
  account['user'] = socks.user;
  account['pass'] = socks.pass;
  socksSettings['accounts'] = [account];

  const sniffing: Record<string, Object> = {};
  sniffing['enabled'] = true;
  sniffing['destOverride'] = ['http', 'tls', 'quic'];
  // routeOnly=true keeps the original IP, so a poisoned LAN DNS answer in
  // geoip:cn is DIRECT even when SNI is youtube.com. Override dest from SNI.

  const tunInbound: Record<string, Object> = {};
  tunInbound['tag'] = 'tun-in';
  tunInbound['listen'] = socks.host;
  tunInbound['port'] = socks.port;
  tunInbound['protocol'] = 'socks';
  tunInbound['settings'] = socksSettings;
  tunInbound['sniffing'] = sniffing;

  const inbounds: Object[] = [tunInbound];
  const inboundTags: string[] = ['tun-in'];
  const usedPorts = new Set<number>(); usedPorts.add(socks.port);
  if (appRouting.config.enabled) {
    const nodeIds: string[] = [];
    appRouting.config.rules.forEach((rule) => {
      if (rule.enabled && nodeIds.indexOf(rule.nodeId) < 0) { nodeIds.push(rule.nodeId); }
    });
    nodeIds.forEach((nodeId: string, index: number) => {
      const node = appRouting.nodes.find((item) => item.nodeId === nodeId);
      const mapping = appPorts.find((item: AppNodePort) => item.nodeId === nodeId);
      if (node === undefined || mapping === undefined || !Number.isInteger(mapping.port) ||
        mapping.port < 1 || mapping.port > 65535 || usedPorts.has(mapping.port)) {
        throw new Error('App 分流节点或本机端口未就绪');
      }
      usedPorts.add(mapping.port);
      const tag = `app-node-${index}`;
      const inbound = JSON.parse(JSON.stringify(tunInbound)) as Record<string, Object>;
      inbound['tag'] = tag; inbound['port'] = mapping.port;
      inbounds.push(inbound); inboundTags.push(tag);
      const appOutbound = cloneOutbound(node.outbound, 'App 节点配置无效');
      appOutbound['tag'] = tag; enforceOutboundReady(appOutbound); appOutbounds.push(appOutbound);
      const rule: Record<string, Object> = {};
      rule['type'] = 'field'; rule['inboundTag'] = [tag]; rule['outboundTag'] = tag;
      appRules.push(rule);
    });
  }
  config['inbounds'] = inbounds;

  const direct: Record<string, Object> = {};
  direct['tag'] = 'direct';
  direct['protocol'] = 'freedom';
  direct['settings'] = new EmptyObject();

  const block: Record<string, Object> = {};
  block['tag'] = 'block';
  block['protocol'] = 'blackhole';
  block['settings'] = new EmptyObject();

  const dnsOut: Record<string, Object> = {};
  dnsOut['tag'] = 'dns-out';
  dnsOut['protocol'] = 'dns';
  const dnsOutSettings: Record<string, Object> = {};
  dnsOutSettings['address'] = mode === 'direct' ? '223.5.5.5' : '1.1.1.1';
  dnsOutSettings['port'] = 53;
  dnsOutSettings['network'] = 'udp';
  dnsOut['settings'] = dnsOutSettings;
  const dnsOutStream: Record<string, Object> = {};
  const dnsOutSockopt: Record<string, Object> = {};
  dnsOutSockopt['dialerProxy'] = mode === 'direct' ? 'direct' : 'proxy';
  dnsOutStream['sockopt'] = dnsOutSockopt;
  dnsOut['streamSettings'] = dnsOutStream;

  const outbounds: Object[] = [outbound];
  if (hasYt) {
    outbounds.push(ytOutbound);
  }
  outbounds.push(direct);
  outbounds.push(block);
  outbounds.push(dnsOut);
  appOutbounds.forEach((item: Object) => { outbounds.push(item); });
  config['outbounds'] = outbounds;

  const dnsHijack: Record<string, Object> = {};
  dnsHijack['type'] = 'field';
  dnsHijack['inboundTag'] = inboundTags;
  dnsHijack['port'] = '53';
  dnsHijack['network'] = 'udp,tcp';
  dnsHijack['outboundTag'] = 'dns-out';

  const dnsInternalDirect: Record<string, Object> = {};
  dnsInternalDirect['type'] = 'field';
  dnsInternalDirect['inboundTag'] = ['dns-internal'];
  dnsInternalDirect['outboundTag'] = 'direct';

  const dnsInternalProxy: Record<string, Object> = {};
  dnsInternalProxy['type'] = 'field';
  dnsInternalProxy['inboundTag'] = ['dns-internal'];
  dnsInternalProxy['ip'] = ['1.1.1.1', '8.8.8.8'];
  dnsInternalProxy['outboundTag'] = 'proxy';

  const dummyV6: Record<string, Object> = {};
  dummyV6['type'] = 'field';
  dummyV6['ip'] = ['2001::1', '::1'];
  dummyV6['outboundTag'] = 'block';

  const quicRule: Record<string, Object> = {};
  quicRule['type'] = 'field';
  quicRule['network'] = 'udp';
  quicRule['port'] = '443';
  quicRule['domain'] = [
    'geosite:youtube',
    'domain:youtube.com',
    'domain:googlevideo.com',
    'domain:ytimg.com'
  ];
  quicRule['outboundTag'] = 'block';

  const privateRule: Record<string, Object> = {};
  privateRule['type'] = 'field';
  privateRule['ip'] = [
    'geoip:private',
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '224.0.0.0/4'
  ];
  privateRule['outboundTag'] = 'direct';

  const youtubeRule: Record<string, Object> = {};
  youtubeRule['type'] = 'field';
  youtubeRule['network'] = 'tcp';
  youtubeRule['domain'] = [
    'geosite:youtube',
    'domain:youtube.com',
    'domain:youtu.be',
    'domain:googlevideo.com',
    'domain:ytimg.com',
    'domain:ggpht.com',
    'domain:youtube-nocookie.com',
    'full:youtubei.googleapis.com'
  ];
  youtubeRule['outboundTag'] = youtubeTag;

  const proxyProbeRule: Record<string, Object> = {};
  proxyProbeRule['type'] = 'field';
  proxyProbeRule['domain'] = [
    'geosite:google',
    'geosite:openai',
    'full:example.com',
    'domain:example.com',
    'full:www.google.com',
    'domain:google.com',
    'domain:googleapis.com',
    'domain:gstatic.com',
    'domain:googleusercontent.com',
    'domain:openai.com',
    'domain:chatgpt.com',
    'domain:oaistatic.com',
    'domain:oaiusercontent.com',
    'domain:auth0.com',
    'domain:challenges.cloudflare.com',
    'domain:featuregates.org',
    'domain:statsigapi.net',
    'domain:statsig.com'
  ];
  proxyProbeRule['outboundTag'] = 'proxy';

  const lineHealthRule: Record<string, Object> = {};
  lineHealthRule['type'] = 'field';
  lineHealthRule['domain'] = [`full:${LINE_HEALTH_HOST}`, `domain:${LINE_HEALTH_HOST}`,
    `full:${LINE_HEALTH_HOST_B}`, `domain:${LINE_HEALTH_HOST_B}`];
  lineHealthRule['outboundTag'] = 'proxy';

  const chatgptRule: Record<string, Object> = {};
  chatgptRule['type'] = 'field';
  chatgptRule['domain'] = [
    'geosite:openai', 'domain:openai.com', 'domain:chatgpt.com', 'domain:oaistatic.com',
    'domain:oaiusercontent.com', 'domain:auth0.com', 'domain:challenges.cloudflare.com',
    'domain:featuregates.org', 'domain:statsigapi.net', 'domain:statsig.com'
  ];
  chatgptRule['outboundTag'] = 'proxy';
  if (roleRouting) {
    proxyProbeRule['domain'] = [
      'geosite:google', 'full:example.com', 'domain:example.com', 'domain:google.com',
      'domain:googleapis.com', 'domain:gstatic.com', 'domain:googleusercontent.com'
    ];
    proxyProbeRule['outboundTag'] = generalTag;
  }

  const cnDomainRule: Record<string, Object> = {};
  cnDomainRule['type'] = 'field';
  cnDomainRule['domain'] = [
    'geosite:cn',
    'domain:baidu.com',
    'domain:qq.com',
    'domain:weixin.qq.com',
    'domain:wechat.com',
    'domain:qpic.cn',
    'domain:aliyun.com',
    'full:www.baidu.com'
  ];
  cnDomainRule['outboundTag'] = 'direct';

  const cnIpRule: Record<string, Object> = {};
  cnIpRule['type'] = 'field';
  cnIpRule['ip'] = ['geoip:cn', '223.5.5.5', '114.114.114.114', '180.76.76.76'];
  cnIpRule['outboundTag'] = 'direct';

  const proxyRule: Record<string, Object> = {};
  proxyRule['type'] = 'field';
  proxyRule['inboundTag'] = ['tun-in'];
  proxyRule['outboundTag'] = generalTag;

  const routing: Record<string, Object> = {};
  routing['domainStrategy'] = 'IPIfNonMatch';
  // IPv6 stays accepted on TUN so it cannot leak on Wi-Fi. Node AAAA must
  // leave via VpnConnection.protect(fd), not a ::/0 blackhole — that blackhole
  // also dropped browser Google AAAA on X5 (generate_204 暂无响应).
  // Port 53 before private: Android YouTube still queries 192.168.3.1, which
  // would otherwise DIRECT to the LAN resolver and return poisoned answers.
  // Rule mode, not global: geoip:cn / geosite:cn DIRECT before any QUIC drop,
  // so mainland UDP/443 is not blackholed. YouTube UDP/443 still blocked
  // (QUIC-over-trojan spun). YouTube TCP uses proxy-yt (current fastest
  // node). ChatGPT/Google and the foreign default use the US proxy.
  //
  // Phase C 连接模式（routeMode）：
  // - 'rule'（默认）：下方规则链与 Phase C 之前逐字节一致。
  // - 'global'：保留 DNS 劫持 / IPv6 blackhole / 局域网直连（防回环必须保留）/
  //   YouTube QUIC 封锁，其余全部走代理（去掉 cnDomainRule / cnIpRule，
  //   国内网站会变慢）。
  // - 'direct'：全部直连。保留 DNS 劫持与 IPv6 blackhole（防泄漏），流量一律
  //   direct。此模式让用户保持 VPN 开启但不代理，便于快速切回代理模式。
  // 健康检查按当前 mode 解释访问标签（见 TunnelVpnAbility.tagsMatchRoute）。
  // Phase C2 用户分流规则（userRuleRoutes）：注入点在 privateRule 之后、quicRule
  // 之前——安全规则（DNS 劫持 / IPv6 blackhole / 局域网直连）永远在最前，用户规则
  // 无法把局域网/私网流量导入隧道，也无法复活 IPv6；同时用户规则优先于服务与地区
  // 规则（含 YouTube QUIC 封锁与 geosite/geoip:cn——用户对某域名指定直连或代理是
  // 明示例外，允许覆盖内置模板）。'direct' 模式下所有流量已直连，用户规则无意义，
  // 不注入。
  if (mode === 'global') {
    // 全局代理：保留 DNS 劫持 / IPv6 blackhole / 局域网直连 / YouTube QUIC
    // 封锁，其余全部走代理（国内网站会变慢）。用户的 direct 例外仍生效。
    const chain: Object[] = [
      dnsHijack, dnsInternalProxy, dnsInternalDirect, dummyV6, privateRule, quicRule, youtubeRule,
      proxyProbeRule, proxyRule
    ];
    if (roleRouting) { chain.splice(6, 0, chatgptRule); }
    chain.splice(roleRouting ? 7 : 6, 0, lineHealthRule);
    routing['rules'] = withUserRules(chain, userRuleRoutes, 5);
  } else if (mode === 'direct') {
    const directRule: Record<string, Object> = {};
    directRule['type'] = 'field';
    directRule['inboundTag'] = ['tun-in'];
    directRule['outboundTag'] = 'direct';
    routing['rules'] = [dnsHijack, dnsInternalDirect, dummyV6, privateRule, directRule];
  } else {
    const chain: Object[] = [
      dnsHijack, dnsInternalProxy, dnsInternalDirect, dummyV6, privateRule, quicRule, youtubeRule,
      proxyProbeRule, cnDomainRule, cnIpRule, proxyRule
    ];
    if (roleRouting) { chain.splice(6, 0, chatgptRule); }
    chain.splice(roleRouting ? 7 : 6, 0, lineHealthRule);
    routing['rules'] = withUserRules(chain, userRuleRoutes, 5);
  }
  if (appRules.length > 0) {
    // Preserve DNS/LAN/safety head; App binding outranks domain and default rules.
    routing['rules'] = withUserRules(routing['rules'] as Object[], appRules, 5);
  }
  config['routing'] = routing;

  return JSON.stringify(config);
}

// Phase C2：把用户规则插到安全头（DNS 劫持 / 内部 DNS 出口 / IPv6 blackhole / 局域网直连）之后。
function withUserRules(chain: Object[], userRules: Array<Record<string, Object>>,
  safetyCount: number = 3): Object[] {
  if (userRules.length === 0) {
    return chain;
  }
  const headEnd = safetyCount > 0 ? safetyCount : 3;
  const head = chain.slice(0, headEnd);
  const tail = chain.slice(headEnd);
  return head.concat(userRules).concat(tail);
}

// Phase C2：防御性解析 payload.userRules（domain/action/groupTag 三键，非法动作丢弃）。
function parseUserRuleRoutes(value: Object | undefined): Array<UserRuleRoute> {
  const routes: Array<UserRuleRoute> = [];
  if (value === undefined || !(value instanceof Array)) {
    return routes;
  }
  const items = value as Array<Object>;
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item === null || typeof item !== 'object') {
      continue;
    }
    const rec = item as Record<string, Object>;
    const domain = asString(rec['domain'], '');
    const action = asString(rec['action'], '');
    if (domain.length === 0 ||
      (action !== 'direct' && action !== 'proxy' && action !== 'group')) {
      continue;
    }
    const route = new UserRuleRoute();
    route.domain = domain;
    route.action = action;
    route.groupTag = asString(rec['groupTag'], '');
    routes.push(route);
  }
  return routes;
}

function resolveRouteMode(param: string, payloadValue: Object | undefined): string {
  const fromParam = normalizeRouteMode(param);
  if (fromParam.length > 0) {
    return fromParam;
  }
  if (typeof payloadValue === 'string') {
    return normalizeRouteMode(payloadValue);
  }
  return 'rule';
}

function normalizeRouteMode(value: string): string {
  if (value === 'global' || value === 'direct') {
    return value;
  }
  if (value === 'rule') {
    return 'rule';
  }
  return '';
}

export function parseNodeMeta(raw: string): NodeMeta {
  const parsed = JSON.parse(raw) as Record<string, Object>;
  const meta: NodeMeta = {
    name: asString(parsed['name'], '未导入节点'),
    region: asString(parsed['region'], '未知'),
    server: asString(parsed['server'], ''),
    port: asNumber(parsed['port'], 0),
    protocol: asString(parsed['protocol'], 'trojan'),
    split: asBool(parsed['split'], false),
    hkName: asString(parsed['hkName'], ''),
    ytName: asString(parsed['ytName'], ''),
    usName: asString(parsed['usName'], '')
  };
  if (meta.ytName.length === 0) {
    meta.ytName = meta.hkName;
  }
  return meta;
}

function cloneOutbound(value: Object | undefined, message: string): Record<string, Object> {
  if (value === undefined || typeof value !== 'object') {
    throw new Error(message);
  }
  return JSON.parse(JSON.stringify(value)) as Record<string, Object>;
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function asNumber(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number' && value > 0) {
    return value;
  }
  return fallback;
}

function asInt(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number') {
    return value;
  }
  return fallback;
}

function asBool(value: Object | undefined, fallback: boolean): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  return fallback;
}

function enforceOutboundReady(outbound: Record<string, Object>): void {
  const err = outboundRunError(JSON.stringify(outbound));
  if (err.length > 0) {
    throw new Error(err);
  }
  const streamValue = outbound['streamSettings'];
  if (streamValue === undefined || typeof streamValue !== 'object') {
    return;
  }
  const stream = streamValue as Record<string, Object>;
  const tlsValue = stream['tlsSettings'];
  if (tlsValue !== undefined && typeof tlsValue === 'object') {
    const tls = tlsValue as Record<string, Object>;
    tls['allowInsecure'] = false;
    stream['tlsSettings'] = tls;
    outbound['streamSettings'] = stream;
  }
}
