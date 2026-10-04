import { UI_FEEDBACK_FILE } from './UiFeedback';
// 穿山 (GPL-3.0) — 隐私与数据管理（Phase D 新增）。
// 硬约束：本模块的一切删除操作只允许触碰 filesDir 下的已知文件名
// （经 StatusStore.removeFile 拼路径），绝不引用 filesDir 之外的目录。
import { common } from '@kit.AbilityKit';
import { SETTINGS_FILE } from './SettingsStore';
import { EVENT_HEAD_FILE, EVENT_SNAPSHOT_FILE, EVENTS_FILE } from './EventStore';
import { HuksSecretStore } from './HuksSecretStore';
import { NodeStore, StoredNode } from './NodeStore';
import { OUTBOUND_FILE, StatusStore } from './StatusStore';
import { SubscriptionStore } from './SubscriptionStore';
import { USER_RULES_FILE } from './UserRuleStore';
import { JOURNAL_FILES } from './RuntimeJournal';

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
  /** 清理日志：删除事件账本与访问/探测日志，返回删除计数。 */
  static clearLogs(context: common.Context): ClearLogsResult {
    DataManagement.assertDisconnected(context);
    const result = new ClearLogsResult();
    const reportFiles = StatusStore.listNames(context).filter((name: string) =>
      /^(diagnostic-report-|incident-report-)\d+\.json$/.test(name));
    const targets = LOG_FILES.concat(JOURNAL_FILES, ['native-stats.json'], reportFiles);
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
        console.error(`clearLogs ${name} failed ${JSON.stringify(error)}`);
      }
    }
    return result;
  }

  /** 删除全部订阅与节点：nodes.json 写空 v2，subscriptions.json 写空数组。 */
  static async clearNodesAndSubscriptions(context: common.Context): Promise<void> {
    DataManagement.assertDisconnected(context);
    NodeStore.saveNodes(context, []);
    SubscriptionStore.save(context, []);
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
  static async wipeAll(context: common.Context): Promise<void> {
    await DataManagement.clearNodesAndSubscriptions(context);
    DataManagement.clearLogs(context);
    StatusStore.removeFile(context, USER_RULES_FILE);
    StatusStore.removeFile(context, SETTINGS_FILE);
    StatusStore.removeFile(context, OUTBOUND_FILE);
    DataManagement.removeExportCaches(context);
    // Only public, bundled GeoIP/GeoSite databases may remain. All personal
    // diagnostics, stale receipts, caches and future app-owned records are removed.
    const keep: string[] = ['geoip.dat', 'geosite.dat', 'geoip.dat.release', 'geosite.dat.release',
      'geoip.dat.release.lock', 'geosite.dat.release.lock'];
    StatusStore.listNames(context).forEach((name: string) => {
      assertSafeName(name);
      if (keep.indexOf(name) < 0) { StatusStore.removeFile(context, name); }
    });
  }

  private static assertDisconnected(context: common.Context): void {
    const status = StatusStore.readStatus(context);
    if (status.desiredRunning || status.vpnCreated || status.tunFdValid || status.xrayRunning || status.forwarderOk) {
      throw new Error('请先断开连接再清理数据');
    }
  }

  static removeExportCaches(context: common.Context): void {
    const names = StatusStore.listNames(context);
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
