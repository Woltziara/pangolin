import { bundleManager, common } from '@kit.AbilityKit';
import { ObservedApp } from '../core/AppRouteModel';
import { StatusStore } from './StatusStore';

export const OBSERVED_APPS_FILE: string = 'observed-apps.json';

/**
 * App lookup deliberately uses the ordinary GET_BUNDLE_INFO capability only.
 * It does not enumerate installed apps: the list is supplied by the VPN's
 * bounded, local observation record.
 */
export class AppCatalog {
  static async resolve(bundleName: string): Promise<ObservedApp> {
    const cleaned = bundleName.trim();
    if (cleaned.length === 0) {
      throw new Error('请先填写 App 包名');
    }
    try {
      const info = await bundleManager.getBundleInfo(cleaned,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const app = new ObservedApp();
      app.bundleName = cleaned;
      // API 23 BundleInfo.appInfo exposes the package UID. Do not infer it
      // from a stale observed record: reinstalling an app can change its UID.
      app.uid = info.appInfo.uid;
      app.label = info.appInfo.label;
      if (app.label.length === 0) {
        app.label = cleaned;
      }
      if (!Number.isSafeInteger(app.uid) || app.uid < 0) {
        throw new Error('系统没有返回有效 UID');
      }
      app.lastSeenAt = Date.now();
      return app;
    } catch (error) {
      const detail = error instanceof Error ? error.message : JSON.stringify(error);
      throw new Error(`无法确认包名 ${cleaned}：${detail}`);
    }
  }

  static observed(context: common.Context): ObservedApp[] {
    const raw = StatusStore.readJsonFile(context, OBSERVED_APPS_FILE);
    if (raw.length === 0) {
      return [];
    }
    try {
      const doc = JSON.parse(raw) as Record<string, Object>;
      if (doc === null || typeof doc !== 'object' || doc['version'] !== 1 || !(doc['items'] instanceof Array)) {
        throw new Error('观察记录结构无效');
      }
      const items = doc['items'] as Array<Object>;
      const names = new Set<string>();
      const result: ObservedApp[] = [];
      for (let i = 0; i < items.length; i++) {
        const item = items[i] as Record<string, Object>;
        if (item === null || typeof item !== 'object' || typeof item['bundleName'] !== 'string' ||
          typeof item['label'] !== 'string' || typeof item['uid'] !== 'number' || typeof item['lastSeenAt'] !== 'number' ||
          item['bundleName'].length === 0 || item['label'].length === 0 || !Number.isSafeInteger(item['uid']) ||
          item['uid'] < 0 || !Number.isSafeInteger(item['lastSeenAt']) || item['lastSeenAt'] < 0 || names.has(item['bundleName'])) {
          throw new Error('观察记录含有无效 App');
        }
        names.add(item['bundleName']);
        const app = new ObservedApp();
        app.bundleName = item['bundleName'];
        app.label = item['label'];
        app.uid = item['uid'];
        app.lastSeenAt = item['lastSeenAt'];
        result.push(app);
      }
      result.sort((a: ObservedApp, b: ObservedApp): number => b.lastSeenAt - a.lastSeenAt || a.bundleName.localeCompare(b.bundleName));
      return result;
    } catch (error) {
      const detail = error instanceof Error ? error.message : JSON.stringify(error);
      throw new Error(`已识别 App 记录无法读取：${detail}`);
    }
  }
}
