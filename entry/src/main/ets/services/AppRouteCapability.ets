import { bundleManager, common } from '@kit.AbilityKit';
import { AppRoutingConfig } from '../core/AppRouteModel';
import { AppUidBinding, addUidBinding } from '../core/AppRoutePayload';
import { AppCatalog } from './AppCatalog';
import { AppRouteStore } from './AppRouteStore';
import { SettingsStore } from './SettingsStore';
import { deadline } from './AsyncDeadline';

export const SHARED_HOST_GUIDANCE: string = '出境易等容器里的应用共用一个应用身份。要指定节点，请选择容器；容器内的应用无法分别设置。';

export class AppRouteCapability {
  static async current(context: common.Context): Promise<void> {
    if (SettingsStore.load(context).routeMode === 'direct') return;
    const config = AppRouteStore.load(context);
    const before = JSON.stringify(config);
    await AppRouteCapability.check(config);
    if (SettingsStore.load(context).routeMode === 'direct' || JSON.stringify(AppRouteStore.load(context)) !== before) {
      throw new Error('核验期间 App 规则或连接模式已改变，原连接未动；请重新应用。');
    }
  }
  static async check(config: AppRoutingConfig): Promise<void> {
    if (!config.enabled) return;
    const bindings: AppUidBinding[] = [];
    for (let i = 0; i < config.rules.length; i++) {
      const rule = config.rules[i];
      if (!rule.enabled) continue;
      if (rule.bundleName === 'com.openai.chatgpt' || rule.bundleName === 'com.google.android.gms') {
        throw new Error(SHARED_HOST_GUIDANCE);
      }
      try {
        const identity = await deadline(AppCatalog.resolve(rule.bundleName), 3000, 'App 身份查询超时');
        const bundle = await deadline(bundleManager.getBundleNameByUid(identity.uid), 3000, 'App 反向身份查询超时');
        if (bundle !== rule.bundleName) throw new Error('App 身份不一致');
        const binding = new AppUidBinding();
        binding.uid = identity.uid; binding.bundleName = rule.bundleName; binding.nodeId = rule.nodeId;
        addUidBinding(bindings, binding);
      } catch (_error) {
        // Never claim SDK availability proves permission for this install.
        throw new Error('当前安装身份不能可靠确认 App 分流权限或 UID，原连接保持不变。请停用该待应用规则或使用已验证的原生 App；不授予特权、不按旧 UID 猜测。');
      }
    }
  }
}
