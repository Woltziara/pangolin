// 穿山 (GPL-3.0) — 订阅内容解析（纯 TS，可在 Node 单元测试下运行，不 import @kit/@ohos）。
// Clash YAML / SIP008 / outbounds JSON 解析逻辑移植自 Hey (GPL-3.0)
// entry/src/main/ets/core/../services/SubscriptionManager.ets，移植日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 解析顺序（产品定义）：(a) 多行分享链接 → (b) 整段 base64 → (c) Clash/Clash-Meta YAML
// （proxies: 列表，覆盖 ss/vmess/trojan/vless/hysteria2/tuic/anytls 常见字段）
// → (d) JSON（SIP008 servers / Xray outbounds）。
import { decodeBase64ToUtf8 } from './Encoding';
import { guessRegion } from './RegionGuess';
import {
  describeOutboundEndpoint,
  isSupportedShareLink,
  isWireguardConfigFile,
  ParsedNode,
  parseShareLink,
  parseShareLinksDetailed,
  ShareLinkFailure
} from './ShareLinkParser';

export type ImportKind = 'single-node' | 'subscription-content' | 'subscription-url' | 'unknown';

export class ParseResult {
  nodes: Array<ParsedNode> = [];
  skipped: number = 0;
  format: string = 'unknown';
  failures: Array<ShareLinkFailure> = [];
}

interface ClashSection {
  indent: number;
  name: string;
}

interface ClashTlsSettings {
  allowInsecure?: boolean;
  serverName?: string;
  fingerprint?: string;
  alpn?: Array<string>;
  publicKey?: string;
  shortId?: string;
  spiderX?: string;
  mldsa65Verify?: string;
  show?: boolean;
}

interface ClashTcpRequestHeaders {
  Host: Array<string>;
}

interface ClashTcpRequest {
  path: Array<string>;
  headers: ClashTcpRequestHeaders;
}

interface ClashTcpHeader {
  type: string;
  request?: ClashTcpRequest;
}

interface ClashTcpSettings {
  header: ClashTcpHeader;
}

interface ClashWsHeaders {
  Host: string;
}

interface ClashWsSettings {
  path: string;
  headers: ClashWsHeaders;
}

interface ClashHttpSettings {
  host: Array<string>;
  path: string;
}

interface ClashGrpcSettings {
  serviceName: string;
  multiMode: boolean;
  idle_timeout: number;
  health_check_timeout: number;
}

interface ClashStreamSettings {
  network: string;
  security?: string;
  tcpSettings?: ClashTcpSettings;
  wsSettings?: ClashWsSettings;
  httpSettings?: ClashHttpSettings;
  grpcSettings?: ClashGrpcSettings;
  tlsSettings?: ClashTlsSettings;
  realitySettings?: ClashTlsSettings;
}

interface ClashVlessUser {
  id: string;
  encryption: string;
  flow?: string;
}

interface ClashVlessServer {
  address: string;
  port: number;
  users: Array<ClashVlessUser>;
}

interface ClashVlessSettings {
  vnext: Array<ClashVlessServer>;
}

interface ClashVmessUser {
  id: string;
  alterId: number;
  security: string;
}

interface ClashVmessServer {
  address: string;
  port: number;
  users: Array<ClashVmessUser>;
}

interface ClashVmessSettings {
  vnext: Array<ClashVmessServer>;
}

interface ClashTrojanServer {
  address: string;
  port: number;
  password: string;
}

interface ClashTrojanSettings {
  servers: Array<ClashTrojanServer>;
}

interface ClashShadowsocksServer {
  address: string;
  port: number;
  method: string;
  password: string;
}

interface ClashShadowsocksSettings {
  servers: Array<ClashShadowsocksServer>;
}

interface ClashGenericUser {
  user: string;
  pass: string;
}

interface ClashGenericServer {
  address: string;
  port: number;
  users?: Array<ClashGenericUser>;
}

interface ClashGenericSettings {
  servers: Array<ClashGenericServer>;
}

interface ClashHysteria2Server {
  address: string;
  port: number;
  password: string;
  sni?: string;
  obfsPassword?: string;
  insecure?: boolean;
}

interface ClashHysteria2Settings {
  servers: Array<ClashHysteria2Server>;
}

interface ClashAnytlsServer {
  address: string;
  port: number;
  password: string;
  sni?: string;
  alpn?: string;
  fingerprint?: string;
  insecure?: boolean;
}

interface ClashAnytlsSettings {
  servers: Array<ClashAnytlsServer>;
}

interface ClashTuicServer {
  address: string;
  port: number;
  uuid: string;
  password: string;
  sni?: string;
  alpn?: string;
  insecure?: boolean;
  congestionControl?: string;
  udpRelayMode?: string;
}

interface ClashTuicSettings {
  servers: Array<ClashTuicServer>;
}

type ClashOutboundSettings = ClashVlessSettings | ClashVmessSettings | ClashTrojanSettings | ClashShadowsocksSettings | ClashGenericSettings | ClashHysteria2Settings | ClashAnytlsSettings | ClashTuicSettings;

interface ClashOutbound {
  protocol: string;
  tag: string;
  settings: ClashOutboundSettings;
  streamSettings?: ClashStreamSettings;
}

interface Sip008Server {
  remarks?: string;
  name?: string;
  server?: string;
  server_port?: string | number;
  port?: string | number;
  method?: string;
  password?: string;
  plugin?: string;
  plugin_opts?: string;
}

interface JsonSubscriptionDocument {
  servers?: Array<Sip008Server>;
  outbound?: Record<string, Object>;
  outbounds?: Array<Record<string, Object>>;
}

/**
 * 区分“一个节点 / 一份订阅内容 / 订阅地址 / 无法识别”。
 */
export function classifyImport(text: string): ImportKind {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return 'unknown';
  }
  if (isWireguardConfigFile(trimmed)) {
    return parseShareLink(trimmed) !== null ? 'single-node' : 'unknown';
  }
  const singleLine = trimmed.indexOf('\n') < 0;
  if (singleLine) {
    if (isSupportedShareLink(trimmed) && parseShareLink(trimmed) !== null) {
      return 'single-node';
    }
    const lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      // http(s) 链接若不能按 HTTP 代理节点解析，则按订阅地址处理。
      return 'subscription-url';
    }
    // 单行也可能是整段 base64 订阅内容。
    const singleLineOutcome = parseSubscriptionContent(trimmed);
    return singleLineOutcome.nodes.length > 0 ? 'subscription-content' : 'unknown';
  }
  const outcome = parseSubscriptionContent(trimmed);
  return outcome.nodes.length > 0 ? 'subscription-content' : 'unknown';
}

/**
 * 解析订阅内容。顺序：多行分享链接 → 整段 base64 → Clash YAML → JSON（SIP008/outbounds）。
 */
export function parseSubscriptionContent(text: string): ParseResult {
  const raw = normalizeSubscriptionPayload(text);
  if (raw.length === 0) {
    return new ParseResult();
  }

  const linkOutcome = parseLinesOutcome(raw);
  if (linkOutcome.nodes.length > 0) {
    linkOutcome.format = 'share-links';
    return linkOutcome;
  }

  try {
    const decoded = normalizeSubscriptionPayload(decodeBase64ToUtf8(raw));
    if (decoded.length > 0 && decoded !== raw) {
      const decodedOutcome = parseStructuredOrLines(decoded);
      if (decodedOutcome.nodes.length > 0) {
        decodedOutcome.format = `base64(${decodedOutcome.format})`;
        return decodedOutcome;
      }
    }
  } catch (error) {
    // 不是整段 base64，继续尝试其它格式。
  }

  const structured = parseStructuredOrLines(raw);
  if (structured.nodes.length > 0) {
    return structured;
  }

  // 全格式都没有解析出节点时，带回跳过数与逐行失败原因，便于 UI 提示。
  const best = structured.skipped >= linkOutcome.skipped ? structured : linkOutcome;
  best.format = 'unknown';
  if (best.failures.length === 0 && looksLikeHtmlContent(raw)) {
    best.failures.push({ line: '', reason: '该地址返回的是网页内容而不是配置数据。' });
  }
  return best;
}

function parseStructuredOrLines(content: string): ParseResult {
  const clashOutcome = parseClashYamlOutcome(content);
  if (clashOutcome.nodes.length > 0) {
    return clashOutcome;
  }
  const jsonOutcome = parseJsonSubscriptionOutcome(content);
  if (jsonOutcome.nodes.length > 0) {
    return jsonOutcome;
  }
  const lines = parseLinesOutcome(content);
  if (lines.nodes.length > 0) {
    return lines;
  }
  // 返回跳过数最大的结果（它最可能是内容的真实格式）。
  let best = clashOutcome;
  if (jsonOutcome.skipped > best.skipped) {
    best = jsonOutcome;
  }
  if (lines.skipped > best.skipped) {
    best = lines;
  }
  if (lines.failures.length > 0 && best.failures.length === 0) {
    best.failures = lines.failures;
  }
  return best;
}

function parseLinesOutcome(content: string): ParseResult {
  const batch = parseShareLinksDetailed(content);
  const outcome = new ParseResult();
  outcome.nodes = batch.nodes;
  outcome.failures = batch.failures;
  outcome.skipped = batch.failures.length;
  outcome.format = 'share-links';
  return outcome;
}

function normalizeSubscriptionPayload(content: string): string {
  let value = content.trim();
  if (value.startsWith('\uFEFF')) {
    value = value.substring(1).trim();
  }
  const lower = value.toLowerCase();
  const dataPrefix = 'data:text/plain;base64,';
  if (lower.startsWith(dataPrefix)) {
    return value.substring(dataPrefix.length).trim();
  }
  const dataBase64Marker = ';base64,';
  const dataBase64Index = lower.indexOf(dataBase64Marker);
  if (lower.startsWith('data:') && dataBase64Index > 0) {
    return value.substring(dataBase64Index + dataBase64Marker.length).trim();
  }
  return value;
}

export function looksLikeHtmlContent(content: string): boolean {
  const head = normalizeSubscriptionPayload(content).substring(0, 512).toLowerCase();
  return head.startsWith('<!doctype') || head.startsWith('<html') ||
    head.indexOf('<html') >= 0 || head.indexOf('<head') >= 0 || head.indexOf('<body') >= 0;
}

function makeNodeFromOutboundJson(outboundJson: string, name: string): ParsedNode | null {
  const node = new ParsedNode();
  node.name = name;
  node.outboundJson = outboundJson;
  node.rawLink = '';
  try {
    const parsed = JSON.parse(outboundJson) as Record<string, Object>;
    const protocol = parsed['protocol'];
    node.protocol = typeof protocol === 'string' ? protocol : '';
  } catch (error) {
    return null;
  }
  if (node.protocol.length === 0) {
    return null;
  }
  const endpoint = describeOutboundEndpoint(outboundJson);
  node.server = endpoint.host;
  node.port = endpoint.port;
  if (node.name.length === 0) {
    node.name = endpoint.host.length > 0
      ? `${node.protocol.toUpperCase()} ${endpoint.host}:${endpoint.port}`
      : node.protocol.toUpperCase();
  }
  node.region = guessRegion(node.name, node.server);
  return node;
}

// ---------- JSON（SIP008 / Xray outbounds） ----------

function parseJsonSubscriptionOutcome(content: string): ParseResult {
  const outcome = new ParseResult();
  outcome.format = 'json';
  const trimmed = content.trim();
  if (trimmed.length === 0) {
    return outcome;
  }
  const first = trimmed.charAt(0);
  if (first !== '{' && first !== '[') {
    return outcome;
  }

  try {
    if (first === '[') {
      const arr = JSON.parse(trimmed) as Array<Record<string, Object>>;
      return parseJsonOutbounds(arr);
    }
    const document = JSON.parse(trimmed) as JsonSubscriptionDocument;
    if (document.outbounds !== undefined) {
      return parseJsonOutbounds(document.outbounds);
    }
    if (document.outbound !== undefined) {
      return parseJsonOutbounds([document.outbound]);
    }
    if (document.servers !== undefined) {
      return parseSip008Document(document.servers);
    }
    return outcome;
  } catch (error) {
    return outcome;
  }
}

function parseJsonOutbounds(outbounds: Array<Record<string, Object>>): ParseResult {
  const outcome = new ParseResult();
  outcome.format = 'json';
  for (let index = 0; index < outbounds.length; index++) {
    const outbound = outbounds[index];
    if (outbound === null || typeof outbound !== 'object') {
      continue;
    }
    if (outbound['protocol'] === undefined || outbound['settings'] === undefined) {
      continue;
    }
    const tag = outbound['tag'];
    const node = makeNodeFromOutboundJson(
      JSON.stringify(outbound, null, 2),
      typeof tag === 'string' ? tag : ''
    );
    if (node !== null && endpointPresent(node)) {
      outcome.nodes.push(node);
    } else {
      outcome.skipped++;
    }
  }
  return outcome;
}

function endpointPresent(node: ParsedNode): boolean {
  return node.server.length > 0 && node.port > 0;
}

function parseSip008Document(servers: Array<Sip008Server>): ParseResult {
  const outcome = new ParseResult();
  outcome.format = 'json';
  for (let index = 0; index < servers.length; index++) {
    const server = servers[index];
    if (server === null || typeof server !== 'object') {
      continue;
    }
    const host = server.server === undefined ? '' : server.server;
    const port = parsePortValue(server.server_port === undefined ? server.port : server.server_port);
    const method = (server.method === undefined ? '' : server.method).toLowerCase();
    const password = server.password === undefined ? '' : server.password;
    if (host.length === 0 || port <= 0 || method.length === 0 || password.length === 0) {
      outcome.skipped++;
      continue;
    }
    const ssServer: ClashShadowsocksServer = {
      address: host,
      port,
      method,
      password
    };
    const settings: ClashShadowsocksSettings = {
      servers: [ssServer]
    };
    const outbound: ClashOutbound = {
      protocol: 'shadowsocks',
      tag: 'proxy',
      settings
    };
    const remarks = server.remarks === undefined
      ? (server.name === undefined ? '' : server.name)
      : server.remarks;
    const node = makeNodeFromOutboundJson(JSON.stringify(outbound, null, 2), remarks);
    if (node !== null) {
      outcome.nodes.push(node);
    } else {
      outcome.skipped++;
    }
  }
  return outcome;
}

// ---------- Clash / Clash-Meta YAML ----------

function parseClashYamlOutcome(content: string): ParseResult {
  const outcome = new ParseResult();
  outcome.format = 'clash-yaml';
  const entries = extractClashProxyEntries(content);
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index];
    const outbound = clashEntryToOutbound(entry);
    if (outbound === null) {
      outcome.skipped++;
      continue;
    }
    const node = makeNodeFromOutboundJson(
      JSON.stringify(outbound, null, 2),
      clashMapValue(entry, 'name', '')
    );
    if (node !== null) {
      outcome.nodes.push(node);
    } else {
      outcome.skipped++;
    }
  }
  return outcome;
}

function extractClashProxyEntries(content: string): Array<Map<string, string>> {
  const normalized = content.split('\r\n').join('\n').split('\r').join('\n');
  const lines = normalized.split('\n');
  const entries = new Array<Map<string, string>>();
  let inProxies = false;
  let proxiesIndent = -1;
  let current: Map<string, string> | null = null;
  let sections = new Array<ClashSection>();

  for (let index = 0; index < lines.length; index++) {
    const rawLine = lines[index];
    const trimmed = rawLine.trim();
    if (trimmed.length === 0 || trimmed.startsWith('#')) {
      continue;
    }

    const indent = countIndent(rawLine);
    if (!inProxies) {
      if (trimmed === 'proxies:') {
        inProxies = true;
        proxiesIndent = indent;
      }
      continue;
    }

    if (indent <= proxiesIndent && !trimmed.startsWith('- ')) {
      pushClashEntry(entries, current);
      current = null;
      sections = new Array<ClashSection>();
      break;
    }

    if (trimmed.startsWith('- ')) {
      pushClashEntry(entries, current);
      current = new Map<string, string>();
      sections = new Array<ClashSection>();
      const body = trimmed.substring(2).trim();
      if (body.startsWith('{') && body.endsWith('}')) {
        parseInlineMap(body, current, '');
      } else {
        parseYamlPair(body, current, '');
      }
      continue;
    }

    if (current === null) {
      continue;
    }

    while (sections.length > 0 && indent <= sections[sections.length - 1].indent) {
      sections.pop();
    }

    if (trimmed.endsWith(':') && trimmed.indexOf(':') === trimmed.length - 1) {
      const section: ClashSection = {
        indent,
        name: normalizeYamlKey(trimmed.substring(0, trimmed.length - 1))
      };
      sections.push(section);
      continue;
    }

    parseYamlPair(trimmed, current, sectionPrefix(sections));
  }

  pushClashEntry(entries, current);
  return entries;
}

function pushClashEntry(entries: Array<Map<string, string>>, entry: Map<string, string> | null): void {
  if (entry !== null && clashMapValue(entry, 'type', '').length > 0) {
    entries.push(entry);
  }
}

function parseYamlPair(line: string, target: Map<string, string>, prefix: string): void {
  const colonIndex = findTopLevelColon(line);
  if (colonIndex <= 0) {
    return;
  }
  const key = normalizeYamlKey(line.substring(0, colonIndex));
  const rawValue = stripYamlValue(line.substring(colonIndex + 1));
  if (rawValue.startsWith('{') && rawValue.endsWith('}')) {
    parseInlineMap(rawValue, target, joinKey(prefix, key));
    return;
  }
  target.set(joinKey(prefix, key), rawValue);
}

function parseInlineMap(value: string, target: Map<string, string>, prefix: string): void {
  const body = value.substring(1, value.length - 1);
  const pairs = splitInlineMapPairs(body);
  for (let index = 0; index < pairs.length; index++) {
    const pair = pairs[index];
    const colonIndex = findTopLevelColon(pair);
    if (colonIndex <= 0) {
      continue;
    }
    const key = normalizeYamlKey(pair.substring(0, colonIndex));
    const rawValue = stripYamlValue(pair.substring(colonIndex + 1));
    if (rawValue.startsWith('{') && rawValue.endsWith('}')) {
      parseInlineMap(rawValue, target, joinKey(prefix, key));
    } else {
      target.set(joinKey(prefix, key), rawValue);
    }
  }
}

function splitInlineMapPairs(value: string): Array<string> {
  const pairs = new Array<string>();
  let depth = 0;
  let quote = '';
  let start = 0;
  for (let index = 0; index < value.length; index++) {
    const ch = value.charAt(index);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === '{' || ch === '[') {
      depth++;
    } else if (ch === '}' || ch === ']') {
      depth--;
    } else if (ch === ',' && depth === 0) {
      pairs.push(value.substring(start, index).trim());
      start = index + 1;
    }
  }
  pairs.push(value.substring(start).trim());
  return pairs;
}

function clashEntryToOutbound(entry: Map<string, string>): ClashOutbound | null {
  const type = clashMapValue(entry, 'type', '').toLowerCase();
  const host = clashMapValue(entry, 'server', '');
  const port = parsePortString(clashMapValue(entry, 'port', ''));
  if (host.length === 0 || port <= 0) {
    return null;
  }

  if (type === 'vless') {
    const id = clashMapFirstValue(entry, ['uuid', 'id'], '');
    if (id.length === 0) {
      return null;
    }
    const user: ClashVlessUser = {
      id,
      encryption: clashMapValue(entry, 'encryption', 'none')
    };
    const flow = clashMapValue(entry, 'flow', '');
    if (flow.length > 0) {
      user.flow = flow;
    }
    const server: ClashVlessServer = {
      address: host,
      port,
      users: [user]
    };
    const settings: ClashVlessSettings = {
      vnext: [server]
    };
    return {
      protocol: 'vless',
      tag: 'proxy',
      settings,
      streamSettings: buildClashStreamSettings(entry)
    };
  }

  if (type === 'vmess') {
    const id = clashMapFirstValue(entry, ['uuid', 'id'], '');
    if (id.length === 0) {
      return null;
    }
    const user: ClashVmessUser = {
      id,
      alterId: parseIntegerString(clashMapFirstValue(entry, ['alterid', 'alter-id', 'aid'], '0'), 0),
      security: clashMapFirstValue(entry, ['cipher', 'security'], 'auto')
    };
    const server: ClashVmessServer = {
      address: host,
      port,
      users: [user]
    };
    const settings: ClashVmessSettings = {
      vnext: [server]
    };
    return {
      protocol: 'vmess',
      tag: 'proxy',
      settings,
      streamSettings: buildClashStreamSettings(entry)
    };
  }

  if (type === 'trojan') {
    const password = clashMapValue(entry, 'password', '');
    if (password.length === 0) {
      return null;
    }
    const server: ClashTrojanServer = {
      address: host,
      port,
      password
    };
    const settings: ClashTrojanSettings = {
      servers: [server]
    };
    return {
      protocol: 'trojan',
      tag: 'proxy',
      settings,
      streamSettings: buildClashStreamSettings(entry, 'tls')
    };
  }

  if (type === 'ss' || type === 'shadowsocks') {
    const method = clashMapFirstValue(entry, ['cipher', 'method'], '').toLowerCase();
    const password = clashMapValue(entry, 'password', '');
    if (method.length === 0 || password.length === 0) {
      return null;
    }
    const server: ClashShadowsocksServer = {
      address: host,
      port,
      method,
      password
    };
    const settings: ClashShadowsocksSettings = {
      servers: [server]
    };
    const stream = buildClashPluginStreamSettings(entry);
    const outbound: ClashOutbound = {
      protocol: 'shadowsocks',
      tag: 'proxy',
      settings
    };
    if (stream !== undefined) {
      outbound.streamSettings = stream;
    }
    return outbound;
  }

  if (type === 'socks5' || type === 'socks') {
    const server: ClashGenericServer = {
      address: host,
      port
    };
    const user = buildGenericUser(entry);
    if (user !== null) {
      server.users = [user];
    }
    const settings: ClashGenericSettings = {
      servers: [server]
    };
    return {
      protocol: 'socks',
      tag: 'proxy',
      settings
    };
  }

  if (type === 'http' || type === 'https') {
    const server: ClashGenericServer = {
      address: host,
      port
    };
    const user = buildGenericUser(entry);
    if (user !== null) {
      server.users = [user];
    }
    const settings: ClashGenericSettings = {
      servers: [server]
    };
    return {
      protocol: 'http',
      tag: 'proxy',
      settings
    };
  }

  if (type === 'hysteria2' || type === 'hy2') {
    const password = clashMapFirstValue(entry, ['password', 'auth'], '');
    if (password.length === 0) {
      return null;
    }
    const server: ClashHysteria2Server = {
      address: host,
      port,
      password
    };
    const sni = clashMapFirstValue(entry, ['sni', 'servername'], '');
    if (sni.length > 0) {
      server.sni = sni;
    }
    const obfsPassword = clashMapFirstValue(entry, ['obfs-password', 'obfs.password'], '');
    if (obfsPassword.length > 0) {
      server.obfsPassword = obfsPassword;
    }
    if (clashMapValue(entry, 'skip-cert-verify', '').length > 0) {
      server.insecure = clashMapBoolean(entry, 'skip-cert-verify', false);
    }
    const settings: ClashHysteria2Settings = {
      servers: [server]
    };
    return {
      protocol: 'hysteria2',
      tag: 'proxy',
      settings
    };
  }

  if (type === 'anytls') {
    const password = clashMapValue(entry, 'password', '');
    if (password.length === 0) {
      return null;
    }
    const server: ClashAnytlsServer = {
      address: host,
      port,
      password
    };
    const sni = clashMapFirstValue(entry, ['sni', 'servername'], '');
    if (sni.length > 0) {
      server.sni = sni;
    }
    const alpn = clashMapFirstValue(entry, ['alpn', 'alpn.0'], '');
    if (alpn.length > 0) {
      server.alpn = alpn;
    }
    const fingerprint = clashMapFirstValue(entry, ['client-fingerprint', 'fingerprint'], '');
    if (fingerprint.length > 0) {
      server.fingerprint = fingerprint;
    }
    if (clashMapValue(entry, 'skip-cert-verify', '').length > 0) {
      server.insecure = clashMapBoolean(entry, 'skip-cert-verify', false);
    }
    const settings: ClashAnytlsSettings = {
      servers: [server]
    };
    return {
      protocol: 'anytls',
      tag: 'proxy',
      settings
    };
  }

  if (type === 'tuic') {
    const uuid = clashMapFirstValue(entry, ['uuid', 'id'], '');
    const password = clashMapFirstValue(entry, ['password', 'token'], '');
    if (uuid.length === 0 || password.length === 0) {
      return null;
    }
    const server: ClashTuicServer = {
      address: host,
      port,
      uuid,
      password
    };
    const sni = clashMapFirstValue(entry, ['sni', 'servername'], '');
    if (sni.length > 0) {
      server.sni = sni;
    }
    const alpn = clashMapFirstValue(entry, ['alpn', 'alpn.0'], '');
    if (alpn.length > 0) {
      server.alpn = alpn;
    }
    const congestionControl = clashMapFirstValue(entry, ['congestion-controller', 'congestion-control'], '');
    if (congestionControl.length > 0) {
      server.congestionControl = congestionControl;
    }
    const udpRelayMode = clashMapValue(entry, 'udp-relay-mode', '');
    if (udpRelayMode.length > 0) {
      server.udpRelayMode = udpRelayMode;
    }
    if (clashMapValue(entry, 'skip-cert-verify', '').length > 0) {
      server.insecure = clashMapBoolean(entry, 'skip-cert-verify', false);
    }
    const settings: ClashTuicSettings = {
      servers: [server]
    };
    return {
      protocol: 'tuic',
      tag: 'proxy',
      settings
    };
  }

  return null;
}

function buildGenericUser(entry: Map<string, string>): ClashGenericUser | null {
  const user = clashMapFirstValue(entry, ['username', 'user'], '');
  const pass = clashMapFirstValue(entry, ['password', 'pass'], '');
  if (user.length === 0 && pass.length === 0) {
    return null;
  }
  return { user, pass };
}

function buildClashPluginStreamSettings(entry: Map<string, string>): ClashStreamSettings | undefined {
  const plugin = clashMapValue(entry, 'plugin', '').toLowerCase();
  if (plugin !== 'obfs') {
    return undefined;
  }
  const mode = clashMapFirstValue(entry, ['plugin-opts.mode', 'plugin_opts.mode'], '');
  if (mode !== 'http') {
    return undefined;
  }
  const host = clashMapFirstValue(entry, ['plugin-opts.host', 'plugin_opts.host'], '');
  const path = clashMapFirstValue(entry, ['plugin-opts.path', 'plugin_opts.path'], '');
  const headers: ClashTcpRequestHeaders = {
    Host: splitCsv(host)
  };
  const request: ClashTcpRequest = {
    path: splitCsvWithDefault(path, '/'),
    headers
  };
  const header: ClashTcpHeader = {
    type: 'http',
    request
  };
  const tcpSettings: ClashTcpSettings = {
    header
  };
  return {
    network: 'tcp',
    tcpSettings
  };
}

function buildClashStreamSettings(entry: Map<string, string>, defaultSecurity: string = ''): ClashStreamSettings {
  let network = clashMapFirstValue(entry, ['network', 'net'], 'tcp').toLowerCase();
  if (network === 'h2' || network === 'http') {
    network = 'h2';
  } else if (network !== 'ws' && network !== 'grpc') {
    network = 'tcp';
  }

  const stream: ClashStreamSettings = {
    network
  };
  if (network === 'ws') {
    const path = clashMapFirstValue(entry, ['ws-opts.path', 'ws_opts.path', 'path'], '/');
    const host = clashMapFirstValue(entry, ['ws-opts.headers.host', 'ws_opts.headers.host', 'host'], '');
    const headers: ClashWsHeaders = {
      Host: host
    };
    const wsSettings: ClashWsSettings = {
      path: path.length > 0 ? path : '/',
      headers
    };
    stream.wsSettings = wsSettings;
  } else if (network === 'grpc') {
    const grpcSettings: ClashGrpcSettings = {
      serviceName: clashMapFirstValue(entry, ['grpc-opts.grpc-service-name', 'grpc_opts.grpc-service-name', 'servicename'], ''),
      multiMode: clashMapFirstValue(entry, ['grpc-opts.grpc-mode', 'mode'], '') === 'multi',
      idle_timeout: 60,
      health_check_timeout: 20
    };
    stream.grpcSettings = grpcSettings;
  } else if (network === 'h2') {
    const httpSettings: ClashHttpSettings = {
      host: splitCsv(clashMapFirstValue(entry, ['h2-opts.host', 'http-opts.host', 'host'], '')),
      path: clashMapFirstValue(entry, ['h2-opts.path', 'http-opts.path', 'path'], '/')
    };
    stream.httpSettings = httpSettings;
  } else {
    const header: ClashTcpHeader = {
      type: 'none'
    };
    const tcpSettings: ClashTcpSettings = {
      header
    };
    stream.tcpSettings = tcpSettings;
  }

  applyClashSecurity(entry, stream, defaultSecurity);
  return stream;
}

function applyClashSecurity(entry: Map<string, string>, stream: ClashStreamSettings, defaultSecurity: string): void {
  const publicKey = clashMapFirstValue(entry, ['reality-opts.public-key', 'reality_opts.public-key', 'reality-opts.publickey', 'pbk'], '');
  let security = defaultSecurity;
  if (publicKey.length > 0) {
    security = 'reality';
  } else if (clashMapBoolean(entry, 'tls', false)) {
    security = 'tls';
  }

  if (security !== 'tls' && security !== 'reality') {
    return;
  }

  const tlsSettings: ClashTlsSettings = {
    allowInsecure: clashMapBoolean(entry, 'skip-cert-verify', false)
  };
  const sni = clashMapFirstValue(entry, ['sni', 'servername'], deriveClashServerName(entry));
  if (sni.length > 0) {
    tlsSettings.serverName = sni;
  }
  const fingerprint = clashMapFirstValue(entry, ['client-fingerprint', 'fingerprint', 'fp'], '');
  if (fingerprint.length > 0) {
    tlsSettings.fingerprint = fingerprint;
  }
  const alpn = splitCsv(clashMapValue(entry, 'alpn', ''));
  if (alpn.length > 0) {
    tlsSettings.alpn = alpn;
  }
  if (publicKey.length > 0) {
    tlsSettings.publicKey = publicKey;
    tlsSettings.shortId = clashMapFirstValue(entry, ['reality-opts.short-id', 'reality_opts.short-id', 'sid'], '');
    const spiderX = clashMapFirstValue(entry, ['reality-opts.spider-x', 'reality_opts.spider-x', 'reality-opts.spiderx', 'spx'], '');
    if (spiderX.length > 0) {
      tlsSettings.spiderX = spiderX;
    }
    const mldsa65Verify = clashMapFirstValue(entry, ['reality-opts.mldsa65-verify', 'reality_opts.mldsa65-verify', 'pqv'], '');
    if (mldsa65Verify.length > 0) {
      tlsSettings.mldsa65Verify = mldsa65Verify;
    }
    tlsSettings.show = false;
  }

  stream.security = security;
  if (security === 'tls') {
    stream.tlsSettings = tlsSettings;
  } else {
    stream.realitySettings = tlsSettings;
  }
}

function deriveClashServerName(entry: Map<string, string>): string {
  const network = clashMapFirstValue(entry, ['network', 'net'], 'tcp').toLowerCase();
  if (network === 'ws') {
    return firstCsvValue(clashMapFirstValue(entry, ['ws-opts.headers.host', 'ws_opts.headers.host', 'host'], ''));
  }
  if (network === 'h2' || network === 'http') {
    return firstCsvValue(clashMapFirstValue(entry, ['h2-opts.host', 'http-opts.host', 'host'], ''));
  }
  if (network === 'grpc') {
    return clashMapFirstValue(entry, ['grpc-opts.authority', 'grpc_opts.authority'], '');
  }
  return '';
}

function parsePortValue(value: string | number | undefined): number {
  if (value === undefined) {
    return -1;
  }
  return parsePortString(value.toString());
}

function parsePortString(value: string): number {
  const port = Number(value.trim());
  if (value.trim().length === 0 || port < 1 || port > 65535 || Math.floor(port) !== port) {
    return -1;
  }
  return port;
}

function parseIntegerString(value: string, fallback: number): number {
  const number = Number(value.trim());
  if (value.trim().length === 0 || Number.isNaN(number) || Math.floor(number) !== number) {
    return fallback;
  }
  return number;
}

function clashMapValue(entry: Map<string, string>, key: string, fallback: string): string {
  const value = entry.get(normalizeYamlKey(key));
  return value === undefined ? fallback : value;
}

function clashMapFirstValue(entry: Map<string, string>, keys: Array<string>, fallback: string): string {
  for (let index = 0; index < keys.length; index++) {
    const value = clashMapValue(entry, keys[index], '');
    if (value.length > 0) {
      return value;
    }
  }
  return fallback;
}

function clashMapBoolean(entry: Map<string, string>, key: string, fallback: boolean): boolean {
  const raw = clashMapValue(entry, key, '');
  if (raw.length === 0) {
    return fallback;
  }
  const lower = raw.toLowerCase();
  return lower === 'true' || lower === '1' || lower === 'yes';
}

function countIndent(value: string): number {
  let indent = 0;
  while (indent < value.length && value.charAt(indent) === ' ') {
    indent++;
  }
  return indent;
}

function sectionPrefix(sections: Array<ClashSection>): string {
  let prefix = '';
  for (let index = 0; index < sections.length; index++) {
    prefix = joinKey(prefix, sections[index].name);
  }
  return prefix;
}

function joinKey(prefix: string, key: string): string {
  const normalizedKey = normalizeYamlKey(key);
  if (prefix.length === 0) {
    return normalizedKey;
  }
  if (normalizedKey.length === 0) {
    return prefix;
  }
  return `${prefix}.${normalizedKey}`;
}

function normalizeYamlKey(key: string): string {
  return stripYamlValue(key).toLowerCase().split('_').join('-');
}

function findTopLevelColon(value: string): number {
  let quote = '';
  let depth = 0;
  for (let index = 0; index < value.length; index++) {
    const ch = value.charAt(index);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === '{' || ch === '[') {
      depth++;
    } else if (ch === '}' || ch === ']') {
      depth--;
    } else if (ch === ':' && depth === 0) {
      return index;
    }
  }
  return -1;
}

function stripYamlValue(value: string): string {
  let result = '';
  let quote = '';
  for (let index = 0; index < value.length; index++) {
    const ch = value.charAt(index);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      result += ch;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      result += ch;
    } else if (ch === '#') {
      break;
    } else {
      result += ch;
    }
  }

  result = result.trim();
  if (result.length >= 2) {
    const firstChar = result.charAt(0);
    const lastChar = result.charAt(result.length - 1);
    if ((firstChar === '"' && lastChar === '"') || (firstChar === "'" && lastChar === "'")) {
      result = result.substring(1, result.length - 1);
    }
  }
  return result;
}

function splitCsv(value: string): Array<string> {
  const result = new Array<string>();
  if (value.length === 0) {
    return result;
  }
  const normalized = value.replace('[', '').replace(']', '');
  const parts = normalized.split(',');
  for (let index = 0; index < parts.length; index++) {
    const part = stripYamlValue(parts[index]);
    if (part.length > 0) {
      result.push(part);
    }
  }
  return result;
}

function splitCsvWithDefault(value: string, fallback: string): Array<string> {
  const values = splitCsv(value);
  if (values.length > 0) {
    return values;
  }
  return [fallback];
}

function firstCsvValue(value: string): string {
  const values = splitCsv(value);
  return values.length > 0 ? values[0] : '';
}
