// 穿山 (GPL-3.0) — 用户设置（settings.json 的唯一读写方，Phase C 新增）。
// 向后兼容契约：settings.json 不存在或损坏时 load() 返回全默认值，即
// routeMode='rule' / selectionMode='auto' / failoverEnabled=true，行为与
// Phase C 之前完全一致（自动分流选路 + 固定规则链 + 故障切换开启）。
// 落盘走 StatusStore.readJsonFile/writeJsonAtomic（recoverCanonical 自愈 +
// 原子替换），与 nodes.json 同级可靠。
import { common } from '@kit.AbilityKit';
import { StatusStore } from './StatusStore';

export const SETTINGS_FILE: string = 'settings.json';
export const SETTINGS_SCHEMA_VERSION: number = 1;

// settings.json v1 顶层结构：
// {"v":1,"routeMode":"rule|global|direct","selectionMode":"auto|manual",
//  "manualNodeId":"","failoverEnabled":true,"failoverGroup":"",
//  "lastGoodNodeId":"","autoConnectOnLaunch":false,"autoUpdateSubscriptions":true}
export const ROUTE_RULE: string = 'rule';
export const ROUTE_GLOBAL: string = 'global';
export const ROUTE_DIRECT: string = 'direct';
export const SELECT_AUTO: string = 'auto';
export const SELECT_MANUAL: string = 'manual';
// Phase D：诊断事件账本保留条数（dataplane-event-snapshot.json 窗口）。
export const EVENT_KEEP_DEFAULT: number = 400;
export const EVENT_KEEP_OPTIONS: Array<number> = [100, 400, 1000];

export class AppSettings {
  channelMode: string = 'single';
  companionEnabled: boolean = true;
  singleNodeId: string = '';
  // 连接模式：rule=按规则分流（默认）/ global=全局代理 / direct=全部直连。
  routeMode: string = ROUTE_RULE;
  // 节点选择：auto=按延迟自动挑选（默认）/ manual=固定节点。
  selectionMode: string = SELECT_AUTO;
  // 固定节点 id（NodeStore StoredNode.id）；'' = 未固定。
  manualNodeId: string = '';
  // Independent role selections. Empty means automatic; legacy manual mode initially pins both.
  chatgptNodeId: string = '';
  generalNodeId: string = '';
  // 节点失败时是否自动切换备用节点（新安装默认关闭；已有明确选择保留）。
  failoverEnabled: boolean = false;
  // 备用节点限定分组；'' = 任意分组。
  failoverGroup: string = '';
  // 最近一次成功连接使用的节点 id（分流时记美国侧节点），供固定模式预选。
  lastGoodNodeId: string = '';
  // 启动即连接（Phase D 才接线到 EntryAbility，Phase C 只持久化）。
  autoConnectOnLaunch: boolean = false;
  // 自动更新订阅（Phase D 才接线到 WorkScheduler，Phase C 只持久化）。
  autoUpdateSubscriptions: boolean = true;
  // 诊断事件账本保留条数（Phase D 新增；缺省 400，与 EventStore 既有上限一致）。
  eventKeepCount: number = EVENT_KEEP_DEFAULT;
}

export class SettingsStore {
  static load(context: common.Context): AppSettings {
    const settings = new AppSettings();
    const raw = StatusStore.readJsonFile(context, SETTINGS_FILE);
    if (raw.length < 2) {
      return settings;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object' ||
        (parsed['v'] !== undefined && parsed['v'] !== SETTINGS_SCHEMA_VERSION)) throw new Error('unsupported settings schema');
      settings.routeMode = normalizeRouteMode(parsed['routeMode']);
      settings.selectionMode = normalizeSelectionMode(parsed['selectionMode']);
      settings.manualNodeId = asString(parsed['manualNodeId'], '');
      settings.channelMode = parsed['channelMode'] === 'dual' ? 'dual' : 'single';
      settings.companionEnabled = parsed['companionEnabled'] !== false;
      settings.singleNodeId = typeof parsed['singleNodeId'] === 'string' ? parsed['singleNodeId'] as string : settings.manualNodeId;
      const legacyPin = settings.selectionMode === SELECT_MANUAL ? settings.manualNodeId : '';
      settings.chatgptNodeId = typeof parsed['chatgptNodeId'] === 'string' ? parsed['chatgptNodeId'] as string : legacyPin;
      settings.generalNodeId = typeof parsed['generalNodeId'] === 'string' ? parsed['generalNodeId'] as string : legacyPin;
      settings.failoverEnabled = asBool(parsed['failoverEnabled'], false);
      settings.failoverGroup = asString(parsed['failoverGroup'], '');
      settings.lastGoodNodeId = asString(parsed['lastGoodNodeId'], '');
      settings.autoConnectOnLaunch = asBool(parsed['autoConnectOnLaunch'], false);
      settings.autoUpdateSubscriptions = asBool(parsed['autoUpdateSubscriptions'], true);
      settings.eventKeepCount = asEventKeep(parsed['eventKeepCount']);
      return settings;
    } catch (error) {
      throw new Error('设置无法读取，未恢复默认或覆盖原设置。');
    }
  }

  static save(context: common.Context, settings: AppSettings): void {
    const doc: Record<string, Object> = {};
    doc['v'] = SETTINGS_SCHEMA_VERSION;
    doc['channelMode'] = settings.channelMode === 'dual' ? 'dual' : 'single';
    doc['companionEnabled'] = settings.companionEnabled;
    doc['singleNodeId'] = settings.singleNodeId;
    doc['routeMode'] = normalizeRouteMode(settings.routeMode);
    doc['selectionMode'] = normalizeSelectionMode(settings.selectionMode);
    doc['manualNodeId'] = settings.manualNodeId;
    doc['chatgptNodeId'] = settings.chatgptNodeId;
    doc['generalNodeId'] = settings.generalNodeId;
    doc['failoverEnabled'] = settings.failoverEnabled;
    doc['failoverGroup'] = settings.failoverGroup;
    doc['lastGoodNodeId'] = settings.lastGoodNodeId;
    doc['autoConnectOnLaunch'] = settings.autoConnectOnLaunch;
    doc['autoUpdateSubscriptions'] = settings.autoUpdateSubscriptions;
    doc['eventKeepCount'] = asEventKeep(settings.eventKeepCount);
    StatusStore.writeJsonAtomic(context, SETTINGS_FILE, JSON.stringify(doc, null, 2));
  }

  /** 改单个字段的便捷入口：读-改-写。 */
  static update(context: common.Context, mutate: (settings: AppSettings) => void): AppSettings {
    const settings = SettingsStore.load(context);
    mutate(settings);
    SettingsStore.save(context, settings);
    return settings;
  }

  /** 这些字段变更后必须重连才会生效（路由/选路/故障切换都只在启动时读取）。 */
  static requiresReconnect(before: AppSettings, after: AppSettings): boolean {
    return before.routeMode !== after.routeMode ||
      before.channelMode !== after.channelMode || before.singleNodeId !== after.singleNodeId ||
      before.selectionMode !== after.selectionMode ||
      before.manualNodeId !== after.manualNodeId ||
      before.chatgptNodeId !== after.chatgptNodeId ||
      before.generalNodeId !== after.generalNodeId ||
      before.failoverEnabled !== after.failoverEnabled ||
      before.failoverGroup !== after.failoverGroup;
  }
}

function normalizeRouteMode(value: Object | undefined): string {
  if (value === ROUTE_GLOBAL || value === ROUTE_DIRECT) {
    return value as string;
  }
  return ROUTE_RULE;
}

function normalizeSelectionMode(value: Object | undefined): string {
  if (value === SELECT_MANUAL) {
    return SELECT_MANUAL;
  }
  return SELECT_AUTO;
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function asBool(value: Object | undefined, fallback: boolean): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  return fallback;
}

/** eventKeepCount 只接受 EVENT_KEEP_OPTIONS 里的档位；其余一律回退默认 400。 */
function asEventKeep(value: Object | undefined): number {
  if (typeof value === 'number') {
    for (let i = 0; i < EVENT_KEEP_OPTIONS.length; i++) {
      if (EVENT_KEEP_OPTIONS[i] === value) {
        return value;
      }
    }
  }
  return EVENT_KEEP_DEFAULT;
}
