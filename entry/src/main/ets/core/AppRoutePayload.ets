import { AppRoutingConfig, normalizeAppRoutingConfig } from './AppRouteModel';

export class AppNodeOutbound {
  nodeId: string = '';
  outbound: Record<string, Object> = {};
}
export class AppRoutePayload {
  config: AppRoutingConfig = new AppRoutingConfig();
  nodes: AppNodeOutbound[] = [];
}
export class AppNodePort {
  nodeId: string = '';
  port: number = 0;
}
export class AppUidBinding {
  uid: number = -1;
  bundleName: string = '';
  nodeId: string = '';
}
export function parseAppRoutePayload(value: Object | undefined): AppRoutePayload {
  const result = new AppRoutePayload();
  if (value === undefined) { return result; }
  if (value === null || typeof value !== 'object') { throw new Error('App 分流配置结构无效'); }
  const rec = value as Record<string, Object>;
  result.config = normalizeAppRoutingConfig(JSON.stringify(rec['config']));
  if (!Array.isArray(rec['nodes']) || (rec['nodes'] as Object[]).length > 64) {
    throw new Error('App 分流节点结构无效');
  }
  const ids = new Set<string>();
  (rec['nodes'] as Object[]).forEach((value: Object) => {
    if (value === null || typeof value !== 'object') { throw new Error('App 分流节点无效'); }
    const item = value as Record<string, Object>;
    if (typeof item['nodeId'] !== 'string' || item['nodeId'].length === 0 || ids.has(item['nodeId']) ||
      item['outbound'] === null || typeof item['outbound'] !== 'object' || Array.isArray(item['outbound'])) {
      throw new Error('App 分流节点缺失或重复');
    }
    const node = new AppNodeOutbound();
    node.nodeId = item['nodeId']; node.outbound = item['outbound'] as Record<string, Object>;
    result.nodes.push(node); ids.add(node.nodeId);
  });
  if (result.config.enabled) {
    result.config.rules.forEach((rule) => {
      if (rule.enabled && !ids.has(rule.nodeId)) { throw new Error(`App 指定的节点已不存在：${rule.label}`); }
    });
  }
  return result;
}
export function addUidBinding(bindings: AppUidBinding[], binding: AppUidBinding): void {
  if (!Number.isSafeInteger(binding.uid) || binding.uid < 0) { throw new Error('App UID 无效'); }
  const previous = bindings.find((item: AppUidBinding) => item.uid === binding.uid);
  if (previous !== undefined && previous.nodeId !== binding.nodeId) {
    throw new Error(`这两个 App 共用系统 UID，不能分别指定节点：${previous.bundleName} / ${binding.bundleName}`);
  }
  bindings.push(binding);
}
// -1: cannot identify, 0: known but unmapped, >0: explicit node port.
export function portForUid(uid: number, bindings: AppUidBinding[], ports: AppNodePort[]): number {
  if (!Number.isSafeInteger(uid) || uid < 0) { return bindings.length > 0 ? -1 : 0; }
  const binding = bindings.find((item: AppUidBinding) => item.uid === uid);
  if (binding === undefined) { return 0; }
  const port = ports.find((item: AppNodePort) => item.nodeId === binding.nodeId);
  return port === undefined || port.port < 1 || port.port > 65535 ? -1 : port.port;
}
