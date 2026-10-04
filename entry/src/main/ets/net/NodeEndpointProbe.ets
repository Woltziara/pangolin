import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection, socket } from '@kit.NetworkKit';
import { nodeEndpointSpec, NodeEndpointSpec } from '../core/NodeEndpointSpec';
import { LATENCY_PROBE } from '../services/LatencyProbe';
import { StatusStore } from '../services/StatusStore';

class EndpointBatch {
  schema: string = 'chuanshan-node-endpoint@1';
  implementation: string = 'system-tls-socket-not-xray';
  runId: string = '';
  generation: string = '';
  at: number = Date.now();
  complete: boolean = false;
  outcome: string = 'running';
  samples: Array<Record<string, Object>> = [];
}

class NodeEndpointProbe {
  private busy: boolean = false;
  private lastRunId: string = '';

  private publish(context: common.Context, batch: EndpointBatch): void {
    batch.at = Date.now();
    StatusStore.writeText(context, 'latency-node-endpoint.json', JSON.stringify(batch));
  }

  async run(context: common.Context, payload: string, generation: string, runId: string): Promise<void> {
    if (this.busy || !LATENCY_PROBE.validRunId(runId) || this.lastRunId === runId) { return; }
    this.busy = true;
    this.lastRunId = runId;
    const batch = new EndpointBatch();
    batch.runId = runId;
    batch.generation = generation;
    try {
      const spec = nodeEndpointSpec(payload);
      if (spec === null) { batch.outcome = 'current-node-not-supported-by-tls-only-probe'; return; }
      this.publish(context, batch);
      for (let i = 0; i < 2; i++) {
        const status = StatusStore.readStatus(context);
        if (status.generation !== generation || !status.desiredRunning || !status.xrayRunning) {
          batch.outcome = 'session-changed'; return;
        }
        const sample = await this.sample(spec);
        sample['round'] = i + 1;
        batch.samples.push(sample);
        this.publish(context, batch);
      }
      batch.outcome = 'measured';
    } finally {
      batch.complete = true;
      this.busy = false;
      this.publish(context, batch);
    }
  }

  private async sample(spec: NodeEndpointSpec): Promise<Record<string, Object>> {
    const result: Record<string, Object> = {};
    const started = Date.now();
    result['startedAt'] = started;
    result['target'] = 'current-node-tls-only';
    result['proxyAuthenticated'] = false;
    result['dnsDoneMs'] = -1;
    result['tcpDoneMs'] = -1;
    result['tlsDoneMs'] = -1;
    result['tlsVerified'] = false;
    let stage = 'dns';
    let tcp: socket.TCPSocket | null = null;
    let tls: socket.TLSSocket | null = null;
    try {
      let ip = spec.host.replace(/^\[|\]$/g, '');
      if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip) && ip.indexOf(':') < 0) {
        const addresses = await this.bounded(connection.getAddressesByName(spec.host), 6000);
        const ipv4 = addresses.filter((address: connection.NetAddress) => {
          return /^\d+\.\d+\.\d+\.\d+$/.test(address.address);
        });
        const ipv6 = addresses.filter((address: connection.NetAddress) => address.address.indexOf(':') >= 0);
        if (ipv4.length === 0 && ipv6.length === 0) { throw new Error('node-address-unavailable'); }
        ip = ipv4.length > 0 ? ipv4[0].address : ipv6[0].address;
        result['resolvedAddressCount'] = addresses.length;
      }
      result['dnsDoneMs'] = Date.now() - started;
      stage = 'tcp';
      tcp = socket.constructTCPSocketInstance();
      const family = ip.indexOf(':') >= 0 ? 2 : 1;
      result['addressFamily'] = family === 2 ? 'IPv6' : 'IPv4';
      await this.bounded(tcp.connect({ address: { address: ip, port: spec.port, family: family }, timeout: 6000 }), 6500);
      result['tcpDoneMs'] = Date.now() - started;
      stage = 'tls';
      // The SDK supports upgrading an established TCP socket before any data
      // is sent. The existing TCP peer is retained; address supplies TLS name.
      tls = socket.constructTLSSocketInstance(tcp);
      tcp = null;
      const protocols: socket.Protocol[] = [];
      if (spec.minVersion !== '1.3') { protocols.push(socket.Protocol.TLSv12); }
      if (spec.maxVersion !== '1.2') { protocols.push(socket.Protocol.TLSv13); }
      await this.bounded(tls.connect({
        address: { address: spec.serverName, port: spec.port, family: family },
        secureOptions: { protocols: protocols },
        ALPNProtocols: spec.alpn,
        skipRemoteValidation: false,
        timeout: 6000
      }), 6500);
      result['tlsDoneMs'] = Date.now() - started;
      result['tlsVerified'] = true;
      const remote = await tls.getRemoteAddress();
      result['peerMatchesResolvedNode'] = remote.address.replace('::ffff:', '') === ip;
      result['protocol'] = await tls.getProtocol();
      result['ok'] = result['peerMatchesResolvedNode'] === true;
    } catch (error) {
      const business = error as BusinessError;
      result['ok'] = false;
      result['failureStage'] = stage;
      result['errorCode'] = typeof business.code === 'number' ? business.code : -1;
    } finally {
      result['closeStartMs'] = Date.now() - started;
      try {
        if (tls !== null) { await this.bounded(tls.close(), 3000); }
        else if (tcp !== null) { await this.bounded(tcp.close(), 3000); }
      } catch (error) {
        result['closeFailed'] = true;
      }
      result['closeDoneMs'] = Date.now() - started;
    }
    return result;
  }

  private async bounded<T>(work: Promise<T>, milliseconds: number): Promise<T> {
    let timer = -1;
    const timeout = new Promise<T>((_resolve: (value: T) => void, reject: (reason: Error) => void) => {
      timer = setTimeout(() => { reject(new Error('diagnostic-deadline')); }, milliseconds);
    });
    try { return await Promise.race([work, timeout]); }
    finally { if (timer >= 0) { clearTimeout(timer); } }
  }
}

export const NODE_ENDPOINT_PROBE = new NodeEndpointProbe();
