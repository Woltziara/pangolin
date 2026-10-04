import { common } from '@kit.AbilityKit';
import { BACKGROUND_KEEP_ALIVE } from './BackgroundKeepAlive';
import { PROBE_SELF_CHECK } from './ProbeSelfCheck';
import { StatusStore } from './StatusStore';

export class BackgroundProbeHost {
  start(context: common.UIAbilityContext, source: string): void {
    const status = StatusStore.readStatus(context);
    const wantKeep = status.desiredRunning === true || source.indexOf('startTunnel') >= 0;
    if (!wantKeep) {
      return;
    }
    BACKGROUND_KEEP_ALIVE.ensure(context, source).then((ok: boolean) => {
      if (!ok) {
        this.failClosed(context, source, status.phase, 'keep-alive ensure returned false');
        return;
      }
      // The VPN process publishes a per-session probe request, but the UI
      // process owns the HTTP/DNS receipt.  Keeping the process alive without
      // starting this loop leaves every healthy-looking tunnel permanently
      // UNPROVEN and prevents the supervisor from seeing fresh failures.
      PROBE_SELF_CHECK.startLoop(context);
    }).catch((error: Object) => {
      this.failClosed(context, source, status.phase, `${error}`);
    });
  }

  stop(context: common.UIAbilityContext, source: string): void {
    PROBE_SELF_CHECK.stopLoop();
    BACKGROUND_KEEP_ALIVE.stop(context, source).catch((error: Object) => {
      const rec: Record<string, Object> = {};
      rec['error'] = `${error}`;
      rec['at'] = Date.now();
      rec['source'] = source;
      StatusStore.writeText(context, 'background-keepalive.json', JSON.stringify(rec));
    });
  }

  private failClosed(context: common.UIAbilityContext, source: string, phase: string, message: string): void {
    PROBE_SELF_CHECK.stopLoop();
    const rec: Record<string, Object> = {};
    rec['ok'] = false;
    rec['error'] = message;
    rec['at'] = Date.now();
    rec['source'] = source;
    rec['phase'] = phase;
    StatusStore.writeText(context, 'background-keepalive.json', JSON.stringify(rec));
  }
}

export const BACKGROUND_PROBE_HOST: BackgroundProbeHost = new BackgroundProbeHost();
