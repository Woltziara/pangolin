/** Per-application route records.  This module intentionally has no system APIs. */
export class AppRoute {
  id: string = '';
  bundleName: string = '';
  label: string = '';
  nodeId: string = '';
  enabled: boolean = true;
  createdAt: number = 0;
  updatedAt: number = 0;
}

export class AppRoutingConfig {
  version: number = 1;
  enabled: boolean = false;
  rules: AppRoute[] = [];
}

/** A locally observed app. It deliberately contains no network destination data. */
export class ObservedApp {
  bundleName: string = '';
  label: string = '';
  uid: number = -1;
  lastSeenAt: number = 0;
}

const MAX_RULES: number = 64;
const MAX_ID_LENGTH: number = 160;
const MAX_LABEL_LENGTH: number = 160;
const BUNDLE_NAME: RegExp = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/;
const SAFE_ID: RegExp = /^[A-Za-z0-9._:-]+$/;

function objectOf(value: Object | undefined): Record<string, Object> {
  if (value === null || typeof value !== 'object' || value instanceof Array) {
    throw new Error('App 路由配置必须是对象');
  }
  return value as Record<string, Object>;
}

function requiredString(record: Record<string, Object>, key: string, maximum: number, pattern?: RegExp): string {
  const value = record[key];
  if (typeof value !== 'string' || value.length === 0 || value.length > maximum || (pattern !== undefined && !pattern.test(value))) {
    throw new Error(`App 路由字段无效：${key}`);
  }
  return value;
}

function requiredBoolean(record: Record<string, Object>, key: string): boolean {
  if (typeof record[key] !== 'boolean') {
    throw new Error(`App 路由字段无效：${key}`);
  }
  return record[key] as boolean;
}

function requiredTime(record: Record<string, Object>, key: string): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`App 路由时间字段无效：${key}`);
  }
  return value;
}

/**
 * Decode the on-disk contract strictly.  A malformed rule is never silently
 * discarded: accepting a partial policy could unexpectedly send an app over
 * the default route.
 */
export function normalizeAppRoutingConfig(raw: string): AppRoutingConfig {
  let decoded: Object;
  try {
    decoded = JSON.parse(raw) as Object;
  } catch (_error) {
    throw new Error('App 路由配置不是有效 JSON');
  }
  const doc = objectOf(decoded);
  if (doc['version'] !== 1 || typeof doc['enabled'] !== 'boolean' || !(doc['rules'] instanceof Array)) {
    throw new Error('App 路由配置版本或结构无效');
  }
  const source = doc['rules'] as Array<Object>;
  if (source.length > MAX_RULES) {
    throw new Error(`App 路由最多只能保存 ${MAX_RULES} 条`);
  }
  const ids = new Set<string>();
  const bundles = new Set<string>();
  const rules: AppRoute[] = [];
  for (let i = 0; i < source.length; i++) {
    const item = objectOf(source[i]);
    const route = new AppRoute();
    route.id = requiredString(item, 'id', MAX_ID_LENGTH, SAFE_ID);
    route.bundleName = requiredString(item, 'bundleName', 256, BUNDLE_NAME);
    route.label = requiredString(item, 'label', MAX_LABEL_LENGTH);
    route.nodeId = requiredString(item, 'nodeId', MAX_ID_LENGTH, SAFE_ID);
    route.enabled = requiredBoolean(item, 'enabled');
    route.createdAt = requiredTime(item, 'createdAt');
    route.updatedAt = requiredTime(item, 'updatedAt');
    if (route.updatedAt < route.createdAt || ids.has(route.id) || bundles.has(route.bundleName)) {
      throw new Error('App 路由存在重复或时间顺序无效');
    }
    ids.add(route.id);
    bundles.add(route.bundleName);
    rules.push(route);
  }
  rules.sort((a: AppRoute, b: AppRoute): number => a.bundleName.localeCompare(b.bundleName) || a.id.localeCompare(b.id));
  const config = new AppRoutingConfig();
  config.enabled = doc['enabled'] as boolean;
  config.rules = rules;
  return config;
}

/** A stable, policy-only fingerprint; cosmetic labels and edit timestamps do not affect a running route. */
export function appRoutingFingerprint(config: AppRoutingConfig): string {
  const normalized = normalizeAppRoutingConfig(JSON.stringify(config));
  const routes: Array<Record<string, Object>> = [];
  for (let i = 0; i < normalized.rules.length; i++) {
    const route = normalized.rules[i];
    const item: Record<string, Object> = {};
    item['bundleName'] = route.bundleName;
    item['nodeId'] = route.nodeId;
    item['enabled'] = route.enabled;
    routes.push(item);
  }
  return JSON.stringify({ version: normalized.version, enabled: normalized.enabled, rules: routes });
}
