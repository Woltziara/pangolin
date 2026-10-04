import { common } from '@kit.AbilityKit';
import { digestText, RUNNING_DIGEST_FILE } from '../core/OutboundCommit';
import { StatusStore } from './StatusStore';
import { UserRuleStore } from './UserRuleStore';
import { SettingsStore } from './SettingsStore';
import { CONNECTION_POLICY } from './ConnectionPolicy';
import { routesForChannel } from '../core/ChannelPolicy';
import { AppRoutingConfig, appRoutingFingerprint } from '../core/AppRouteModel';
import { AppRouteStore } from './AppRouteStore';

const FILE: string = 'applied-policy.json';

/** Receipt is written only after the native core accepted this exact payload. No credentials. */
export class AppliedPolicy {
  private static defaultAppRoutingFingerprint(): string {
    return appRoutingFingerprint({ version: 1, enabled: false, rules: [] } as AppRoutingConfig);
  }

  private static payloadAppRoutingFingerprint(source: Record<string, Object>): string {
    const routing = source['appRouting'];
    if (routing === undefined) {
      return AppliedPolicy.defaultAppRoutingFingerprint();
    }
    if (routing === null || typeof routing !== 'object' || (routing as Record<string, Object>)['config'] === undefined) {
      throw new Error('运行 payload 缺少有效的 App 路由配置');
    }
    return appRoutingFingerprint((routing as Record<string, Object>)['config'] as AppRoutingConfig);
  }

  static noteRunning(context: common.Context, payload: string): void {
    const rec: Record<string, Object> = {};
    rec['digest'] = digestText(payload);
    rec['at'] = Date.now();
    StatusStore.writeText(context, RUNNING_DIGEST_FILE, JSON.stringify(rec));
  }

  static record(context: common.Context, payload: string, generation: string, intent: Record<string, Object> | null = null): void {
    const source = JSON.parse(payload) as Record<string, Object>;
    const settings = SettingsStore.load(context);
    const record: Record<string, Object> = {};
    record['generation'] = generation;
    record['at'] = Date.now();
    record['routeMode'] = source['routeMode'] ?? 'rule';
    record['intendedChatgptNodeId'] = intent !== null ? intent['chatgptNodeId'] : settings.chatgptNodeId;
    record['intendedGeneralNodeId'] = intent !== null ? intent['generalNodeId'] : settings.generalNodeId;
    record['intendedSingleNodeId'] = intent !== null ? intent['singleNodeId'] : settings.singleNodeId;
    record['chatgptNodeId'] = source['usNodeId'] ?? source['chatgptNodeId'] ?? '';
    record['generalNodeId'] = source['ytNodeId'] ?? source['generalNodeId'] ?? '';
    record['channelMode'] = source['channelMode'] ?? 'dual';
    record['singleNodeId'] = source['singleNodeId'] ?? '';
    record['executingName'] = source['singleName'] ?? source['usName'] ?? '';
    record['failedOver'] = source['singleFailedOver'] === true || source['usFailedOver'] === true ||
      source['ytFailedOver'] === true;
    record['payloadDigest'] = digestText(payload);
    record['userRules'] = source['userRules'] ?? [];
    record['appRoutingFingerprint'] = AppliedPolicy.payloadAppRoutingFingerprint(source);
    StatusStore.writeJsonAtomic(context, FILE, JSON.stringify(record));
  }

  static current(context: common.Context): Record<string, Object> | null {
    try {
      const raw = StatusStore.readJsonFile(context, FILE);
      if (raw.length < 2) { return null; }
      const receipt = JSON.parse(raw) as Record<string, Object>;
      const status = StatusStore.readStatus(context);
      if (!status.xrayRunning || !status.vpnCreated || Date.now() - status.at > 30000 ||
        receipt['generation'] !== status.generation) { return null; }
      const liveDigest = status.payloadDigest;
      if (typeof liveDigest !== 'string' || liveDigest.length < 4) { return null; }
      if (liveDigest !== receipt['payloadDigest']) { return null; }
      return receipt;
    } catch (error) { return null; }
  }

  /** Compare saved selection intent even when its old VPN owner is gone.
   * This does not attest that the saved route is currently running. */
  static savedSelectionChanged(context: common.Context): boolean {
    try {
      const raw = StatusStore.readJsonFile(context, FILE);
      if (raw.length < 2) return false;
      const receipt = JSON.parse(raw) as Record<string, Object>;
      if (typeof receipt['generation'] !== 'string' || (receipt['generation'] as string).length === 0 ||
        typeof receipt['payloadDigest'] !== 'string' || (receipt['payloadDigest'] as string).length < 4) return false;
      const settings = SettingsStore.load(context);
      const mode = CONNECTION_POLICY.mode(context);
      if (receipt['channelMode'] !== 'single' && receipt['channelMode'] !== 'dual') return false;
      if (receipt['channelMode'] !== mode) return true;
      if (mode === 'single') {
        return typeof receipt['intendedSingleNodeId'] === 'string' && receipt['intendedSingleNodeId'] !== settings.singleNodeId;
      }
      return typeof receipt['intendedChatgptNodeId'] === 'string' && typeof receipt['intendedGeneralNodeId'] === 'string' &&
        (receipt['intendedChatgptNodeId'] !== settings.chatgptNodeId || receipt['intendedGeneralNodeId'] !== settings.generalNodeId);
    } catch (_error) { return false; }
  }

  static matches(context: common.Context): boolean {
    const receipt = AppliedPolicy.current(context);
    if (receipt === null) { return false; }
    const settings = SettingsStore.load(context);
    const mode = CONNECTION_POLICY.mode(context);
    let currentAppRouting: string;
    try {
      currentAppRouting = appRoutingFingerprint(AppRouteStore.load(context));
    } catch (_error) {
      return false;
    }
    const receivedAppRouting = typeof receipt['appRoutingFingerprint'] === 'string'
      ? receipt['appRoutingFingerprint'] as string : AppliedPolicy.defaultAppRoutingFingerprint();
    return receipt['routeMode'] === settings.routeMode &&
      receipt['channelMode'] === mode &&
      (mode === 'single' ? receipt['intendedSingleNodeId'] === settings.singleNodeId :
        receipt['intendedChatgptNodeId'] === settings.chatgptNodeId &&
        receipt['intendedGeneralNodeId'] === settings.generalNodeId) &&
      JSON.stringify(receipt['userRules']) === JSON.stringify(routesForChannel(UserRuleStore.enabledRoutes(context), mode)) &&
      receivedAppRouting === currentAppRouting;
  }
}
