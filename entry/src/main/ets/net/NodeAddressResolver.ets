import { connection } from '@kit.NetworkKit';

// Rebuilt on every session/recovery; no permanent IP pin or app DNS cache.
// Preserve endpoint names for TLS, Reality, WS Host and gRPC authority. Only
// node transport sockets consume these OS-resolved IPv4/IPv6 mappings.
// Xray races TCP addresses with bounded concurrency; IPv4 starts first to
// retain the proven fast path while IPv6 remains available after 250 ms.
export async function withSystemResolvedNodes(configJson: string): Promise<string> {
  const config = JSON.parse(configJson) as Record<string, Object>;
  const outbounds = config['outbounds'] as Array<Record<string, Object>>;
  const dns = config['dns'] as Record<string, Object>;
  const hosts: Record<string, Object> = dns['hosts'] !== undefined ? dns['hosts'] as Record<string, Object> : {};
  const resolved = new Map<string, string[]>();
  for (let i = 0; i < outbounds.length; i++) {
    const outbound = outbounds[i];
    const tag = outbound['tag'];
    if (tag !== 'proxy' && tag !== 'proxy-yt' &&
      !(typeof tag === 'string' && /^app-node-\d+$/.test(tag))) { continue; }
    const settings = outbound['settings'] as Record<string, Object>;
    const endpoints = (Array.isArray(settings['servers']) ? settings['servers'] : settings['vnext']) as Array<Record<string, Object>>;
    if (!Array.isArray(endpoints) || endpoints.length === 0) { throw new Error('节点缺少连接地址。'); }
    const stream: Record<string, Object> = outbound['streamSettings'] !== undefined ? outbound['streamSettings'] as Record<string, Object> : {};
    const names: string[] = [];
    for (let j = 0; j < endpoints.length; j++) {
      const address = endpoints[j]['address'];
      if (typeof address !== 'string' || address.length === 0) { throw new Error('节点缺少连接地址。'); }
      names.push(address);
    }
    if (typeof stream['address'] === 'string') { names.push(stream['address'] as string); }
    for (let j = 0; j < names.length; j++) {
      const host = names[j];
      if (isIpv4(host) || host.indexOf(':') >= 0) { continue; }
      let addresses = resolved.get(host);
      if (addresses === undefined) { addresses = await resolveAddresses(host); resolved.set(host, addresses); }
      hosts[host] = addresses;
    }
    const sockopt: Record<string, Object> = stream['sockopt'] !== undefined ? stream['sockopt'] as Record<string, Object> : {};
    sockopt['domainStrategy'] = 'ForceIP';
    const race: Record<string, Object> = {};
    race['prioritizeIPv6'] = false;
    race['tryDelayMs'] = 250;
    race['interleave'] = 1;
    race['maxConcurrentTry'] = 2;
    sockopt['happyEyeballs'] = race;
    stream['sockopt'] = sockopt;
    outbound['streamSettings'] = stream;
  }
  // Xray's global queryStrategy filters even static hosts before lookup.
  // Permit both families for OS-resolved node hosts, while keeping ordinary
  // upstream website resolution IPv4-only as in the existing runtime policy.
  if (dns['queryStrategy'] === 'UseIPv4') {
    const servers = dns['servers'] as Object[];
    const scoped: Object[] = [];
    for (let i = 0; i < servers.length; i++) {
      let server: Record<string, Object>;
      if (typeof servers[i] === 'string') {
        server = {};
        server['address'] = servers[i];
      } else {
        server = servers[i] as Record<string, Object>;
      }
      server['queryStrategy'] = 'UseIPv4';
      scoped.push(server);
    }
    dns['servers'] = scoped;
    dns['queryStrategy'] = 'UseIP';
  }
  dns['hosts'] = hosts;
  return JSON.stringify(config);
}

function isIpv4(value: string): boolean {
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(value)) { return false; }
  const parts = value.split('.');
  return parts.every((part: string) => Number(part) >= 0 && Number(part) <= 255);
}

async function resolveAddresses(host: string): Promise<string[]> {
    let timer = -1;
    const timeout = new Promise<connection.NetAddress[]>((_resolve: (value: connection.NetAddress[]) => void,
      reject: (reason: Error) => void) => {
      timer = setTimeout(() => { reject(new Error('节点地址解析超时，请检查当前网络。')); }, 6000);
    });
    let addresses: connection.NetAddress[] = [];
    try { addresses = await Promise.race([connection.getAddressesByName(host), timeout]); }
    finally { if (timer >= 0) { clearTimeout(timer); } }
    const ips: string[] = [];
    for (let i = 0; i < addresses.length; i++) {
      const address = addresses[i].address;
      if ((isIpv4(address) || address.indexOf(':') >= 0) && ips.indexOf(address) < 0) { ips.push(address); }
    }
    if (ips.length === 0) { throw new Error('节点没有可用的 IPv4 或 IPv6 地址，请检查当前网络。'); }
    return ips;
}
