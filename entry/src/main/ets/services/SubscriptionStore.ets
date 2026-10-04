// 穿山 (GPL-3.0) — 订阅源持久化（subscriptions.json v1）。
// 存储结构：[{id,name,url,enabled,autoUpdate,intervalHours,lastUpdateAt,lastError,
//   userinfo:{upload,download,total,expire}|null,nodeCount}]
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { StatusStore } from './StatusStore';

export const SUBSCRIPTIONS_FILE: string = 'subscriptions.json';
export const DEFAULT_INTERVAL_HOURS: number = 24;
export const MIN_INTERVAL_HOURS: number = 2;

export class SubscriptionUserinfo {
  upload: number = 0;
  download: number = 0;
  total: number = 0;
  expire: number = 0;
}

export class SubscriptionRecord {
  id: string = '';
  name: string = '';
  url: string = '';
  enabled: boolean = true;
  autoUpdate: boolean = true;
  intervalHours: number = DEFAULT_INTERVAL_HOURS;
  lastUpdateAt: number = 0;
  lastError: string = '';
  userinfo: SubscriptionUserinfo | null = null;
  nodeCount: number = 0;
}

export class SubscriptionStore {
  static load(context: common.Context): Array<SubscriptionRecord> {
    const raw = StatusStore.readJsonFile(context, SUBSCRIPTIONS_FILE);
    if (raw.length < 2) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as Array<Object>;
      if (!(arr instanceof Array)) {
        return [];
      }
      const list: Array<SubscriptionRecord> = [];
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const record = SubscriptionStore.recordFromJson(item as Record<string, Object>);
        if (record !== null) {
          list.push(record);
        }
      }
      return list;
    } catch (error) {
      console.error(`SubscriptionStore.load parse failed ${JSON.stringify(error)}`);
      return [];
    }
  }

  static save(context: common.Context, subs: Array<SubscriptionRecord>): void {
    const records: Array<Record<string, Object | null>> = [];
    for (let i = 0; i < subs.length; i++) {
      records.push(SubscriptionStore.recordToJson(subs[i]));
    }
    StatusStore.writeJsonAtomic(context, SUBSCRIPTIONS_FILE, JSON.stringify(records, null, 2));
  }

  static add(context: common.Context, name: string, url: string): SubscriptionRecord {
    const subs = SubscriptionStore.load(context);
    for (let i = 0; i < subs.length; i++) {
      if (subs[i].url.trim() === url.trim()) {
        if (!subs[i].enabled) { throw new Error('该订阅已存在且已关闭，请在订阅管理中开启。'); }
        return subs[i];
      }
    }
    const record = new SubscriptionRecord();
    record.id = `sub-${util.generateRandomUUID()}`;
    record.name = name.trim().length > 0 ? name.trim() : SubscriptionStore.deriveNameFromUrl(url);
    record.url = url.trim();
    subs.push(record);
    SubscriptionStore.save(context, subs);
    return record;
  }

  static update(context: common.Context, updated: SubscriptionRecord): boolean {
    const subs = SubscriptionStore.load(context);
    for (let i = 0; i < subs.length; i++) {
      if (subs[i].id === updated.id) {
        updated.intervalHours = SubscriptionStore.clampIntervalHours(updated.intervalHours);
        subs[i] = updated;
        SubscriptionStore.save(context, subs);
        return true;
      }
    }
    return false;
  }

  static remove(context: common.Context, id: string): boolean {
    const subs = SubscriptionStore.load(context);
    const kept: Array<SubscriptionRecord> = [];
    let found = false;
    for (let i = 0; i < subs.length; i++) {
      if (subs[i].id === id) {
        found = true;
      } else {
        kept.push(subs[i]);
      }
    }
    if (found) {
      SubscriptionStore.save(context, kept);
    }
    return found;
  }

  static findById(context: common.Context, id: string): SubscriptionRecord | null {
    const subs = SubscriptionStore.load(context);
    for (let i = 0; i < subs.length; i++) {
      if (subs[i].id === id) {
        return subs[i];
      }
    }
    return null;
  }

  static clampIntervalHours(hours: number): number {
    if (Number.isNaN(hours) || hours < MIN_INTERVAL_HOURS) {
      return hours <= 0 ? DEFAULT_INTERVAL_HOURS : MIN_INTERVAL_HOURS;
    }
    return Math.floor(hours);
  }

  private static deriveNameFromUrl(url: string): string {
    const schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) {
      return '订阅';
    }
    let host = url.substring(schemeEnd + 3);
    const slash = host.indexOf('/');
    if (slash >= 0) {
      host = host.substring(0, slash);
    }
    const at = host.lastIndexOf('@');
    if (at >= 0) {
      host = host.substring(at + 1);
    }
    return host.length > 0 ? host : '订阅';
  }

  private static recordFromJson(item: Record<string, Object>): SubscriptionRecord | null {
    const url = item['url'];
    if (typeof url !== 'string' || url.length === 0) {
      return null;
    }
    const record = new SubscriptionRecord();
    record.id = asString(item['id'], '');
    if (record.id.length === 0) {
      return null;
    }
    record.name = asString(item['name'], '订阅');
    record.url = url;
    record.enabled = asBool(item['enabled'], true);
    record.autoUpdate = asBool(item['autoUpdate'], true);
    record.intervalHours = SubscriptionStore.clampIntervalHours(asNumber(item['intervalHours'], DEFAULT_INTERVAL_HOURS));
    record.lastUpdateAt = asNumber(item['lastUpdateAt'], 0);
    record.lastError = asStringAllowEmpty(item['lastError'], '');
    record.nodeCount = asNumber(item['nodeCount'], 0);
    const userinfo = item['userinfo'];
    if (userinfo !== undefined && userinfo !== null && typeof userinfo === 'object') {
      const info = userinfo as Record<string, Object>;
      const parsed = new SubscriptionUserinfo();
      parsed.upload = asNumberAllowZero(info['upload'], 0);
      parsed.download = asNumberAllowZero(info['download'], 0);
      parsed.total = asNumberAllowZero(info['total'], 0);
      parsed.expire = asNumberAllowZero(info['expire'], 0);
      record.userinfo = parsed;
    }
    return record;
  }

  private static recordToJson(record: SubscriptionRecord): Record<string, Object | null> {
    const item: Record<string, Object | null> = {};
    item['id'] = record.id;
    item['name'] = record.name;
    item['url'] = record.url;
    item['enabled'] = record.enabled;
    item['autoUpdate'] = record.autoUpdate;
    item['intervalHours'] = record.intervalHours;
    item['lastUpdateAt'] = record.lastUpdateAt;
    item['lastError'] = record.lastError;
    item['nodeCount'] = record.nodeCount;
    if (record.userinfo !== null) {
      const info: Record<string, Object> = {};
      info['upload'] = record.userinfo.upload;
      info['download'] = record.userinfo.download;
      info['total'] = record.userinfo.total;
      info['expire'] = record.userinfo.expire;
      item['userinfo'] = info;
    } else {
      item['userinfo'] = null;
    }
    return item;
  }
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function asStringAllowEmpty(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string') {
    return value;
  }
  return fallback;
}

function asNumber(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number' && value > 0) {
    return value;
  }
  return fallback;
}

function asNumberAllowZero(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number' && value >= 0) {
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
