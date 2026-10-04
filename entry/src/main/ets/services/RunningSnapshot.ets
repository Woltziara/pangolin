import { Revocations } from './Revocations';
import { common } from '@kit.AbilityKit';
import { digestText } from '../core/OutboundCommit';
import { parseAppRoutePayload } from '../core/AppRoutePayload';
import { DataplaneStatus } from '../net/DataplaneStatus';
import { HuksSecretStore } from './HuksSecretStore';
import { NodeStore, StoredNode } from './NodeStore';
import { SettingsStore } from './SettingsStore';
import { StatusStore } from './StatusStore';
import { AppRouteCapability } from './AppRouteCapability';

export const RUNNING_SNAPSHOT_FILE: string = 'running-recovery.huks';
export class SnapshotNode {
  id: string = '';
  sourceId: string = '';
  region: string = '';
  outboundDigest: string = '';
}
export class RecoverySnapshot {
  purpose: string = 'pangolin-running-recovery-v2';
  id: string = '';
  generation: string = '';
  revision: number = 0;
  payload: string = '';
  payloadDigest: string = '';
  intent: Record<string, Object> = {};
  nodes: SnapshotNode[] = [];
  allowedRegions: string[] = [];
  routeMode: string = '';
  rulesDigest: string = '';
}

// The payload and node definitions live only inside authenticated HUKS
// encryption. No payload/credentials cross Want, the UI log or a manifest.
export class RunningSnapshot {
  private static boundPayload: string = '';
  private static boundNodes: SnapshotNode[] = [];
  static assertAuthorized(context: common.Context, payload: string, intent: Record<string, Object> | null): void {
    const revision = intent !== null && typeof intent['authorizedRevision'] === 'number' ? intent['authorizedRevision'] as number : 0;
    const revoked = Revocations.keys(context, revision);
    if (revoked.length === 0) return;
    const nodes = RunningSnapshot.boundPayload === payload && RunningSnapshot.boundNodes.length > 0 ?
      RunningSnapshot.boundNodes : RunningSnapshot.bindings(payload, NodeStore.loadNodes(context));
    if (nodes.some((node: SnapshotNode) => revoked.indexOf(`node:${node.id}`) >= 0 || revoked.indexOf(`source:${node.sourceId}`) >= 0))
      throw new Error('当前运行线路的节点或来源已被明确删除；停止自动恢复，不使用撤销的凭据。');
  }
  static async record(context: common.Context, payload: string, status: DataplaneStatus,
    previousIntent: Record<string, Object> | null = null, commitAllowed: () => boolean = (): boolean => true): Promise<void> {
    const snap = new RecoverySnapshot();
    snap.id = `${status.generation}-${status.sessionRevision}`;
    snap.generation = status.generation; snap.revision = status.sessionRevision;
    // Full executing payload is authenticated in bounded HUKS chunks. Catalog updates
    // cannot substitute a different credential set into this immutable snapshot.
    snap.payload = payload; snap.payloadDigest = digestText(payload);
    const settings = SettingsStore.load(context);
    if (previousIntent !== null) snap.intent = previousIntent;
    else {
      snap.intent['authorizedRevision'] = Revocations.revision(context);
      snap.intent['singleNodeId'] = settings.singleNodeId;
      snap.intent['chatgptNodeId'] = settings.chatgptNodeId;
      snap.intent['generalNodeId'] = settings.generalNodeId;
      snap.intent['failoverEnabled'] = settings.failoverEnabled;
    }
    snap.nodes = RunningSnapshot.boundPayload === payload && RunningSnapshot.boundNodes.length > 0 ?
      RunningSnapshot.boundNodes : RunningSnapshot.bindings(payload, NodeStore.loadNodes(context));
    snap.allowedRegions = Array.from(new Set<string>(snap.nodes.map((node: SnapshotNode) => node.region))).sort();
    const parsed = JSON.parse(payload) as Record<string, Object>;
    snap.routeMode = typeof parsed['routeMode'] === 'string' ? parsed['routeMode'] as string : 'rule';
    snap.rulesDigest = RunningSnapshot.rulesDigest(parsed);
    if (!commitAllowed()) return;
    RunningSnapshot.boundPayload = payload; RunningSnapshot.boundNodes = snap.nodes;
    const file = `running-recovery-${snap.id}.huks`;
    await HuksSecretStore.writeLocalRecord(context, file, JSON.stringify(snap), commitAllowed);
    if (!commitAllowed()) return;
    const previous = StatusStore.readText(context, 'running-recovery-pointer.json');
    let retained: string[] = [];
    try {
      const old = JSON.parse(previous) as Record<string, Object>;
      if (Array.isArray(old['retained'])) retained = (old['retained'] as Object[]).filter((v: Object) => typeof v === 'string') as string[];
      if (typeof old['file'] === 'string') retained.push(old['file'] as string);
    } catch (_error) {}
    retained = Array.from(new Set<string>(retained.filter((v: string) => v !== file))).concat([file]).slice(-4);
    const pointer: Record<string, Object> = { 'v': 2, 'id': snap.id, 'file': file, 'retained': retained };
    StatusStore.writeText(context, 'running-recovery-pointer.json', JSON.stringify(pointer));
    // Only old immutable snapshot files, never nodes/settings/subscriptions or the current pointer.
    try { StatusStore.listNames(context).filter((name: string) => /^running-recovery-[A-Za-z0-9_-]{3,160}\.huks$/.test(name) && retained.indexOf(name) < 0)
      .forEach((name: string) => StatusStore.removeFile(context, name)); } catch (_error) { /* retry retention after the next commit */ }
  }
  static async read(context: common.Context, expectedId: string = ''): Promise<RecoverySnapshot> {
    const pointerRaw = StatusStore.readStrictText(context, 'running-recovery-pointer.json');
    let file = RUNNING_SNAPSHOT_FILE;
    if (expectedId.length > 0) {
      if (!/^[A-Za-z0-9_-]{3,160}$/.test(expectedId)) throw new Error('运行快照标识无效');
      file = `running-recovery-${expectedId}.huks`;
    } else if (pointerRaw.length > 0) {
      const pointer = JSON.parse(pointerRaw) as Record<string, Object>;
      if (pointer['v'] !== 2 || typeof pointer['file'] !== 'string' ||
        !/^running-recovery-[A-Za-z0-9_-]{3,160}\.huks$/.test(pointer['file'] as string)) throw new Error('运行快照指针损坏');
      file = pointer['file'] as string;
    }
    if (expectedId.length > 0 && StatusStore.readStrictText(context, file).length === 0) file = RUNNING_SNAPSHOT_FILE;
    const raw = await HuksSecretStore.readLocalRecord(context, file);
    const snap = JSON.parse(raw) as RecoverySnapshot;
    if ((snap.purpose !== 'pangolin-running-recovery-v2' && snap.purpose !== 'pangolin-running-recovery-v1') ||
      typeof snap.id !== 'string' || !/^[A-Za-z0-9_-]{3,160}$/.test(snap.id) || !Array.isArray(snap.nodes) ||
      (expectedId.length > 0 && snap.id !== expectedId)) throw new Error('已提交运行快照缺失或不匹配；不重新选路。');
    if (snap.purpose === 'pangolin-running-recovery-v1') {
      const payload = await HuksSecretStore.readOutbound(context);
      if (digestText(payload) !== snap.payloadDigest) throw new Error('旧版快照引用已变化，未重连。');
      snap.payload = payload;
    }
    if (typeof snap.payload !== 'string' || digestText(snap.payload) !== snap.payloadDigest) throw new Error('运行配置摘要不匹配');
    const authorizedRevision = typeof snap.intent['authorizedRevision'] === 'number' ? snap.intent['authorizedRevision'] as number : 0;
    const revoked = Revocations.keys(context, authorizedRevision);
    if (snap.nodes.some((node: SnapshotNode) => revoked.indexOf(`node:${node.id}`) >= 0 || revoked.indexOf(`source:${node.sourceId}`) >= 0))
      throw new Error('原节点或订阅已被明确删除，不能用旧快照恢复。');
    const current = snap.nodes;
    const p = JSON.parse(snap.payload) as Record<string, Object>;
    const regions = Array.from(new Set<string>(current.map((node: SnapshotNode) => node.region))).sort();
    if (JSON.stringify(regions) !== JSON.stringify(snap.allowedRegions) || snap.routeMode !== (p['routeMode'] ?? 'rule') ||
      snap.rulesDigest !== RunningSnapshot.rulesDigest(p)) {
      throw new Error('运行快照规则或地区约束不一致；不扩大范围。');
    }
    if (p['routeMode'] !== 'direct') await AppRouteCapability.check(parseAppRoutePayload(p['appRouting']).config);
    RunningSnapshot.boundPayload = snap.payload; RunningSnapshot.boundNodes = snap.nodes;
    return snap;
  }
  private static rulesDigest(payload: Record<string, Object>): string {
    const emptyRouting: Record<string, Object> = {};
    const emptyRules: Object[] = [];
    const rules: Record<string, Object> = {};
    rules['userRules'] = payload['userRules'] ?? emptyRules;
    rules['appRouting'] = payload['appRouting'] ?? emptyRouting;
    return digestText(JSON.stringify(rules));
  }
  private static bindings(payload: string, catalog: StoredNode[]): SnapshotNode[] {
    const p = JSON.parse(payload) as Record<string, Object>;
    const ids: string[] = [];
    if (p['channelMode'] === 'single' || p['v'] === 4) {
      ids.push(p['singleNodeId'] as string);
    } else {
      ids.push((p['usNodeId'] ?? p['chatgptNodeId']) as string, (p['ytNodeId'] ?? p['generalNodeId']) as string);
    }
    const app = parseAppRoutePayload(p['appRouting']);
    if (app.config.enabled && p['routeMode'] !== 'direct') {
      app.nodes.forEach((n) => { ids.push(n.nodeId); });
    }
    const nodes: SnapshotNode[] = [];
    ids.forEach((id: string, index: number) => {
      if (typeof id !== 'string' || id.length === 0) throw new Error('旧运行快照缺少稳定节点 ID；不按名称猜测。');
      const matches = catalog.filter((n: StoredNode) => n.id === id);
      if (matches.length !== 1 || matches[0].id.length === 0) throw new Error('原节点缺失或身份冲突；不扩大选路范围。');
      const node = matches[0];
      const entry = new SnapshotNode();
      entry.id = id; entry.sourceId = node.sourceId; entry.region = node.region;
      entry.outboundDigest = digestText(node.outboundJson);
      nodes.push(entry);
    });
    return nodes;
  }
}
