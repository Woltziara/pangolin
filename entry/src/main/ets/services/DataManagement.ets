import { AppLog } from './AppLog';
import { LIFECYCLE_GATE } from './LifecycleGate';
import { CONTROL_FILE, OWNER_TERMINAL_FILE, controlBlocksStart, terminalProven } from '../net/OwnerTerminal';
import { PLATFORM_OPERATIONS_FILE } from './PlatformOperations';
import { UI_FEEDBACK_FILE } from './UiFeedback';
// 穿山 (GPL-3.0) — 隐私与数据管理（Phase D 新增）。
// 硬约束：本模块的一切删除操作只允许触碰 filesDir 下的已知文件名
// （经 StatusStore.removeFile 拼路径），绝不引用 filesDir 之外的目录。
import { common } from '@kit.AbilityKit';
import { SETTINGS_FILE, SettingsStore } from './SettingsStore';
import { Revocations } from './Revocations';
import { EVENT_HEAD_FILE, EVENT_SNAPSHOT_FILE, EVENTS_FILE } from './EventStore';
import { HuksSecretStore } from './HuksSecretStore';
import { NodeStore, StoredNode } from './NodeStore';
import { OUTBOUND_FILE, StatusStore } from './StatusStore';
import { SubscriptionStore } from './SubscriptionStore';
import { USER_RULES_FILE } from './UserRuleStore';
import { JOURNAL_FILES } from './RuntimeJournal';
import { ERROR_JOURNAL_FILES } from './ErrorJournal';

// 清理日志覆盖的 filesDir 文件名：事件账本 + 内核访问日志 + 自证探测记录。
// 全部是纯文件名（不含目录分隔符），由 assertSafeName 兜底。
const LOG_FILES: Array<string> = [
  UI_FEEDBACK_FILE,
  EVENTS_FILE,
  EVENT_HEAD_FILE,
  EVENT_SNAPSHOT_FILE,
  'xray-access.log',
  'xray-access-pub.log',
  'xray-timing.log',
  'probe-fetch.json',
  'probe-loop-error.json',
  'subscription-dns-check.json',
  'latency-http.json',
  'latency-socks.json',
  'latency-native-socks.json',
  'latency-outbound-timing.json',
  'latency-node-endpoint.json'
];

const EXPORT_PREFIX: string = 'tongdao-config-export-';

function assertSafeName(name: string): void {
  if (name.length === 0 || name.indexOf('/') >= 0 || name.indexOf('..') >= 0 ||
    name.indexOf('\\') >= 0) {
    throw new Error(`非法文件名，拒绝触碰 filesDir 之外的路径：${name}`);
  }
}

export class ClearLogsResult {
  removed: number = 0;
  failed: number = 0;
}

export class DataManagement {
  static pendingSubscriptionRemoval(context: common.Context): string {
    const raw = StatusStore.readStrictText(context, CONTROL_FILE);
    if (raw.length === 0) return '';
    const row = JSON.parse(raw) as Record<string, Object>;
    const action = row['action'];
    if (row['kind'] === 'maintenance' && row['state'] === 'pending' && typeof action === 'string' &&
      /^subscription:sub-[A-Za-z0-9-]+$/.test(action)) return action.substring(13);
    return '';
  }

  /** Delete one source and its own nodes; retain a resumable plan before the first data write. */
  static removeSubscriptionAndNodes(context: common.Context, id: string): number {
    if (!/^sub-[A-Za-z0-9-]+$/.test(id)) throw new Error('订阅标识无效，未删除。');
    const release = DataManagement.enter(context, `subscription:${id}`);
    let ok = false;
    try {
      NodeStore.loadNodes(context); SubscriptionStore.load(context); SettingsStore.load(context);
      const catalog = JSON.parse(StatusStore.readStrictText(context, 'nodes.json') || '{"v":2,"nodes":[]}') as Record<string, Object>;
      const rows = catalog['nodes'] as Record<string, Object>[];
      const subs = JSON.parse(StatusStore.readStrictText(context, 'subscriptions.json') || '[]') as Record<string, Object>[];
      const settingsRaw = StatusStore.readStrictText(context, SETTINGS_FILE);
      const settings = JSON.parse(settingsRaw || '{}') as Record<string, Object>;
      const planFile = 'subscription-removal.json';
      const priorRaw = StatusStore.readStrictText(context, planFile);
      const prior = JSON.parse(priorRaw || '{}') as Record<string, Object>;
      let ids: string[] = rows.filter((row: Record<string, Object>) => row['sourceId'] === id)
        .map((row: Record<string, Object>) => row['id'] as string);
      if (prior['completed'] === false) {
        if (prior['sourceId'] !== id || !Array.isArray(prior['nodeIds']) ||
          !(prior['nodeIds'] as Object[]).every((value: Object) => typeof value === 'string'))
          throw new Error('上次订阅删除尚未完成，请先继续原操作。');
        ids = Array.from(new Set<string>(ids.concat(prior['nodeIds'] as string[])));
      }
      const plan: Record<string, Object> = { 'sourceId': id, 'nodeIds': ids, 'completed': false };
      StatusStore.writeText(context, planFile, JSON.stringify(plan));
      Revocations.revoke(context, [`source:${id}`].concat(ids.map((nodeId: string) => `node:${nodeId}`)));
      const kept = rows.filter((row: Record<string, Object>) => row['sourceId'] !== id);
      catalog['nodes'] = kept;
      StatusStore.writeText(context, 'nodes.json', JSON.stringify(catalog, null, 2));
      const keptIds = new Set<string>(kept.map((row: Record<string, Object>) => row['id'] as string));
      const removedIds = new Set<string>(ids);
      let changed = false;
      ['singleNodeId', 'manualNodeId', 'chatgptNodeId', 'generalNodeId', 'lastGoodNodeId'].forEach((key: string) => {
        const value = settings[key];
        if (typeof value === 'string' && removedIds.has(value)) {
          const single = settings['singleNodeId'];
          settings[key] = key === 'manualNodeId' && typeof single === 'string' && keptIds.has(single) ? single : '';
          changed = true;
        }
      });
      if (changed) StatusStore.writeText(context, SETTINGS_FILE, JSON.stringify(settings, null, 2));
      StatusStore.writeText(context, 'subscriptions.json', JSON.stringify(subs.filter((row: Record<string, Object>) => row['id'] !== id), null, 2));
      plan['completed'] = true;
      StatusStore.writeText(context, planFile, JSON.stringify(plan));
      ok = true;
      return ids.length;
    } finally { release(ok); }
  }

  /** 清理日志：删除事件账本与访问/探测日志，返回删除计数。 */
  private static clearLogsUnchecked(context: common.Context): ClearLogsResult {
    const result = new ClearLogsResult();
    const reportFiles = StatusStore.listNamesStrict(context).filter((name: string) =>
      /^(diagnostic-report-|incident-report-)\d+\.json$/.test(name));
    const targets = LOG_FILES.concat(JOURNAL_FILES, ERROR_JOURNAL_FILES, ['native-stats.json'], reportFiles);
    for (let i = 0; i < targets.length; i++) {
      const name = targets[i];
      assertSafeName(name);
      const path = `${context.filesDir}/${name}`;
      try {
        if (StatusStore.destExists(path)) {
          StatusStore.removeFile(context, name);
          result.removed += 1;
        }
      } catch (error) {
        result.failed += 1;
        AppLog.error(0x3200, 'DataManagement', '%{public}s', `clearLogs ${name} failed ${JSON.stringify(error)}`);
      }
    }
    return result;
  }

  /** 删除全部订阅与节点：nodes.json 写空 v2，subscriptions.json 写空数组。 */
  private static async clearNodesUnchecked(context: common.Context): Promise<void> {
    // This method holds the cross-process data lease. Do not reacquire it via normal writers.
    StatusStore.writeText(context, 'nodes.json', '{"v":2,"nodes":[]}');
    StatusStore.writeText(context, 'subscriptions.json', '[]');
    // 运行时选型痕迹一并清掉，避免悬空引用。
    StatusStore.removeFile(context, OUTBOUND_FILE);
    await HuksSecretStore.removeProtected(context);
    const files: string[] = ['node-meta.json', 'applied-policy.json', 'xray-config.json', 'node-latency-test.json'];
    files.forEach((name: string) => { StatusStore.removeFile(context, name); });
  }

  /**
   * 清空全部数据：节点 / 订阅 / 分流规则 / 设置 / 日志 / 缓存的节点凭据
   * （HUKS 信封与密钥）。调用方必须保证 VPN 已断开。
   */
  private static async wipeAllUnchecked(context: common.Context): Promise<void> {
    await DataManagement.clearNodesUnchecked(context);
    DataManagement.clearLogsUnchecked(context);
    StatusStore.removeFile(context, USER_RULES_FILE);
    StatusStore.removeFile(context, SETTINGS_FILE);
    StatusStore.removeFile(context, OUTBOUND_FILE);
    DataManagement.removeExportCaches(context);
    // Only public, bundled GeoIP/GeoSite databases may remain. All personal
    // diagnostics, stale receipts, caches and future app-owned records are removed.
    const keep: string[] = ['geoip.dat', 'geosite.dat', 'geoip.dat.release', 'geosite.dat.release',
      'geoip.dat.release.lock', 'geosite.dat.release.lock', CONTROL_FILE, PLATFORM_OPERATIONS_FILE,
      'user-data-transaction.lock'];
    StatusStore.listNamesStrict(context).forEach((name: string) => {
      assertSafeName(name);
      if (!name.endsWith('.lock') && keep.indexOf(name) < 0) { StatusStore.removeFile(context, name); }
    });
  }

  private static enter(context: common.Context, action: string): (ok: boolean) => void {
    const releaseGate = LIFECYCLE_GATE.beginMaintenance();
    let lease = 0;
    try {
      lease = StatusStore.acquireUserDataLease(context);
      const status = StatusStore.readStatus(context);
      const before = StatusStore.readStrictText(context, CONTROL_FILE);
      const original = StatusStore.readOwnerStatus(context);
      const previous = JSON.parse(before || '{}') as Record<string, Object>;
      const resuming = previous['kind'] === 'maintenance' && previous['state'] === 'pending' && previous['action'] === action;
      if (previous['kind'] === 'maintenance' && previous['state'] === 'pending' && !resuming) throw new Error('请再次执行先前的清理操作，不得扩大未完成清理范围。');
      const stopped = status.operationState === 'reboot-confirmed' || original.phase === 'STOPPED' && terminalProven(StatusStore.readStrictText(context, OWNER_TERMINAL_FILE),
        original.generation, 0, Date.now(), original.ownerInstance);
      const pristine = original.phase === 'IDLE' && original.at === 0 && (before.length === 0 ||
        previous['kind'] === 'maintenance' && previous['action'] === 'all' && previous['state'] === 'confirmed' && previous['outcome'] === 'completed');
      if ((!stopped && !pristine && !resuming) || status.desiredRunning || status.vpnCreated || status.tunFdValid ||
        status.xrayRunning || status.forwarderOk || status.cleanupPending || !resuming && controlBlocksStart(before))
        throw new Error('请回首页点“恢复连接”，确认断开后再清理数据。');
      const opRaw = StatusStore.readStrictText(context, PLATFORM_OPERATIONS_FILE);
      if (opRaw.length > 0) {
        const op = JSON.parse(opRaw) as Record<string, Object>;
        if (op['schema'] !== 2 || !Array.isArray(op['operations']) ||
          (op['operations'] as Record<string, Object>[]).some((row) => row['state'] === 'pending'))
          throw new Error('系统操作尚未结束，未清理数据。');
      }
      const marker: Record<string, Object> = { 'schema': 2, 'kind': 'maintenance', 'action': action,
        'state': 'pending', 'generation': original.generation, 'requestedAt': Date.now() };
      StatusStore.writeText(context, CONTROL_FILE, JSON.stringify(marker));
      return (ok: boolean): void => {
        try {
          marker['state'] = ok ? 'confirmed' : 'pending';
          marker['outcome'] = ok ? 'completed' : 'interrupted';
          StatusStore.writeText(context, CONTROL_FILE, JSON.stringify(marker));
        } finally { StatusStore.releaseUserDataLease(lease); releaseGate(); }
      };
    } catch (error) {
      if (lease > 0) StatusStore.releaseUserDataLease(lease);
      releaseGate(); throw error as Error;
    }
  }
  static clearLogs(context: common.Context): ClearLogsResult {
    const release = DataManagement.enter(context, 'logs');
    let ok = false;
    try { const result = DataManagement.clearLogsUnchecked(context); ok = true; return result; } finally { release(ok); }
  }
  static async clearNodesAndSubscriptions(context: common.Context): Promise<void> {
    const release = DataManagement.enter(context, 'nodes');
    let ok = false;
    try { await DataManagement.clearNodesUnchecked(context); ok = true; } finally { release(ok); }
  }
  static async wipeAll(context: common.Context): Promise<void> {
    const release = DataManagement.enter(context, 'all');
    let ok = false;
    try { await DataManagement.wipeAllUnchecked(context); ok = true; } finally { release(ok); }
  }

  static removeExportCaches(context: common.Context): void {
    const names = StatusStore.listNamesStrict(context);
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (name.indexOf(EXPORT_PREFIX) === 0 && name.indexOf('/') < 0) {
        StatusStore.removeFile(context, name);
      }
    }
  }

  /**
   * 导出配置（含凭据）：nodes.json + subscriptions.json + user-rules.json
   * 合并成一个 JSON 落到 filesDir，返回文件路径。调用方负责事前的中文警告弹窗；
   * 本函数不做脱敏。标准 outbounds 节点列表可重新导入；原始元数据同时保留。
   */
  static exportConfig(context: common.Context): string {
    const doc: Record<string, Object> = {};
    doc['v'] = 1;
    doc['exportedAt'] = Date.now();
    doc['warning'] = '本文件包含节点密码和订阅链接，请勿分享给他人';
    doc['restoreKind'] = 'partial-share';
    doc['restoreNote'] = '本导出可重新导入节点和订阅，不是完整跨设备备份。收藏、固定选择、加密运行副本和会话状态不会按此文件完整恢复。';
    doc['nodes'] = DataManagement.parseOrRaw(StatusStore.readJsonFile(context, 'nodes.json'));
    doc['subscriptions'] = DataManagement.parseOrRaw(StatusStore.readJsonFile(context, 'subscriptions.json'));
    doc['userRules'] = DataManagement.parseOrRaw(StatusStore.readJsonFile(context, USER_RULES_FILE));
    doc['settings'] = DataManagement.parseOrRaw(StatusStore.readJsonFile(context, SETTINGS_FILE));
    doc['outbounds'] = NodeStore.loadNodes(context).map((node: StoredNode): Record<string, Object> => {
      const outbound = JSON.parse(node.outboundJson) as Record<string, Object>;
      outbound['tag'] = NodeStore.displayName(node);
      return outbound;
    });
    const name = `${EXPORT_PREFIX}${Date.now()}.json`;
    assertSafeName(name);
    StatusStore.writeText(context, name, JSON.stringify(doc, null, 2));
    return `${context.filesDir}/${name}`;
  }

  private static parseOrRaw(raw: string): Object {
    if (raw.length < 2) {
      return '';
    }
    try {
      return JSON.parse(raw) as Object;
    } catch (error) {
      return raw;
    }
  }
}
