import { common } from '@kit.AbilityKit';
import { connection, socket, vpnExtension } from '@kit.NetworkKit';
import { NodeStore, StoredNode } from './NodeStore';
import { StatusStore } from './StatusStore';
import { isConnectionEstablished } from '../net/ConnectionHealth';
import { createVpnAbilityWant } from '../vpn/VpnConstants';

export const NODE_LATENCY_FILE: string = 'node-latency-test.json';
export class NodeLatencySample {
  id: string = '';
  milliseconds: number = -1;
  text: string = '失败';
}
export class NodeLatencyBatch {
  runId: string = '';
  selectedNodeId: string = '';
  region: string = '';
  generation: string = '';
  metric: string = 'tcp-connect-ms';
  at: number = Date.now();
  total: number = 0;
  complete: boolean = false;
  outcome: string = 'running';
  samples: NodeLatencySample[] = [];
}
class NodeLatencyTest {
  private busy: boolean = false;
  private lastRunId: string = '';

  async begin(context: common.UIAbilityContext, selectedNodeId: string = ''): Promise<string> {
    if (this.busy) { throw new Error('test-busy'); }
    const status = StatusStore.readStatus(context);
    const live = isConnectionEstablished(status, Date.now());
    if (!live && status.desiredRunning) { throw new Error('connection-changing'); }
    if (!live) {
      const nets = await connection.getAllNets();
      for (let i = 0; i < nets.length; i++) {
        const caps = await connection.getNetCapabilities(nets[i]);
        if (caps.bearerTypes.indexOf(connection.NetBearType.BEARER_VPN) >= 0) { throw new Error('other-vpn-active'); }
      }
    }
    const runId = `n${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const pending = new NodeLatencyBatch();
    pending.runId = runId;
    pending.selectedNodeId = selectedNodeId;
    pending.generation = live ? status.generation : '';
    this.publish(context, pending);
    if (live) {
      const want = createVpnAbilityWant();
      want.parameters = { command: 'diagnose-node-latency', generation: status.generation, runId: runId,
        selectedNodeId: selectedNodeId };
      await vpnExtension.startVpnExtensionAbility(want);
    } else {
      this.run(context, runId, '', selectedNodeId).catch(() => {});
    }
    return runId;
  }

  async run(context: common.Context, runId: string, generation: string, selectedNodeId: string = ''): Promise<void> {
    if (this.busy || this.lastRunId === runId || !/^[a-zA-Z0-9_-]{1,64}$/.test(runId)) { return; }
    this.busy = true;
    this.lastRunId = runId;
    const batch = new NodeLatencyBatch();
    batch.runId = runId; batch.generation = generation;
    batch.selectedNodeId = selectedNodeId;
    try {
      let nodes = NodeStore.loadNodes(context);
      if (selectedNodeId.length > 0) {
        const selected = nodes.find((node: StoredNode) => node.id === selectedNodeId);
        if (selected === undefined) { batch.outcome = 'selected-node-missing'; return; }
        batch.region = selected.region;
        const peers = selected.region.length > 0 ? nodes.filter((node: StoredNode) =>
          node.id !== selected.id && node.region === selected.region) : [];
        nodes = [selected].concat(peers);
      }
      batch.total = nodes.length;
      this.publish(context, batch);
      for (let offset = 0; offset < nodes.length; offset += 4) {
        const status = StatusStore.readStatus(context);
        if ((generation.length > 0 && (status.generation !== generation || !isConnectionEstablished(status, Date.now()))) ||
          (generation.length === 0 && status.desiredRunning)) {
          batch.outcome = 'connection-changed'; return;
        }
        const jobs: Promise<NodeLatencySample>[] = [];
        for (let i = offset; i < Math.min(offset + 4, nodes.length); i++) { jobs.push(this.sample(nodes[i])); }
        const results = await Promise.all(jobs);
        const after = StatusStore.readStatus(context);
        if ((generation.length > 0 && (after.generation !== generation || !isConnectionEstablished(after, Date.now()))) ||
          (generation.length === 0 && after.desiredRunning)) { batch.outcome = 'connection-changed'; return; }
        batch.samples = batch.samples.concat(results);
        this.publish(context, batch);
      }
      batch.outcome = 'measured';
    } catch (error) {
      batch.outcome = 'failed';
    } finally {
      batch.complete = true; this.busy = false; this.publish(context, batch);
    }
  }

  private publish(context: common.Context, batch: NodeLatencyBatch): void {
    batch.at = Date.now();
    StatusStore.writeText(context, NODE_LATENCY_FILE, JSON.stringify(batch));
  }

  private async sample(node: StoredNode): Promise<NodeLatencySample> {
    const result = new NodeLatencySample(); result.id = node.id;
    let tcp: socket.TCPSocket | null = null;
    try {
      const host = node.server.replace(/^\[|\]$/g, '');
      let candidates: string[] = [host];
      if (!/^\d+\.\d+\.\d+\.\d+$/.test(host) && host.indexOf(':') < 0) {
        const addresses = await this.bounded(connection.getAddressesByName(host), 2000);
        const ipv4 = addresses.filter((a: connection.NetAddress) => /^\d+\.\d+\.\d+\.\d+$/.test(a.address));
        const ipv6 = addresses.filter((a: connection.NetAddress) => a.address.indexOf(':') >= 0);
        // One address per family, bounded to two attempts. This is a TCP
        // sample, not the live Xray race or an authenticated speed test.
        candidates = [];
        if (ipv4.length > 0) { candidates.push(ipv4[0].address); }
        if (ipv6.length > 0) { candidates.push(ipv6[0].address); }
        if (candidates.length === 0) { result.text = '无可用地址'; return result; }
      }
      for (let i = 0; i < candidates.length; i++) {
        const ip = candidates[i];
        tcp = socket.constructTCPSocketInstance();
        try {
          const started = Date.now();
          await this.bounded(tcp.connect({address:{address:ip,port:node.port,family:ip.indexOf(':') >= 0 ? 2 : 1},timeout:2500}), 2500);
          result.milliseconds = Math.max(1, Date.now() - started);
          result.text = `${result.milliseconds} ms`;
          return result;
        } catch (error) {
          if (i === candidates.length - 1) { throw new Error((error as Error).message); }
        } finally {
          try { await this.bounded(tcp.close(), 500); } catch (error) {}
          tcp = null;
        }
      }
    } catch (error) {
      result.milliseconds = -1;
      result.text = (error as Error).message === 'node-latency-timeout' ? '超时' : '失败';
    } finally {
      if (tcp !== null) { try { await this.bounded(tcp.close(), 500); } catch (error) {} }
    }
    return result;
  }

  private async bounded<T>(work: Promise<T>, milliseconds: number): Promise<T> {
    let timer = -1;
    const timeout = new Promise<T>((_resolve: (value: T) => void, reject: (reason: Error) => void) => {
      timer = setTimeout(() => { reject(new Error('node-latency-timeout')); }, milliseconds);
    });
    try { return await Promise.race([work, timeout]); }
    finally { if (timer >= 0) { clearTimeout(timer); } }
  }
}
export const NODE_LATENCY_TEST: NodeLatencyTest = new NodeLatencyTest();
