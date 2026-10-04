import { AppLog as hilog } from './AppLog';
import { common } from '@kit.AbilityKit';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { StatusStore } from './StatusStore';

export const SYSTEM_EXIT_FILE: string = 'system-exit-events.json';
const EVENTS: string[] = ['APP_CRASH', 'APP_FREEZE', 'APP_KILLED'];
const BUNDLE: string = 'com.oscarwoltz.tongdao';

// The OS delivers these after a process has died. Keep their original time and
// process identity; never attribute a historical exit to the current VPN owner.
export class SystemExitEvidence {
  private static watcher: hiAppEvent.Watcher | null = null;

  static start(context: common.Context): void {
    if (SystemExitEvidence.watcher !== null) return;
    const watcher: hiAppEvent.Watcher = {
      name: 'pangolin_system_exit',
      appEventFilters: [{ domain: hiAppEvent.domain.OS,
        names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE, hiAppEvent.event.APP_KILLED] }],
      onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
        if (domain !== hiAppEvent.domain.OS) return;
        groups.forEach((group: hiAppEvent.AppEventGroup) => {
          group.appEventInfos.forEach((event: hiAppEvent.AppEventInfo) => {
            SystemExitEvidence.receive(context, event.name, event.params as Record<string, Object>);
          });
        });
      }
    };
    try {
      hiAppEvent.addWatcher(watcher); SystemExitEvidence.watcher = watcher;
      hilog.info(0x3200, 'SystemExit', 'OS exit watcher registered');
    } catch (_error) { hilog.warn(0x3200, 'SystemExit', 'OS exit watcher unavailable'); }
  }

  static stop(): void {
    const watcher = SystemExitEvidence.watcher;
    SystemExitEvidence.watcher = null;
    if (watcher !== null) { try { hiAppEvent.removeWatcher(watcher); } catch (_error) {} }
  }

  static read(context: common.Context): Record<string, Object>[] {
    try {
      const value = JSON.parse(StatusStore.readText(context, SYSTEM_EXIT_FILE) || '[]') as Object;
      if (!Array.isArray(value)) return [];
      const out: Record<string, Object>[] = [];
      (value as Record<string, Object>[]).slice(-32).forEach((row: Record<string, Object>) => {
        if (row === null || typeof row !== 'object') return;
        const safe = SystemExitEvidence.sanitize(row['eventName'] as string, row,
          typeof row['receivedAt'] === 'number' ? row['receivedAt'] as number : 0);
        if (safe !== null) out.push(safe);
      });
      return out;
    } catch (_error) { return []; }
  }

  private static receive(context: common.Context, name: string, params: Record<string, Object>): void {
    try {
      const row = SystemExitEvidence.sanitize(name, params, Date.now());
      if (row === null) return;
      const rows = SystemExitEvidence.read(context);
      if (rows.some((old: Record<string, Object>) => old['eventName'] === row['eventName'] &&
        old['time'] === row['time'] && old['pid'] === row['pid'] && old['reason'] === row['reason'] &&
        old['process_name'] === row['process_name'])) return;
      rows.push(row);
      rows.sort((a: Record<string, Object>, b: Record<string, Object>) => (a['time'] as number) - (b['time'] as number));
      StatusStore.writeText(context, SYSTEM_EXIT_FILE, JSON.stringify(rows.slice(-32)));
    } catch (_error) { /* No raw event bodies or arbitrary exception messages are logged. */ }
  }

  private static sanitize(name: string, params: Record<string, Object>, receivedAt: number): Record<string, Object> | null {
    if (EVENTS.indexOf(name) < 0 || params === null || typeof params !== 'object' ||
      typeof params['time'] !== 'number' || !Number.isFinite(params['time'] as number) || (params['time'] as number) <= 0) return null;
    const processName = typeof params['process_name'] === 'string' ? params['process_name'] as string : '';
    if (processName.length > 0 && processName !== BUNDLE && !processName.startsWith(`${BUNDLE}:`)) return null;
    const row: Record<string, Object> = { 'eventName': name, 'time': params['time'], 'receivedAt': receivedAt };
    if (processName.length > 0) row['process_name'] = processName;
    ['pid', 'app_running_unique_id'].forEach((key: string) => {
      if (typeof params[key] === 'number' && Number.isFinite(params[key] as number)) row[key] = params[key];
    });
    if (typeof params['foreground'] === 'boolean') row['foreground'] = params['foreground'];
    ['reason', 'bundle_version', 'exceptionName'].forEach((key: string) => {
      const value = params[key];
      if (typeof value === 'number' && Number.isFinite(value)) row[key] = value;
      else if (typeof value === 'string' && /^[A-Za-z0-9_. :()+-]{1,160}$/.test(value)) row[key] = value;
    });
    const exception = params['exception'];
    if (exception !== null && typeof exception === 'object' && !Array.isArray(exception)) {
      const value = (exception as Record<string, Object>)['name'];
      if (typeof value === 'string' && /^[A-Za-z0-9_ .()+-]{1,80}$/.test(value)) row['exceptionName'] = value;
    }
    const paths = params['external_log'] || params['logFiles'];
    const files: string[] = [];
    if (Array.isArray(paths)) {
      (paths as Object[]).slice(0, 8).forEach((path: Object) => {
        if (typeof path !== 'string') return;
        const prefix = '/data/storage/el2/log/hiappevent/';
        const file = path.startsWith(prefix) ? path.substring(prefix.length) : path;
        if (/^APP_(CRASH|FREEZE|KILLED)_[A-Za-z0-9_.-]+\.log$/.test(file) && file.indexOf('..') < 0) files.push(file);
      });
    }
    row['logFiles'] = files;
    return row;
  }
}
