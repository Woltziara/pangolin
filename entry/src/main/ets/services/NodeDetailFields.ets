// 穿山 (GPL-3.0) — 节点详情字段分组（基本 / 传输 / 安全）。
// 交互思路（分组展示 + 敏感字段默认打码）参考 Hey (GPL-3.0)
// entry/src/main/ets/features/nodes/NodeDetailFields.ets，参考日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 本文件为独立实现：中文标签直出、无 i18n 键；纯 TS，不 import 任何 @kit/@ohos 模块。

export class NodeDetailField {
  label: string = '';
  value: string = '';
  sensitive: boolean = false;
}

export class NodeDetailSection {
  title: string = '';
  fields: Array<NodeDetailField> = [];
}

/** 解析 outboundJson 为非空分组列表；解析失败返回空数组。 */
export function buildNodeDetailSections(outboundJson: string, protocol: string): Array<NodeDetailSection> {
  const sections: Array<NodeDetailSection> = [];
  let outbound: Record<string, Object> | null = null;
  try {
    outbound = objectValue(JSON.parse(outboundJson) as Object);
  } catch (error) {
    return sections;
  }
  if (outbound === null) {
    return sections;
  }

  const parsed = stringValue(outbound['protocol']).toLowerCase();
  const proto = parsed.length > 0 ? parsed : protocol.toLowerCase();
  const settings = objectValue(outbound['settings']);
  const stream = objectValue(outbound['streamSettings']);

  pushSection(sections, '基本', buildBasics(proto, settings));
  if (stream !== null) {
    pushSection(sections, '传输', buildTransport(stream));
    pushSection(sections, '安全', buildSecurity(stream));
  }
  return sections;
}

function buildBasics(proto: string, settings: Record<string, Object> | null): Array<NodeDetailField> {
  const fields: Array<NodeDetailField> = [];
  pushField(fields, '协议', proto.toUpperCase(), false);
  if (settings === null) {
    return fields;
  }

  if (proto === 'vless' || proto === 'vmess') {
    const server = firstRecord(settings['vnext']);
    const user = firstRecord(server !== null ? server['users'] : undefined);
    pushField(fields, '地址', server !== null ? stringValue(server['address']) : '', false);
    pushField(fields, '端口', server !== null ? stringValue(server['port']) : '', false);
    pushField(fields, '用户 ID', user !== null ? stringValue(user['id']) : '', true);
    if (proto === 'vmess') {
      pushField(fields, '加密方式', user !== null ? stringValue(user['security']) : '', false);
      const alterId = user !== null ? stringValue(user['alterId']) : '';
      if (alterId.length > 0 && alterId !== '0') {
        pushField(fields, 'AlterId', alterId, false);
      }
    } else {
      pushField(fields, '加密方式', user !== null ? stringValue(user['encryption']) : '', false);
      pushField(fields, '流控', user !== null ? stringValue(user['flow']) : '', false);
    }
    return fields;
  }

  if (proto === 'wireguard') {
    const peer = firstRecord(settings['peers']);
    pushField(fields, '对端地址', peer !== null ? stringValue(peer['endpoint']) : '', false);
    pushField(fields, '私钥', stringValue(settings['secretKey']), true);
    pushField(fields, '对端公钥', peer !== null ? stringValue(peer['publicKey']) : '', false);
    pushField(fields, '预共享密钥', peer !== null ? stringValue(peer['preSharedKey']) : '', true);
    pushField(fields, 'MTU', stringValue(settings['mtu']), false);
    return fields;
  }

  if (proto === 'tuic') {
    const server = firstRecord(settings['servers']);
    pushField(fields, '地址', server !== null ? stringValue(server['address']) : '', false);
    pushField(fields, '端口', server !== null ? stringValue(server['port']) : '', false);
    pushField(fields, 'UUID', server !== null ? stringValue(server['uuid']) : '', true);
    pushField(fields, '密码', server !== null ? stringValue(server['password']) : '', true);
    pushField(fields, '拥塞控制', server !== null ? stringValue(server['congestionControl']) : '', false);
    return fields;
  }

  const server = firstRecord(settings['servers']);
  pushField(fields, '地址', server !== null ? stringValue(server['address']) : '', false);
  pushField(fields, '端口', server !== null ? stringValue(server['port']) : '', false);
  if (proto === 'shadowsocks') {
    pushField(fields, '加密方式', server !== null ? stringValue(server['method']) : '', false);
    pushField(fields, '密码', server !== null ? stringValue(server['password']) : '', true);
  } else if (proto === 'trojan') {
    pushField(fields, '密码', server !== null ? stringValue(server['password']) : '', true);
    pushField(fields, '流控', server !== null ? stringValue(server['flow']) : '', false);
  } else if (proto === 'hysteria2') {
    pushField(fields, '密码', server !== null ? stringValue(server['password']) : '', true);
    pushField(fields, '混淆密码', server !== null ? stringValue(server['obfsPassword']) : '', true);
    pushField(fields, '端口跳跃', server !== null ? stringValue(server['portHopping']) : '', false);
  } else if (proto === 'anytls') {
    pushField(fields, '密码', server !== null ? stringValue(server['password']) : '', true);
  } else {
    const user = firstRecord(server !== null ? server['users'] : undefined);
    pushField(fields, '用户名', user !== null ? stringValue(user['user']) : '', false);
    pushField(fields, '密码', user !== null ? stringValue(user['pass']) : '', true);
  }
  return fields;
}

function buildTransport(stream: Record<string, Object>): Array<NodeDetailField> {
  const fields: Array<NodeDetailField> = [];
  const network = stringValue(stream['network']);
  pushField(fields, '传输方式', network.length > 0 ? network : 'tcp', false);

  const ws = objectValue(stream['wsSettings']);
  if (ws !== null) {
    pushField(fields, '路径', stringValue(ws['path']), false);
    const headers = objectValue(ws['headers']);
    pushField(fields, '伪装域名', headers !== null ? stringValue(headers['Host']) : '', false);
    return fields;
  }

  const grpc = objectValue(stream['grpcSettings']);
  if (grpc !== null) {
    pushField(fields, '服务名', stringValue(grpc['serviceName']), false);
    if (stringValue(grpc['multiMode']) === 'true') {
      pushField(fields, '模式', 'multi', false);
    }
    return fields;
  }

  const httpUpgrade = objectValue(stream['httpupgradeSettings']);
  if (httpUpgrade !== null) {
    pushField(fields, '路径', stringValue(httpUpgrade['path']), false);
    pushField(fields, '伪装域名', stringValue(httpUpgrade['host']), false);
    return fields;
  }

  const xhttp = objectValue(stream['xhttpSettings']);
  if (xhttp !== null) {
    pushField(fields, '路径', stringValue(xhttp['path']), false);
    pushField(fields, '伪装域名', stringValue(xhttp['host']), false);
    pushField(fields, '模式', stringValue(xhttp['mode']), false);
    return fields;
  }

  const http = objectValue(stream['httpSettings']);
  if (http !== null) {
    pushField(fields, '伪装域名', joinStringArray(http['host']), false);
    pushField(fields, '路径', stringValue(http['path']), false);
    return fields;
  }

  const kcp = objectValue(stream['kcpSettings']);
  if (kcp !== null) {
    const header = objectValue(kcp['header']);
    pushField(fields, '伪装类型', header !== null ? stringValue(header['type']) : '', false);
    pushField(fields, 'MTU', stringValue(kcp['mtu']), false);
    return fields;
  }

  const tcp = objectValue(stream['tcpSettings']);
  if (tcp !== null) {
    const header = objectValue(tcp['header']);
    const headerType = header !== null ? stringValue(header['type']) : '';
    if (headerType.length > 0 && headerType !== 'none') {
      pushField(fields, '伪装类型', headerType, false);
      const request = header !== null ? objectValue(header['request']) : null;
      const headers = request !== null ? objectValue(request['headers']) : null;
      pushField(fields, '伪装域名', headers !== null ? joinStringArray(headers['Host']) : '', false);
      pushField(fields, '路径', request !== null ? joinStringArray(request['path']) : '', false);
    }
  }
  return fields;
}

function buildSecurity(stream: Record<string, Object>): Array<NodeDetailField> {
  const fields: Array<NodeDetailField> = [];
  const security = stringValue(stream['security']).toLowerCase();
  if (security !== 'tls' && security !== 'reality') {
    return fields;
  }
  pushField(fields, '安全层', security.toUpperCase(), false);

  let tls = objectValue(stream['tlsSettings']);
  if (tls === null) {
    tls = objectValue(stream['realitySettings']);
  }
  if (tls !== null) {
    pushField(fields, 'SNI', stringValue(tls['serverName']), false);
    pushField(fields, '指纹', stringValue(tls['fingerprint']), false);
    pushField(fields, 'ALPN', joinStringArray(tls['alpn']), false);
    if (stringValue(tls['allowInsecure']) === 'true') {
      pushField(fields, '跳过证书验证', '是', false);
    }
    pushField(fields, 'REALITY 公钥', stringValue(tls['publicKey']), false);
    pushField(fields, 'Short ID', stringValue(tls['shortId']), false);
    pushField(fields, 'SpiderX', stringValue(tls['spiderX']), false);
  }
  return fields;
}

function pushSection(sections: Array<NodeDetailSection>, title: string, fields: Array<NodeDetailField>): void {
  if (fields.length > 0) {
    const section = new NodeDetailSection();
    section.title = title;
    section.fields = fields;
    sections.push(section);
  }
}

function pushField(fields: Array<NodeDetailField>, label: string, value: string, sensitive: boolean): void {
  const trimmed = value.trim();
  if (trimmed.length > 0) {
    const field = new NodeDetailField();
    field.label = label;
    field.value = trimmed;
    field.sensitive = sensitive;
    fields.push(field);
  }
}

function joinStringArray(value: Object | undefined): string {
  if (!Array.isArray(value)) {
    return '';
  }
  const values = value as Array<Object>;
  const parts: Array<string> = [];
  for (let i = 0; i < values.length; i++) {
    const part = stringValue(values[i]);
    if (part.length > 0) {
      parts.push(part);
    }
  }
  return parts.join(', ');
}

function firstRecord(value: Object | undefined): Record<string, Object> | null {
  if (!Array.isArray(value) || value.length === 0) {
    return null;
  }
  const values = value as Array<Object>;
  return objectValue(values[0]);
}

function objectValue(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

function stringValue(value: Object | undefined): string {
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return `${value}`;
  }
  return '';
}
