// Select only non-credential connection parameters from the active payload.
// The probe never serializes this object and never authenticates to the node.
export class NodeEndpointSpec {
  host: string = '';
  port: number = 0;
  serverName: string = '';
  minVersion: string = '';
  maxVersion: string = '';
  alpn: string[] = [];
}

export function nodeEndpointSpec(payload: string): NodeEndpointSpec | null {
  try {
    const doc = JSON.parse(payload) as Record<string, Object>;
    const outbound = (doc['v'] === 3 || doc['v'] === 2 ? doc['us'] :
      doc['v'] === 4 ? doc['single'] : doc) as Record<string, Object>;
    if (outbound['protocol'] !== 'trojan') { return null; }
    const stream = outbound['streamSettings'] as Record<string, Object>;
    if (stream['security'] !== 'tls' ||
      (stream['network'] !== undefined && stream['network'] !== 'tcp' && stream['network'] !== 'raw')) {
      return null;
    }
    const tls = stream['tlsSettings'] as Record<string, Object>;
    if (tls['allowInsecure'] === true) { return null; }
    const settings = outbound['settings'] as Record<string, Object>;
    const servers = settings['servers'] as Array<Record<string, Object>>;
    const server = servers[0];
    const spec = new NodeEndpointSpec();
    spec.host = typeof server['address'] === 'string' ? server['address'] as string : '';
    spec.port = typeof server['port'] === 'number' ? server['port'] as number : 0;
    spec.serverName = typeof tls['serverName'] === 'string' ? tls['serverName'] as string : spec.host;
    spec.minVersion = typeof tls['minVersion'] === 'string' ? tls['minVersion'] as string : '';
    spec.maxVersion = typeof tls['maxVersion'] === 'string' ? tls['maxVersion'] as string : '';
    if (Array.isArray(tls['alpn'])) {
      const alpn = tls['alpn'] as Object[];
      for (let i = 0; i < alpn.length && i < 8; i++) {
        if (typeof alpn[i] === 'string') { spec.alpn.push(alpn[i] as string); }
      }
    }
    if (spec.host.length === 0 || spec.serverName.length === 0 || spec.port < 1 || spec.port > 65535) {
      return null;
    }
    return spec;
  } catch (error) {
    return null;
  }
}
