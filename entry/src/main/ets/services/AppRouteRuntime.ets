import { bundleManager, common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { AppNodePort, AppRoutePayload, AppUidBinding, addUidBinding, parseAppRoutePayload, portForUid } from '../core/AppRoutePayload';
import { ObservedApp } from '../core/AppRouteModel';
import { newSocksSession } from '../core/XrayRuntime';
import { ackAppRoute, AppFlowRequest, clearAppRouteCallback, setAppRouteCallback } from '../native/TunnelNative';
import { AppCatalog, OBSERVED_APPS_FILE } from './AppCatalog';
import { StatusStore } from './StatusStore';

/** One immutable configured identity snapshot per VPN generation; no persistent UID authority. */
export class AppRouteRuntime {
  ports: AppNodePort[] = [];
  private bindings: AppUidBinding[] = [];
  private enabled: boolean = false;
  private active: boolean = false;
  private resolving: number = 0;
  private context: common.Context;
  private observed: ObservedApp[] = [];
  private recorded: Set<number> = new Set<number>();
  // Session-local, count-only telemetry. Do not retain flow tuples, UIDs,
  // bundle names, ports, or error strings: diagnostics only establish whether
  // the app-identity bridge made a routing decision.
  private queries: number = 0;
  private selected: number = 0;
  private defaulted: number = 0;
  private rejected: number = 0;
  private ownerQueryFailed: number = 0;
  private identityMismatch: number = 0;
  private overloaded: number = 0;
  private inactive: number = 0;
  private ackFailed: number = 0;
  private tcpQueries: number = 0;
  private udpQueries: number = 0;

  constructor(context: common.Context) { this.context = context; }

  static async prepare(context: common.Context, payload: string, defaultPort: number): Promise<AppRouteRuntime> {
    const runtime = new AppRouteRuntime(context);
    const parsed = JSON.parse(payload) as Record<string, Object>;
    // Direct mode explicitly pauses App routing, including missing-node checks.
    if (parsed['routeMode'] === 'direct') { return runtime; }
    const app = parseAppRoutePayload(parsed['appRouting']);
    runtime.enabled = app.config.enabled;
    if (!runtime.enabled) { return runtime; }
    try { runtime.observed = AppCatalog.observed(context).slice(0, 128); } catch (error) { runtime.observed = []; }
    for (let i = 0; i < app.config.rules.length; i++) {
      const rule = app.config.rules[i];
      if (!rule.enabled) { continue; }
      const resolved = await AppCatalog.resolve(rule.bundleName);
      const binding = new AppUidBinding();
      binding.uid = resolved.uid; binding.bundleName = rule.bundleName; binding.nodeId = rule.nodeId;
      addUidBinding(runtime.bindings, binding);
    }
    runtime.reallocate(defaultPort);
    return runtime;
  }

  reallocate(defaultPort: number): void {
    this.ports = [];
    const used = new Set<number>(); used.add(defaultPort);
    this.bindings.forEach((binding: AppUidBinding) => {
      if (this.ports.some((item: AppNodePort) => item.nodeId === binding.nodeId)) { return; }
      let port = 0;
      for (let attempt = 0; attempt < 16; attempt++) {
        port = newSocksSession().port;
        if (!used.has(port)) { break; }
        port = 0;
      }
      if (port === 0) { throw new Error('无法分配互不冲突的 App 分流端口'); }
      used.add(port);
      const mapping = new AppNodePort(); mapping.nodeId = binding.nodeId; mapping.port = port;
      this.ports.push(mapping);
    });
  }

  install(): void {
    clearAppRouteCallback();
    if (!this.enabled) { return; }
    this.active = true;
    if (setAppRouteCallback((flow: AppFlowRequest): void => { this.resolveFlow(flow); }) !== 0) {
      this.active = false; throw new Error('App 身份查询桥接初始化失败');
    }
  }
  stop(): void { this.active = false; clearAppRouteCallback(); }

  /**
   * Return only count-only state for the current VPN generation. This is
   * deliberately synchronous and memory-only so querying diagnostics cannot
   * create a per-flow record or expose app/network identity metadata.
   */
  diagnostics(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['enabled'] = this.enabled;
    out['active'] = this.active;
    out['configuredRules'] = this.bindings.length;
    out['pending'] = this.resolving;
    out['queries'] = this.queries;
    out['selected'] = this.selected;
    out['defaulted'] = this.defaulted;
    out['rejected'] = this.rejected;
    out['ownerQueryFailed'] = this.ownerQueryFailed;
    out['identityMismatch'] = this.identityMismatch;
    out['overloaded'] = this.overloaded;
    out['inactive'] = this.inactive;
    out['ackFailed'] = this.ackFailed;
    out['tcpQueries'] = this.tcpQueries;
    out['udpQueries'] = this.udpQueries;
    return out;
  }

  private ack(flow: AppFlowRequest, status: number, port: number): void {
    const result = ackAppRoute(flow.requestId, status, port);
    if (result !== 0) { this.ackFailed += 1; }
  }

  private async resolveFlow(flow: AppFlowRequest): Promise<void> {
    if (!this.active) {
      this.inactive += 1;
      this.rejected += 1;
      this.ack(flow, -1, 0);
      return;
    }
    if (this.resolving >= 128) {
      this.overloaded += 1;
      this.rejected += 1;
      this.ack(flow, -1, 0);
      return;
    }
    this.queries += 1;
    if (flow.protocol === 6) { this.tcpQueries += 1; }
    if (flow.protocol === 17) { this.udpQueries += 1; }
    this.resolving += 1;
    let port = -1;
    try {
      const local: connection.NetAddress = { address: flow.sourceAddress,
        family: flow.family === 6 ? 2 : 1, port: flow.sourcePort };
      const remote: connection.NetAddress = { address: flow.destinationAddress,
        family: flow.family === 6 ? 2 : 1, port: flow.destinationPort };
      const protocol = flow.protocol === 6 ? connection.ProtocolType.PROTO_TYPE_TCP : connection.ProtocolType.PROTO_TYPE_UDP;
      const uid = await connection.getConnectOwnerUid(protocol, local, remote);
      port = portForUid(uid, this.bindings, this.ports);
      if (port > 0) {
        // Confirm identity as well as UID: an uninstall/reinstall must not redirect a different app.
        const bundle = await bundleManager.getBundleNameByUid(uid);
        if (!this.bindings.some((item: AppUidBinding) => item.uid === uid && item.bundleName === bundle)) {
          this.identityMismatch += 1;
          port = -1;
        }
      }
      if (this.active && uid >= 0) { this.observe(uid); }
    } catch (error) {
      // This includes getConnectOwnerUid and the identity confirmation lookup;
      // retain the existing route outcome while recording no raw SDK detail.
      this.ownerQueryFailed += 1;
      port = this.bindings.length > 0 ? -1 : 0;
    }
    finally { this.resolving -= 1; }
    if (!this.active) {
      this.inactive += 1;
      this.rejected += 1;
      port = -1;
    } else if (port < 0) {
      this.rejected += 1;
    } else if (port === 0) {
      this.defaulted += 1;
    } else {
      this.selected += 1;
    }
    this.ack(flow, port < 0 ? -1 : port === 0 ? 1 : 0, Math.max(0, port));
  }

  private async observe(uid: number): Promise<void> {
    if (this.recorded.has(uid) || this.recorded.size >= 128) { return; }
    this.recorded.add(uid);
    try {
      const bundle = await bundleManager.getBundleNameByUid(uid);
      const app = await AppCatalog.resolve(bundle);
      if (!this.active || app.uid !== uid) { return; }
      this.observed = this.observed.filter((item: ObservedApp) => item.bundleName !== bundle);
      this.observed.unshift(app); this.observed = this.observed.slice(0, 128);
      const record: Record<string, Object> = {};
      record['version'] = 1; record['items'] = this.observed;
      StatusStore.writeJsonAtomic(this.context, OBSERVED_APPS_FILE, JSON.stringify(record));
    } catch (error) { /* System/service UIDs may have no visible bundle; no invented identity. */ }
  }
}
