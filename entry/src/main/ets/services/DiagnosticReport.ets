import { redactDiagnosticText } from '../core/UserFacingCopy';
import { UI_FEEDBACK_FILE } from './UiFeedback';
// 穿山 (GPL-3.0) — 诊断报告构建（Phase D 新增）。
// 产品契约：报告必须脱敏——不出现节点密码 / UUID / 订阅链接；端点地址经
// NodeStore.maskEndpointAddress 风格脱敏（域名只保留首段）；事件只带最近 50 条。
import { bundleManager, common } from '@kit.AbilityKit';
import { EventStore } from './EventStore';
import { NodeStore } from './NodeStore';
import { StatusStore } from './StatusStore';
import { RuntimeJournal } from './RuntimeJournal';
import { serializeStatus } from '../net/DataplaneStatus';

export const FALLBACK_APP_VERSION: string = '0.3.47';
export const REPORT_PREFIX: string = 'diagnostic-report-';
export const REPORT_EVENT_LIMIT: number = 50;
export const INCIDENT_PREFIX: string = 'incident-report-';
const MAX_SAVED_REPORTS: number = 5;

// 命中这些键名的值一律替换为 ***（凭据/令牌类字段）。
const SCRUB_KEYS: Array<string> = ['password', 'uuid', 'ssk', 'secret', 'token', 'pwd', 'passphrase', 'cookie', 'authorization'];

export class DiagnosticCheck {
  name: string = '';
  ok: boolean = false;
  skipped: boolean = false;
  verdict: string = '';
  advice: string = '';
}

export class DiagnosticReport {
  /** 读取应用版本名；失败回退硬编码常量。 */
  static async appVersion(): Promise<string> {
    try {
      const info = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        return info.versionName;
      }
    } catch (error) {
      console.error(`appVersion failed ${JSON.stringify(error)}`);
    }
    return FALLBACK_APP_VERSION;
  }

  /** 组装报告对象（已脱敏）。 */
  static async build(context: common.Context, checks: Array<DiagnosticCheck>): Promise<Record<string, Object>> {
    const status = StatusStore.readStatus(context);
    const ledger = EventStore.load(context);
    const events = ledger.seq >= 0 && ledger.events.length > REPORT_EVENT_LIMIT
      ? ledger.events.slice(ledger.events.length - REPORT_EVENT_LIMIT)
      : ledger.events;

    const statusDoc: Record<string, Object> = {};
    statusDoc['phase'] = status.phase;
    statusDoc['honestLabel'] = status.honestLabel;
    statusDoc['lastError'] = status.lastError;
    statusDoc['lastCanary'] = status.lastCanary;
    statusDoc['generation'] = status.generation;
    statusDoc['sessionRevision'] = status.sessionRevision;
    statusDoc['nodeName'] = status.nodeName;
    statusDoc['nodeRegion'] = status.nodeRegion;
    statusDoc['reconnectCount'] = status.reconnectCount;
    statusDoc['tunRxBytes'] = status.tunRxBytes;
    statusDoc['tunTxBytes'] = status.tunTxBytes;
    statusDoc['uploadBytes'] = status.uploadBytes;
    statusDoc['downloadBytes'] = status.downloadBytes;
    statusDoc['at'] = status.at;

    const checkDocs: Array<Record<string, Object>> = [];
    for (let i = 0; i < checks.length; i++) {
      const item: Record<string, Object> = {};
      item['name'] = checks[i].name;
      item['ok'] = checks[i].ok;
      item['skipped'] = checks[i].skipped;
      item['verdict'] = checks[i].verdict;
      item['advice'] = checks[i].advice;
      checkDocs.push(item);
    }

    const scrubbedEvents: Array<Object> = [];
    for (let i = 0; i < events.length; i++) {
      scrubbedEvents.push(DiagnosticReport.scrub(events[i]));
    }

    const doc: Record<string, Object> = {};
    doc['v'] = 2;
    doc['time'] = Date.now();
    doc['appVersion'] = await DiagnosticReport.appVersion();
    doc['sanitized'] = true;
    doc['status'] = DiagnosticReport.scrub(statusDoc);
    doc['checks'] = DiagnosticReport.scrub(checkDocs);
    doc['events'] = scrubbedEvents;
    const eventWindow: Record<string, Object> = { 'generation': ledger.generation, 'sequence': ledger.seq,
      'available': ledger.events.length, 'exported': events.length,
      'note': '此窗口按连接会话重置；跨会话历史请看 runtimeJournal。' };
    doc['eventWindow'] = eventWindow;
    const native = DiagnosticReport.readObject(context, 'native-stats.json');
    const fullStatus = JSON.parse(serializeStatus(status)) as Record<string, Object>;
    doc['runtimeSnapshot'] = RuntimeJournal.snapshot(fullStatus, native);
    const freshness: Record<string, Object> = {
      'statusAt': status.at, 'nativeAt': typeof native['at'] === 'number' ? native['at'] : 0,
      'nativeMatchesSession': native['generation'] === status.generation,
      'statusAgeMs': status.at > 0 ? Math.max(0, Date.now() - status.at) : -1
    };
    doc['snapshotFreshness'] = freshness;
    doc['runtimeJournal'] = RuntimeJournal.read(context);
    const applied = DiagnosticReport.readObject(context, 'applied-policy.json');
    const policy: Record<string, Object> = {};
    const modes = ['single', 'dual', 'rule', 'global', 'direct'];
    ['channelMode', 'routeMode'].forEach((key: string) => {
      if (typeof applied[key] === 'string' && modes.indexOf(applied[key] as string) >= 0) { policy[key] = applied[key]; }
    });
    policy['matchesSession'] = applied['generation'] === status.generation &&
      applied['payloadDigest'] === status.payloadDigest;
    policy['failedOver'] = applied['failedOver'] === true;
    policy['at'] = typeof applied['at'] === 'number' ? applied['at'] : 0;
    doc['appliedPolicy'] = policy;
    doc['limitations'] = [
      '仅记录穿山甲自身可见的运行元数据；不是微信或其他应用的内部日志。',
      '不记录聊天、请求正文、访问域名/IP、账号、密码或订阅地址；不解密流量。',
      'App 分流关闭时没有逐 App 结果；聚合正常不能证明某个 App 正常，也不能排除某条连接失败。',
      '滚动记录最多保留 48 小时且受 4 MiB 容量限制，满后提前淘汰；休眠或进程未运行时可能有时间缺口。',
      '日志只覆盖功能启用后的实际记录，无法补回此前故障。'
    ];
    const uiFeedback = StatusStore.readText(context, UI_FEEDBACK_FILE);
    if (uiFeedback.length > 0) {
      try { doc['uiFeedback'] = DiagnosticReport.scrub(JSON.parse(uiFeedback) as Object); } catch (_error) {}
    }
    return doc;
  }

  /** 写入 filesDir/diagnostic-report-<ts>.json，返回文件路径。 */
  static write(context: common.Context, doc: Record<string, Object>, incident: boolean = false): string {
    const name = `${incident ? INCIDENT_PREFIX : REPORT_PREFIX}${Date.now()}.json`;
    StatusStore.writeText(context, name, JSON.stringify(doc, null, 2));
    // Reports are independent snapshots, so later reconnects cannot replace their history.
    const names = DiagnosticReport.reportNames(context, incident ? INCIDENT_PREFIX : REPORT_PREFIX);
    for (let i = MAX_SAVED_REPORTS; i < names.length; i++) {
      try { StatusStore.removeFile(context, names[i]); } catch (_error) { /* Saving succeeded; cleanup is best-effort. */ }
    }
    return `${context.filesDir}/${name}`;
  }

  static latestIncident(context: common.Context): string {
    const names = DiagnosticReport.reportNames(context, INCIDENT_PREFIX);
    return names.length > 0 ? names[0] : '';
  }

  private static reportNames(context: common.Context, prefix: string): string[] {
    return StatusStore.listNames(context).filter((name: string) =>
      name.startsWith(prefix) && /^\d+\.json$/.test(name.substring(prefix.length))).sort().reverse();
  }

  private static readObject(context: common.Context, name: string): Record<string, Object> {
    try {
      const parsed = JSON.parse(StatusStore.readText(context, name)) as Object;
      return parsed !== null && typeof parsed === 'object' && !(parsed instanceof Array)
        ? parsed as Record<string, Object> : {};
    }
    catch (_error) { return {}; }
  }

  /**
   * 递归脱敏：凭据键 → ***；URL 只留 scheme + 脱敏主机名；域名/IP 形态的字符串
   * 经 NodeStore.maskEndpointAddress 处理。数组与对象逐层深入。
   */
  static scrub(value: Object, key: string = ''): Object {
    if (DiagnosticReport.isScrubKey(key)) {
      return '***';
    }
    if (typeof value === 'string') {
      return DiagnosticReport.scrubString(value);
    }
    if (value instanceof Array) {
      const out: Array<Object> = [];
      for (let i = 0; i < value.length; i++) {
        out.push(DiagnosticReport.scrub(value[i] as Object));
      }
      return out;
    }
    if (value !== null && typeof value === 'object') {
      const src = value as Record<string, Object>;
      const out: Record<string, Object> = {};
      const keys = Object.keys(src);
      for (let i = 0; i < keys.length; i++) {
        out[keys[i]] = DiagnosticReport.scrub(src[keys[i]], keys[i]);
      }
      return out;
    }
    return value;
  }

  private static isScrubKey(key: string): boolean {
    const lower = key.toLowerCase();
    for (let i = 0; i < SCRUB_KEYS.length; i++) {
      if (lower.indexOf(SCRUB_KEYS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static scrubString(rawText: string): string {
    const text = redactDiagnosticText(rawText);
    const schemeEnd = text.indexOf('://');
    if (schemeEnd > 0 && schemeEnd < 10) {
      // URL：保留 scheme，主机名脱敏，路径丢弃。
      const scheme = text.substring(0, schemeEnd);
      let host = text.substring(schemeEnd + 3);
      const at = host.lastIndexOf('@');
      if (at >= 0) {
        host = host.substring(at + 1);
      }
      const slash = host.indexOf('/');
      if (slash >= 0) {
        host = host.substring(0, slash);
      }
      const colon = host.indexOf(':');
      const port = colon >= 0 ? host.substring(colon) : '';
      const bare = colon >= 0 ? host.substring(0, colon) : host;
      return `${scheme}://${NodeStore.maskEndpointAddress(bare)}${port}/…`;
    }
    if (DiagnosticReport.looksLikeHost(text)) {
      return NodeStore.maskEndpointAddress(text);
    }
    // Legacy event/error messages can contain addresses inside prose, not just
    // standalone hosts. Never let those bypass the diagnostic export boundary.
    return text
      .replace(/\[[0-9a-fA-F:.%]+\](?::\d+)?/g, '[address]')
      .replace(/(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F]{0,4}(?:%[A-Za-z0-9_-]+)?/g, '[address]')
      .replace(/\b(?:[A-Za-z0-9_-]+\.)+[A-Za-z0-9_-]+(?::\d+)?\b/g, '[host]');
  }

  /** 形如 a.b / a.b.c / 1.2.3.4 / 2001:db8::1 的裸主机名。 */
  private static looksLikeHost(text: string): boolean {
    if (text.length < 4 || text.length > 253 || text.indexOf(' ') >= 0) {
      return false;
    }
    if (text.indexOf(':') >= 0) {
      // IPv6 形态（含端口的不算裸主机名，交给 URL 分支）。
      return /^[0-9a-fA-F:]+$/.test(text) && text.indexOf('::') >= 0;
    }
    return /^[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)+$/.test(text);
  }
}
