import { common, errorManager } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { configureErrorLog, recordErrorLog } from '../native/TunnelNative';

export const ERROR_JOURNAL_FILES: string[] = ['error-journal.jsonl', 'error-journal.1.jsonl', 'error-journal.2.jsonl', 'error-journal.3.jsonl'];

// Native flock serializes the UI, VPN and scheduler processes into one journal.
// Error records do not compete with periodic metrics samples.
export class ErrorJournal {
  private static observer: number = -1;
  static start(context: common.Context, component: string): void {
    try { configureErrorLog(context.filesDir); } catch (_error) { return; }
    if (ErrorJournal.observer >= 0) return;
    try {
      ErrorJournal.observer = errorManager.on('error', {
        onUnhandledException: (message: string): void => {
          ErrorJournal.record('fatal', `${component}.uncaught`, message, message);
        },
        onException: (error: Error): void => {
          ErrorJournal.record('error', `${component}.exception`, error.message, error.stack || '');
        }
      });
      errorManager.on('unhandledRejection', (reason: Object, _promise: Promise<Object>): void => { ErrorJournal.error(`${component}.promise`, reason); });
    } catch (error) { ErrorJournal.record('warn', component, 'Global error observer registration failed', ''); }
  }
  static record(level: string, component: string, message: string, stack: string = ''): void {
    try { recordErrorLog(level, component, message, stack); } catch (_error) { /* Preserve original operation. */ }
  }
  static error(component: string, error: Object): void {
    if (typeof error === 'string') { ErrorJournal.record('error', component, error); return; }
    if (error === null || error === undefined) { ErrorJournal.record('error', component, 'Operation failed'); return; }
    const value = error as Record<string, Object>;
    const message = typeof value['message'] === 'string' ? value['message'] as string : 'Operation failed';
    const stack = typeof value['stack'] === 'string' ? value['stack'] as string : '';
    ErrorJournal.record('error', component, message, stack);
  }
  static read(context: common.Context): Record<string, Object> {
    const records: Record<string, Object>[] = [];
    let corrupt = 0;
    let bytes = 0;
    let total = 0;
    for (let i = ERROR_JOURNAL_FILES.length - 1; i >= 0; i--) {
      try {
        const path = `${context.filesDir}/${ERROR_JOURNAL_FILES[i]}`;
        if (!fs.accessSync(path)) continue;
        bytes += fs.statSync(path).size;
        const lines = fs.readTextSync(path).split('\n');
        for (let p = 0; p < lines.length; p++) {
          if (lines[p].trim().length === 0) continue;
          try {
            const row = JSON.parse(lines[p]) as Record<string, Object>;
            if (row['schema'] === 1 && typeof row['at'] === 'number' && typeof row['message'] === 'string') { total++; records.push(row); if (records.length > 500) records.shift(); }
            else corrupt++;
          } catch (_error) { corrupt++; }
        }
      } catch (_error) { corrupt++; }
    }
    return { 'records': records, 'count': records.length, 'totalRecords': total, 'omittedFromReport': total - records.length, 'corruptLines': corrupt, 'bytes': bytes,
      'capacityBytes': 32 * 1024 * 1024, 'retention': 'until-capacity-rollover', 'captures': 'warn/error/fatal and global exceptions',
      'returnedLimit': 500, 'limits': 'Abrupt process death or storage failure can prevent an append; OS crash evidence is collected separately.' };
  }
}
