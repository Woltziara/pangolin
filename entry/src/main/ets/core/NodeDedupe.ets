// 移植自 Hey (GPL-3.0): entry/src/main/ets/core/NodeDedupe.ets，移植日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 适配：Hey 的 key 是“整份归一化 outbound JSON（去 tag/name）”；本项目按产品定义改为
// “protocol + server + port + 主凭据”，无法提取凭据时回退到 Hey 的整份 JSON 方式。
// 纯 TS 模块：不 import 任何 @kit/@ohos，可在 Node 单元测试下运行。

/**
 * 节点去重键：protocol|server|port|主凭据|完整连接身份。
 * 传输方式、路径、TLS/Reality 名称等计入身份；显示名/备注不计。
 * 主凭据按协议取：vless/vmess→用户 id；trojan/hysteria2/anytls→password；
 * shadowsocks→method:password；socks/http→user；tuic→uuid；wireguard→peer publicKey。
 * 返回空字符串表示无法构造（调用方应跳过）。
 */
export function nodeDedupeKey(protocol: string, outboundJson: string): string {
  const normalized = normalizeOutboundDedupeJson(outboundJson);
  if (normalized.length === 0) {
    return '';
  }
  try {
    const outbound = JSON.parse(outboundJson) as Record<string, Object>;
    const settingsValue = outbound['settings'];
    if (settingsValue === undefined || typeof settingsValue !== 'object') {
      return `json:${normalized}`;
    }
    const settings = settingsValue as Record<string, Object>;
    const serverRecord = firstServerRecord(settings);
    if (serverRecord === null) {
      return `json:${normalized}`;
    }
    const server = asText(serverRecord['address']);
    const portValue = serverRecord['port'];
    const port = typeof portValue === 'number' ? portValue : 0;
    const credential = primaryCredential(protocol, settings, serverRecord);
    const identity = streamIdentity(outbound);
    return `${protocol}|${server}|${port}|${credential}|${identity}`;
  } catch (error) {
    return `json:${normalized}`;
  }
}

export function dedupeKeyOfNode(protocol: string, outboundJson: string, rawLink: string): string {
  const key = nodeDedupeKey(protocol, outboundJson);
  if (key.length > 0) {
    return key;
  }
  const raw = rawLink.trim();
  return raw.length > 0 ? `raw:${raw}` : '';
}

function firstServerRecord(settings: Record<string, Object>): Record<string, Object> | null {
  const vnext = settings['vnext'];
  if (vnext instanceof Array && vnext.length > 0) {
    const first = vnext[0] as Object;
    if (typeof first === 'object') {
      return first as Record<string, Object>;
    }
  }
  const servers = settings['servers'];
  if (servers instanceof Array && servers.length > 0) {
    const first = servers[0] as Object;
    if (typeof first === 'object') {
      return first as Record<string, Object>;
    }
  }
  return null;
}

function primaryCredential(protocol: string, settings: Record<string, Object>, server: Record<string, Object>): string {
  const lower = protocol.toLowerCase();
  if (lower === 'vless' || lower === 'vmess') {
    const users = server['users'];
    if (users instanceof Array && users.length > 0) {
      const user = users[0] as Record<string, Object>;
      return asText(user['id']);
    }
    return '';
  }
  if (lower === 'trojan' || lower === 'hysteria2' || lower === 'anytls') {
    return asText(server['password']);
  }
  if (lower === 'shadowsocks') {
    return `${asText(server['method'])}:${asText(server['password'])}`;
  }
  if (lower === 'socks' || lower === 'http') {
    const users = server['users'];
    if (users instanceof Array && users.length > 0) {
      const user = users[0] as Record<string, Object>;
      return asText(user['user']);
    }
    return '';
  }
  if (lower === 'tuic') {
    return asText(server['uuid']);
  }
  if (lower === 'wireguard') {
    const peers = settings['peers'];
    if (peers instanceof Array && peers.length > 0) {
      const peer = peers[0] as Record<string, Object>;
      return asText(peer['publicKey']);
    }
    return '';
  }
  return '';
}

// 与 Hey normalizeOutboundDedupeJson 同义：去掉 tag/remarks/name 后的整份 JSON。
function normalizeOutboundDedupeJson(outboundJson: string): string {
  try {
    const parsed = JSON.parse(outboundJson) as Record<string, Object>;
    const result: Record<string, Object> = {};
    const keys = Object.keys(parsed);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      if (key === 'tag' || key === 'remarks' || key === 'name') {
        continue;
      }
      result[key] = parsed[key];
    }
    return JSON.stringify(result);
  } catch (error) {
    return '';
  }
}

function streamIdentity(outbound: Record<string, Object>): string {
  const raw = outbound['streamSettings'];
  if (raw === undefined || typeof raw !== 'object') {
    return 'tcp|none';
  }
  const stream = raw as Record<string, Object>;
  const network = asText(stream['network']);
  const security = asText(stream['security']);
  const ws = asRecord(stream['wsSettings']);
  const grpc = asRecord(stream['grpcSettings']);
  const tls = asRecord(stream['tlsSettings']);
  const reality = asRecord(stream['realitySettings']);
  const wsHeaders = ws !== null ? asRecord(ws['headers']) : null;
  return [
    network.length > 0 ? network : 'tcp',
    security.length > 0 ? security : 'none',
    ws !== null ? asText(ws['path']) : '',
    wsHeaders !== null ? asText(wsHeaders['Host']) : '',
    grpc !== null ? asText(grpc['serviceName']) : '',
    tls !== null ? asText(tls['serverName']) : '',
    reality !== null ? asText(reality['serverName']) : '',
    reality !== null ? asText(reality['publicKey']) : '',
    reality !== null ? asText(reality['shortId']) : '',
    tls !== null ? asText(tls['fingerprint']) : ''
  ].join('|');
}

function asRecord(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object') {
    return null;
  }
  return value as Record<string, Object>;
}

function asText(value: Object | undefined): string {
  return typeof value === 'string' ? value : '';
}
