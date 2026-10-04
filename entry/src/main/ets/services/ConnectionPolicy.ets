import { common } from '@kit.AbilityKit';
import { effectiveChannelMode, payloadForFailover, singleChannelPayload } from '../core/ChannelPolicy';
import { requireCertificateVerification } from '../core/OutboundReady';
import { SettingsStore } from './SettingsStore';

/** Local connection policy: channel and failover behavior follow the user's settings. */
class ConnectionPolicy {
  mode(context: common.Context): string { return effectiveChannelMode(SettingsStore.load(context).channelMode); }
  allowsAutoFailover(): boolean { return true; }
  autoFailoverEnabled(context: common.Context): boolean {
    return SettingsStore.load(context).failoverEnabled === true;
  }
  enforcePayload(context: common.Context, payload: string): string {
    const channelled = this.mode(context) === 'dual' ? payload : singleChannelPayload(payload);
    const effective = JSON.parse(payloadForFailover(channelled, this.autoFailoverEnabled(context))) as Record<string, Object>;
    const names: string[] = ['single', 'single2', 'us', 'yt', 'us2', 'yt2'];
    for (let i = 0; i < names.length; i++) {
      const value = effective[names[i]];
      if (value !== undefined) {
        effective[names[i]] = JSON.parse(requireCertificateVerification(JSON.stringify(value))) as Object;
      }
    }
    return JSON.stringify(effective);
  }
}
export const CONNECTION_POLICY = new ConnectionPolicy();
