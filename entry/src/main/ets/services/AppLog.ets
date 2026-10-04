import { hilog } from '@kit.PerformanceAnalysisKit';
import { ErrorJournal } from './ErrorJournal';

export class AppLog {
  private static text(format: string, args: Object[]): string {
    let i = 0;
    return format.replace(/%\{(public|private)\}[sdif]/g, (_match: string, visibility: string): string => {
      if (i >= args.length) return '[missing]';
      const value = args[i++];
      if (visibility === 'private') return '[private]';
      return typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean' ? String(value) : '[object]';
    });
  }
  static info(domain: number, tag: string, format: string, ...args: Object[]): void { hilog.info(domain, tag, format, ...args); }
  static debug(domain: number, tag: string, format: string, ...args: Object[]): void { hilog.debug(domain, tag, format, ...args); }
  static warn(domain: number, tag: string, format: string, ...args: Object[]): void {
    ErrorJournal.record('warn', tag, AppLog.text(format, args)); hilog.warn(domain, tag, format, ...args);
  }
  static error(domain: number, tag: string, format: string, ...args: Object[]): void {
    ErrorJournal.record('error', tag, AppLog.text(format, args)); hilog.error(domain, tag, format, ...args);
  }
  static fatal(domain: number, tag: string, format: string, ...args: Object[]): void {
    ErrorJournal.record('fatal', tag, AppLog.text(format, args)); hilog.fatal(domain, tag, format, ...args);
  }
}
