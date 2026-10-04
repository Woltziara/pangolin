import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BACKGROUND_PROBE_HOST } from '../services/BackgroundProbeHost';
import { StatusStore } from '../services/StatusStore';
import { LATENCY_PROBE } from '../services/LatencyProbe';

const DOMAIN = 0x3200;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'Entry', 'onCreate');
    StatusStore.seedFromRawfile(this.context);
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onCreate');
    this.runRequestedLatencyProbe(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onNewWant');
    this.runRequestedLatencyProbe(want);
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
    // Official VPN keep-alive: start DATA_TRANSFER continuous task when the
    // UI process leaves the foreground. UI setInterval is frozen after that.
    // https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-network-134
    hilog.info(DOMAIN, 'Entry', 'background');
    BACKGROUND_PROBE_HOST.start(this.context, 'EntryAbility.onBackground');
  }
}
