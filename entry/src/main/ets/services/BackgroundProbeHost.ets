import { common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { PROBE_SELF_CHECK } from './ProbeSelfCheck';
import { StatusStore } from './StatusStore';

// UI-path checks belong to the visible app. The VPN extension owns its own
// background SOCKS checks; it must not need a UI DATA_TRANSFER notification.
export class BackgroundProbeHost {
  private foreground: boolean = true;
  private legacyTaskRetired: boolean = false;

  start(context: common.UIAbilityContext, source: string): void {
    if (!this.legacyTaskRetired) {
      this.legacyTaskRetired = true;
      // Migration cleanup only. Never request a new continuous task or hide
      // a notification while keeping such a task alive.
      try { backgroundTaskManager.stopBackgroundRunning(context).catch(() => {}); } catch (_error) {}
    }
    if (source.indexOf('onBackground') >= 0) {
      this.foreground = false;
      PROBE_SELF_CHECK.setForeground(false);
      PROBE_SELF_CHECK.stopLoop();
      return;
    }
    if (source.indexOf('onCreate') >= 0 || source.indexOf('onForeground') >= 0) {
      this.foreground = true;
      PROBE_SELF_CHECK.setForeground(true);
    }
    if (!this.foreground) return;
    const status = StatusStore.readStatus(context);
    if (status.desiredRunning !== true && source.indexOf('startTunnel') < 0) return;
    PROBE_SELF_CHECK.startLoop(context);
    if (source.indexOf('onForeground') >= 0) PROBE_SELF_CHECK.tick(context, true).catch(() => {});
  }

  stop(_context: common.UIAbilityContext, source: string): void {
    if (source.indexOf('onDestroy') >= 0) this.foreground = false;
    PROBE_SELF_CHECK.stopLoop();
  }
}

export const BACKGROUND_PROBE_HOST: BackgroundProbeHost = new BackgroundProbeHost();
