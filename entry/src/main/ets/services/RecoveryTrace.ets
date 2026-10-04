import { common } from '@kit.AbilityKit';
import { DiagnosticReport } from './DiagnosticReport';
import { StatusStore } from './StatusStore';
import { RuntimeJournal } from './RuntimeJournal';
import { BuildIdentity } from './BuildIdentity';
import { serializeStatus } from '../net/DataplaneStatus';
import { probeIdentity } from '../net/ProbeResult';

/** Freeze the failure before any repair. Recording must never prevent recovery. */
export class RecoveryTrace {
  static currentRouteAlreadyFailed(context: common.Context): boolean {
    try {
      const status = StatusStore.readStatus(context);
      if (status.connectionHealth !== 'check-failed') return false;
      const identity = probeIdentity(status);
      const names = StatusStore.listNames(context).filter((name: string) =>
        /^incident-report-\d+\.json$/.test(name)).sort().reverse().slice(0, 5);
      for (let i = 0; i < names.length; i++) {
        try {
          const doc = JSON.parse(StatusStore.readStrictText(context, names[i])) as Record<string, Object>;
          const attempt = doc['recoveryAttempt'] as Record<string, Object>;
          if (attempt !== undefined && attempt['action'] === 'rebuild-current-route' &&
            attempt['state'] === 'failed' && attempt['afterIdentity'] === identity) return true;
        } catch (_error) {}
      }
    } catch (_error) {}
    return false;
  }
  static begin(context: common.Context, action: string): string {
    try {
      const status = StatusStore.readStatus(context);
      let native: Record<string, Object> = {};
      try { native = JSON.parse(StatusStore.readText(context, 'native-stats.json') || '{}') as Record<string, Object>; } catch (_error) {}
      const before: Record<string, Object> = { 'generation': status.generation, 'phase': status.phase,
        'at': status.at, 'connectionHealth': status.connectionHealth, 'networkState': status.networkState };
      const doc: Record<string, Object> = { 'v': 2, 'time': Date.now(), 'sanitized': true,
        'buildSourceIdentity': BuildIdentity.source(context), 'status': before,
        'runtimeSnapshot': RuntimeJournal.snapshot(JSON.parse(serializeStatus(status)) as Record<string, Object>, native),
        'runtimeJournal': RuntimeJournal.read(context), 'checks': [], 'events': [], 'targetBusiness': 'not-observed' };
      const recovery: Record<string, Object> = { 'action': action, 'startedAt': Date.now(),
        'state': 'pending', 'beforeIdentity': probeIdentity(status), 'businessOutcome': 'not-observed' };
      doc['recoveryAttempt'] = recovery;
      const path = DiagnosticReport.write(context, doc, true);
      return path.substring(path.lastIndexOf('/') + 1);
    } catch (_error) { return ''; }
  }
  static finish(context: common.Context, name: string): void {
    if (!/^incident-report-\d+\.json$/.test(name)) return;
    try {
      const doc = JSON.parse(StatusStore.readStrictText(context, name)) as Record<string, Object>;
      const attempt = doc['recoveryAttempt'] as Record<string, Object>;
      if (attempt === undefined || attempt['state'] !== 'pending') return;
      const status = StatusStore.readStatus(context);
      const live = status.desiredRunning && status.vpnCreated && status.tunFdValid && status.xrayRunning &&
        status.forwarderOk && !status.cleanupPending && !status.nativePoisoned &&
        status.at > 0 && Date.now() >= status.at && Date.now() - status.at <= 25000;
      attempt['finishedAt'] = Date.now();
      attempt['state'] = live && status.connectionHealth === 'reachable' ? 'network-ready' :
        status.phase === 'ERROR' || status.phase === 'STOP_UNCONFIRMED' ||
        status.connectionHealth === 'offline' || status.connectionHealth === 'check-failed' ? 'failed' : 'unverified';
      attempt['afterGeneration'] = status.generation;
      attempt['afterIdentity'] = probeIdentity(status);
      attempt['afterPhase'] = status.phase;
      attempt['networkHealth'] = status.connectionHealth;
      // A successful probe is never a ChatGPT reply or a framework recovery.
      attempt['businessOutcome'] = 'not-observed';
      StatusStore.writeText(context, name, JSON.stringify(doc, null, 2));
    } catch (_error) {}
  }
  static reportBusiness(context: common.Context, name: string, success: boolean): boolean {
    if (!/^incident-report-\d+\.json$/.test(name)) return false;
    try {
      const doc = JSON.parse(StatusStore.readStrictText(context, name)) as Record<string, Object>;
      const attempt = doc['recoveryAttempt'] as Record<string, Object>;
      const live = StatusStore.readStatus(context);
      const expected = attempt['afterIdentity'] || attempt['beforeIdentity'];
      if (probeIdentity(live) !== expected) return false;
      attempt['businessOutcome'] = success ? 'user-reported-success' : 'user-reported-failure';
      attempt['businessReportedAt'] = Date.now();
      StatusStore.writeText(context, name, JSON.stringify(doc, null, 2));
      return true;
    } catch (_error) { return false; }
  }
}
