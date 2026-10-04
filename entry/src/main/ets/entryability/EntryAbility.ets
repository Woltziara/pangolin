import { ErrorJournal } from '../services/ErrorJournal';
import { AppLog as hilog } from '../services/AppLog';
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BACKGROUND_PROBE_HOST } from '../services/BackgroundProbeHost';
import { StatusStore } from '../services/StatusStore';
import { LATENCY_PROBE } from '../services/LatencyProbe';
import { SystemExitEvidence } from '../services/SystemExitEvidence';

const DOMAIN = 0x3200;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ErrorJournal.start(this.context, 'ui');
    hilog.info(DOMAIN, 'Entry', 'onCreate');
    StatusStore.seedFromRawfile(this.context);
    SystemExitEvidence.start(this.context);
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onCreate');
    this.runRequestedLatencyProbe(want);
    this.runRequestedMaintenance(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onNewWant');
    this.runRequestedLatencyProbe(want);
    this.runRequestedMaintenance(want);
  }

  private runRequestedMaintenance(want: Want): void {
    const request = want.parameters?.['maintenanceSelfTest'];
    if (typeof request === 'string' && /^[a-f0-9]{8,64}$/.test(request)) {
      ErrorJournal.record('error', 'maintenance-selftest', 'Synthetic diagnostic record; no application fault triggered', `request=${request}`);
    }
  }

  private runRequestedLatencyProbe(want: Want): void {
    const runId = want.parameters?.['latencyProbe'];
    if (typeof runId === 'string' && LATENCY_PROBE.validRunId(runId)) {
      const forceFresh = want.parameters?.['latencyFresh'] === true;
      LATENCY_PROBE.runHttp(this.context, runId, null, forceFresh).catch(() => {
        hilog.warn(DOMAIN, 'Entry', 'latency diagnostic did not complete');
      });
    }
  }


  onDestroy(): void {
    hilog.info(DOMAIN, 'Entry', 'onDestroy');
    SystemExitEvidence.stop();
    BACKGROUND_PROBE_HOST.stop(this.context, 'EntryAbility.onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'Entry', 'loadContent %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'Entry', 'content loaded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'Entry', 'window destroyed');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'Entry', 'foreground');
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onForeground');
  }

  onBackground(): void {
    // Stop UI-path requests when hidden. VPN-owned checks continue in the
    // extension without a separate data-transfer notification.
    hilog.info(DOMAIN, 'Entry', 'background');
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onBackground');
  }
}
