// 穿山 (GPL-3.0) — 运行能力判断（纯函数，无 @kit）。
// 解析层可以接受多种分享链接；本文件回答「当前锁定内核能不能真正连上」。
// 导入预览与 Xray 配置生成必须调用同一函数，避免导入成功却在启动时报 TLS。

const AEAD_METHODS: string[] = [
  'aes-128-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305'
];

/** Import policy: never honor a provider's request to disable certificate checks.
 * Preserve the server/SNI and all other connection fields. This config policy is
 * not proof that a certificate is valid; the TLS handshake still has to verify it.
 */
export function requireCertificateVerification(outboundJson: string): string {
  const outbound = JSON.parse(outboundJson) as Record<string, Object>;
  const stream = streamOf(outbound);
  let changed = false;
  const tlsNames: string[] = ['tlsSettings', 'realitySettings'];
  for (let i = 0; i < tlsNames.length; i++) {
    const value = stream[tlsNames[i]];
    if (value !== undefined && typeof value === 'object') {
      const tls = value as Record<string, Object>;
      if (tls['allowInsecure'] === true) { tls['allowInsecure'] = false; changed = true; }
    }
  }
  const server = firstServer(outbound);
  if (server !== null && (server['insecure'] === true || server['insecure'] === '1' || server['insecure'] === 'true')) {
    server['insecure'] = false;
    changed = true;
  }
  return changed ? JSON.stringify(outbound) : outboundJson;
}

export function outboundIsRunnable(outboundJson: string): boolean {
  try {
    return outboundRunError(requireCertificateVerification(outboundJson)).length === 0;
  } catch (error) { return false; }
}

export function outboundRunError(outboundJson: string): string {
  if (outboundJson.length < 20) {
    return '节点配置不完整';
  }
  let outbound: Record<string, Object>;
  try {
    outbound = JSON.parse(outboundJson) as Record<string, Object>;
  } catch (error) {
    return '节点配置无法解析';
  }
  const protocol = asString(outbound['protocol'], '').toLowerCase();
  if (protocol.length === 0) {
    return '节点缺少协议';
  }
  if (hasAllowInsecure(outbound)) {
    return '拒绝关闭证书校验的节点';
  }
  if (protocol === 'shadowsocks') {
    return shadowsocksError(outbound);
  }
  if (protocol === 'trojan' || protocol === 'vmess') {
    return tlsStreamError(outbound, protocol);
  }
  if (protocol === 'vless') {
    return vlessError(outbound);
  }
  return `当前版本暂不支持 ${protocol}，导入后无法连接`;
}

function shadowsocksError(outbound: Record<string, Object>): string {
  const first = firstServer(outbound);
  if (first === null) {
    return 'Shadowsocks 节点缺少服务器';
  }
  const method = asString(first['method'], '').toLowerCase();
  const password = asString(first['password'], '');
  if (method.length === 0 || password.length === 0) {
    return 'Shadowsocks 节点缺少加密方法或密码';
  }
  if (AEAD_METHODS.indexOf(method) < 0) {
    return `Shadowsocks 加密方法不受支持：${method}`;
  }
  return '';
}

function vlessError(outbound: Record<string, Object>): string {
  const stream = streamOf(outbound);
  const security = asString(stream['security'], '').toLowerCase();
  if (security === 'reality') {
    return realityError(stream);
  }
  return tlsStreamError(outbound, 'vless');
}

function realityError(stream: Record<string, Object>): string {
  const raw = stream['realitySettings'];
  if (raw === undefined || typeof raw !== 'object') {
    return 'Reality 节点缺少 realitySettings';
  }
  const reality = raw as Record<string, Object>;
  if (reality['allowInsecure'] === true) {
    return '拒绝关闭证书校验的节点';
  }
  if (asString(reality['publicKey'], '').length === 0) {
    return 'Reality 节点缺少 publicKey';
  }
  const serverName = asString(reality['serverName'], '');
  if (serverName.length === 0 || looksLikeIp(serverName)) {
    return 'Reality 节点缺少可用的 serverName';
  }
  return '';
}

function tlsStreamError(outbound: Record<string, Object>, protocol: string): string {
  const stream = streamOf(outbound);
  if (asString(stream['security'], '').toLowerCase() !== 'tls') {
    return `${protocol} 需要 TLS`;
  }
  const raw = stream['tlsSettings'];
  if (raw === undefined || typeof raw !== 'object') {
    return '节点缺少 tlsSettings';
  }
  const tls = raw as Record<string, Object>;
  if (tls['allowInsecure'] === true) {
    return '拒绝关闭证书校验的节点';
  }
  let serverName = asString(tls['serverName'], '');
  if (serverName.length === 0) {
    serverName = firstServerAddress(outbound);
  }
  if (serverName.length === 0 || looksLikeIp(serverName)) {
    return '节点缺少可用的 serverName/SNI';
  }
  return '';
}

function hasAllowInsecure(outbound: Record<string, Object>): boolean {
  const stream = streamOf(outbound);
  const tls = stream['tlsSettings'];
  if (tls !== undefined && typeof tls === 'object') {
    if ((tls as Record<string, Object>)['allowInsecure'] === true) {
      return true;
    }
  }
  const reality = stream['realitySettings'];
  if (reality !== undefined && typeof reality === 'object') {
    if ((reality as Record<string, Object>)['allowInsecure'] === true) {
      return true;
    }
  }
  const first = firstServer(outbound);
  if (first !== null && (first['insecure'] === true || first['insecure'] === '1' ||
    first['insecure'] === 'true')) {
    return true;
  }
  return false;
}

function streamOf(outbound: Record<string, Object>): Record<string, Object> {
  const raw = outbound['streamSettings'];
  if (raw === undefined || typeof raw !== 'object') {
    return {};
  }
  return raw as Record<string, Object>;
}

function firstServer(outbound: Record<string, Object>): Record<string, Object> | null {
  const settingsValue = outbound['settings'];
  if (settingsValue === undefined || typeof settingsValue !== 'object') {
    return null;
  }
  const settings = settingsValue as Record<string, Object>;
  const fromVnext = firstRecord(settings['vnext']);
  if (fromVnext !== null) {
    return fromVnext;
  }
  return firstRecord(settings['servers']);
}

function firstRecord(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || !(value instanceof Array) || value.length === 0) {
    return null;
  }
  const first: Object = value[0];
  if (first === null || typeof first !== 'object') {
    return null;
  }
  return first as Record<string, Object>;
}

function firstServerAddress(outbound: Record<string, Object>): string {
  const first = firstServer(outbound);
  if (first === null) {
    return '';
  }
  return asString(first['address'], '');
}

function looksLikeIp(value: string): boolean {
  return isIpv4Literal(value) || isIpv6Literal(value);
}

function isIpv4Literal(value: string): boolean {
  const parts = value.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < 4; i++) {
    const part = parts[i];
    if (part.length === 0 || part.length > 3) {
      return false;
    }
    for (let j = 0; j < part.length; j++) {
      const ch = part.charAt(j);
      if (ch < '0' || ch > '9') {
        return false;
      }
    }
    if (part.length > 1 && part.charAt(0) === '0') {
      return false;
    }
    const n = Number(part);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

function isIpv6Literal(value: string): boolean {
  if (value.indexOf(':') < 0) {
    return false;
  }
  if (value.indexOf('.') >= 0) {
    return false;
  }
  const groups = value.split(':');
  if (groups.length < 3 || groups.length > 8) {
    return false;
  }
  let empty = 0;
  for (let i = 0; i < groups.length; i++) {
    const group = groups[i];
    if (group.length === 0) {
      empty += 1;
      continue;
    }
    if (group.length > 4) {
      return false;
    }
    for (let j = 0; j < group.length; j++) {
      const ch = group.charAt(j).toLowerCase();
      const hex = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
      if (!hex) {
        return false;
      }
    }
  }
  return empty <= 2;
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}
