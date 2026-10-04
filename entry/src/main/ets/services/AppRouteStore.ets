import { common } from '@kit.AbilityKit';
import { AppRoute, AppRoutingConfig, normalizeAppRoutingConfig } from '../core/AppRouteModel';
import { StatusStore } from './StatusStore';

export const APP_ROUTES_FILE: string = 'app-routes.json';

/** The only persistence owner for App-routing policy. Credentials never belong here. */
export class AppRouteStore {
  static load(context: common.Context): AppRoutingConfig {
    const raw = StatusStore.readJsonFile(context, APP_ROUTES_FILE);
    if (raw.length === 0) {
      if (StatusStore.destExists(`${context.filesDir}/${APP_ROUTES_FILE}`)) {
        throw new Error('App 指定节点配置损坏，未加载部分规则；请检查后重新保存。');
      }
      return new AppRoutingConfig();
    }
    try {
      return normalizeAppRoutingConfig(raw);
    } catch (error) {
      console.error(`AppRouteStore.load invalid config ${JSON.stringify(error)}`);
      throw new Error('App 指定节点配置损坏，未加载部分规则；请检查后重新保存。');
    }
  }

  static save(context: common.Context, config: AppRoutingConfig): void {
    const normalized = normalizeAppRoutingConfig(JSON.stringify(config));
    StatusStore.writeJsonAtomic(context, APP_ROUTES_FILE, JSON.stringify(normalized, null, 2));
  }

  static setEnabled(context: common.Context, enabled: boolean): void {
    const config = AppRouteStore.load(context);
    config.enabled = enabled;
    AppRouteStore.save(context, config);
  }

  /** Insert or replace by id (and reject a conflicting second rule for one bundle). */
  static upsert(context: common.Context, route: AppRoute): void {
    const config = AppRouteStore.load(context);
    const now = Date.now();
    let existing = -1;
    for (let i = 0; i < config.rules.length; i++) {
      const current = config.rules[i];
      if (current.id === route.id || current.bundleName === route.bundleName) {
        if (existing >= 0 && config.rules[existing].id !== current.id) {
          throw new Error('同一个 App 只能有一条指定节点规则');
        }
        existing = i;
      }
    }
    const next = new AppRoute();
    next.id = route.id;
    next.bundleName = route.bundleName.trim();
    next.label = route.label.trim();
    next.nodeId = route.nodeId;
    next.enabled = route.enabled;
    next.createdAt = existing >= 0 ? config.rules[existing].createdAt : route.createdAt;
    if (next.createdAt === 0) {
      next.createdAt = now;
    }
    next.updatedAt = now;
    if (existing >= 0) {
      config.rules[existing] = next;
    } else {
      config.rules.push(next);
    }
    AppRouteStore.save(context, config);
  }

  static remove(context: common.Context, id: string): boolean {
    const config = AppRouteStore.load(context);
    const before = config.rules.length;
    config.rules = config.rules.filter((route: AppRoute): boolean => route.id !== id);
    if (before === config.rules.length) {
      return false;
    }
    AppRouteStore.save(context, config);
    return true;
  }
}
