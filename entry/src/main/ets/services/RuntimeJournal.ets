import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

// This is intentionally independent of EventStore.  It is a small, local
// runtime flight recorder used only by the VPN process; it is not a UI event
// history and must never become one.
export const JOURNAL_FILES: Array<string> = [
  'runtime-journal.jsonl', 'runtime-journal.1.jsonl',
  'runtime-journal.2.jsonl', 'runtime-journal.3.jsonl'
];

const RETENTION_MS: number = 48 * 60 * 60 * 1000;
const CAPACITY_BYTES: number = 4 * 1024 * 1024;
const SEGMENT_BYTES: number = CAPACITY_BYTES / JOURNAL_FILES.length;
const MAX_LINE_BYTES: number = 8 * 1024;
const SAMPLE_MS: number = 30 * 1000;

const PHASES: Array<string> = ['IDLE', 'STARTING', 'VPN_CREATED', 'PROBE_SNIFFING',
  'CORE_RUNNING', 'FORWARDER_RUNNING', 'CANARY_OK', 'UNPROVEN', 'DEGRADED_UNPROVEN',
  'DEGRADED', 'RECONNECTING', 'ERROR', 'STOPPED', 'STALE', 'POISONED'];
const EVENT_KINDS: Array<string> = ['canary', 'net', 'recover-begin', 'recover-end', 'session-start', 'session-stop'];
const STATUS_BOOLEANS: Array<string> = ['vpnCreated', 'tunFdValid', 'tunReceiving', 'dnsOk',
  'forwarderOk', 'protectOk', 'nodeTcpOk', 'canaryOk', 'socksCanaryOk', 'directOk', 'proxyOk',
  'nativePoisoned', 'desiredRunning', 'probePending', 'selfProbe', 'fetchDnsOk', 'xrayRunning'];
const STATUS_NUMBERS: Array<string> = ['tunRxBytes', 'tunTxBytes', 'tunRxPackets', 'tunTxPackets',
  'tunDropped', 'uploadBytes', 'downloadBytes', 'reconnectCount', 'evidenceAt', 'probeRevision',
  'probeEpoch', 'commandEpoch', 'lastReachableAt', 'healthCheckedAt', 'healthRevision',
  'fetchGoogleHttp', 'fetchDirectHttp'];
// Native output is deliberately not treated as a generic JSON metrics tree.
const NATIVE_BOOLEANS: Array<string> = ['xrayRunning', 'tunRunning', 'poisoned'];
const NATIVE_NUMBERS: Array<string> = ['protectQueued', 'protectAcked', 'protectTimeout', 'protectVisible',
  'protectMeasured', 'protectTcp4', 'protectTcp6', 'protectUdp', 'protectTotalUs', 'protectMaxUs'];
const HEV_NUMBERS: Array<string> = ['rxCalls', 'rxAgain', 'rxErrors', 'rxZero', 'rxMessages', 'lastRxErrno',
  'loopCalls', 'loopIdle', 'loopProgress', 'loopTerminal', 'controlCalls', 'controlAgain', 'controlEof',
  'controlErrors', 'lastControlErrno', 'pollCalls', 'pollZeroTimeout', 'pollReady', 'pollEmpty', 'pollErrors',
  'eventIn', 'eventOut', 'eventErr', 'eventHup', 'tcpLoopCalls', 'tcpLoopIdle', 'tcpLoopProgress',
  'tunTraceVersion', 'tunStage', 'tunLastMs', 'tunRegResult', 'tunRegErrno', 'tunFlags', 'tunReadErrno',
  'tunWriteErrno', 'tunInputResult'];
const ROUTING_BOOLEANS: Array<string> = ['enabled', 'active'];
const ROUTING_NUMBERS: Array<string> = ['configuredRules', 'pending', 'queries', 'selected', 'defaulted',
  'rejected', 'ownerQueryFailed', 'identityMismatch', 'overloaded', 'inactive', 'ackFailed', 'tcpQueries', 'udpQueries'];
const PROTECT_NUMBERS: Array<string> = ['requests', 'invalid', 'unavailable', 'claimRejected', 'apiRejected',
  'apiSucceeded', 'lastErrorCode'];
const EXTRA_BOOLEANS: Array<string> = ['ok', 'retrying', 'forced', 'netChanged', 'recoveryRequested'];
const EXTRA_NUMBERS: Array<string> = ['attempt', 'exitCode', 'latencyMs', 'retryCount', 'errorCode'];
const EXTRA_ENUMS: Array<string> = ['ok', 'failed', 'timeout', 'start', 'stop', 'restart', 'reconnect', 'applied',
  'invalid', 'unavailable', 'claim-rejected', 'api-rejected', 'available', 'lost', 'changed'];

export class RuntimeJournal {
  private static lastSampleAt: Record<string, number> = {};
  private static lastSampleFingerprint: Record<string, string> = {};
  private static failedWrites: Record<string, boolean> = {};
  private static lastCleanupAt: Record<string, number> = {};

  static sample(context: common.Context, status: Record<string, Object>, native: Record<string, Object>): void {
    try {
      const key = context.filesDir;
      const fingerprint = JSON.stringify(RuntimeJournal.criticalFingerprint(status, native));
      const now = Date.now();
      if (RuntimeJournal.lastSampleAt[key] !== undefined && now - RuntimeJournal.lastSampleAt[key] < SAMPLE_MS &&
        RuntimeJournal.lastSampleFingerprint[key] === fingerprint) {
        return;
      }
      const record = RuntimeJournal.baseRecord(status, native);
      RuntimeJournal.append(context, record);
      RuntimeJournal.lastSampleAt[key] = now;
      RuntimeJournal.lastSampleFingerprint[key] = fingerprint;
    } catch (error) {
      RuntimeJournal.failedWrites[context.filesDir] = true;
    }
  }

  // Shared with the diagnostic report: returns exactly the persistent journal
  // schema, without a timestamp and without reading or writing any file.
  static snapshot(status: Record<string, Object>, native: Record<string, Object>): Record<string, Object> {
    return RuntimeJournal.baseRecord(status, native, false);
  }

  static event(context: common.Context, kind: string, status: Record<string, Object>, native: Record<string, Object>, extra: Record<string, Object>): void {
    try {
      if (EVENT_KINDS.indexOf(kind) < 0) {
        return;
      }
      const record = RuntimeJournal.baseRecord(status, native);
      record['kind'] = kind;
      RuntimeJournal.copyExtra(record, extra);
      RuntimeJournal.append(context, record);
    } catch (error) {
      RuntimeJournal.failedWrites[context.filesDir] = true;
    }
  }

  static read(context: common.Context): Record<string, Object> {
    const out: Record<string, Object> = {};
    const records: Array<Record<string, Object>> = [];
    let corruptLines = 0;
    let expiredLines = 0;
    let foundFiles = 0;
    let oldest: number = 0;
    let newest: number = 0;
    const cutoff = Date.now() - RETENTION_MS;
    for (let i = JOURNAL_FILES.length - 1; i >= 0; i--) {
      const path = RuntimeJournal.path(context, JOURNAL_FILES[i]);
      try {
        if (!fs.accessSync(path)) {
          continue;
        }
        foundFiles++;
        const lines = fs.readTextSync(path).split('\n');
        for (let p = 0; p < lines.length; p++) {
          const line = lines[p];
          if (line.length === 0) {
            continue;
          }
          try {
            const item = RuntimeJournal.filterDiskRecord(JSON.parse(line) as Record<string, Object>);
            const at = item['at'];
            if (typeof at !== 'number' || at > Date.now() + 60000) {
              corruptLines++;
              continue;
            }
            if (at < cutoff) { expiredLines++; continue; }
            records.push(item);
            if (oldest === 0 || at < oldest) oldest = at;
            if (at > newest) newest = at;
          } catch (error) {
            corruptLines++;
          }
        }
      } catch (error) {
        out['readFailed'] = true;
      }
    }
    out['records'] = records;
    out['first'] = oldest;
    out['last'] = newest;
    out['count'] = records.length;
    out['retentionHours'] = 48;
    out['capacityBytes'] = CAPACITY_BYTES;
    out['segmentBytes'] = SEGMENT_BYTES;
    out['missing'] = foundFiles === 0;
    out['corruptLines'] = corruptLines;
    out['expiredLines'] = expiredLines;
    if (RuntimeJournal.failedWrites[context.filesDir] === true) out['writeFailedCurrentProcess'] = true;
    out['writeFailureVisibility'] = 'current-process-only';
    out['writeFailureCoverage'] = 'prior-process-failures-unknown';
    out['capacityMayEvictEarly'] = true;
    return out;
  }

  private static baseRecord(status: Record<string, Object>, native: Record<string, Object>, includeAt: boolean = true): Record<string, Object> {
    const record: Record<string, Object> = {};
    if (includeAt) record['at'] = Date.now();
    const generation = status['generation'];
    if (typeof generation === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(generation)) record['generation'] = generation;
    const phase = status['phase'];
    if (typeof phase === 'string' && PHASES.indexOf(phase) >= 0) record['phase'] = phase;
    RuntimeJournal.copyNumber(record, status, 'sessionRevision');
    RuntimeJournal.copyAllowed(record, status, STATUS_BOOLEANS, STATUS_NUMBERS, 's.');
    const digest = status['payloadDigest'];
    if (typeof digest === 'string' && /^[A-Fa-f0-9]{8,128}$/.test(digest)) record['payloadDigest'] = digest;
    RuntimeJournal.copyAllowed(record, native, NATIVE_BOOLEANS, NATIVE_NUMBERS, 'n.');
    const hev = RuntimeJournal.parseHev(native['hevDiagnostics']);
    if (!RuntimeJournal.validHev(native['hevDiagnostics'])) record['n.hevDiagnosticsMissing'] = true;
    RuntimeJournal.copySignedNumbers(record, hev, HEV_NUMBERS, 'n.hev.');
    const tunCounts = hev['tunCounts'];
    if (tunCounts instanceof Array && tunCounts.length === 13) {
      const safe: Array<number> = [];
      for (let i = 0; i < tunCounts.length; i++) {
        if (typeof tunCounts[i] !== 'number' || !isFinite(tunCounts[i] as number) || (tunCounts[i] as number) < 0) break;
        safe.push(tunCounts[i] as number);
      }
      if (safe.length === 13) record['n.tunCounts'] = safe;
    }
    const appRouting = native['appRouting'];
    if (appRouting !== null && typeof appRouting === 'object') {
      RuntimeJournal.copyAllowed(record, appRouting as Record<string, Object>, ROUTING_BOOLEANS, ROUTING_NUMBERS, 'n.appRouting.');
    }
    const protect = native['protectDiagnostics'];
    if (protect !== null && typeof protect === 'object') {
      RuntimeJournal.copySignedNumbers(record, protect as Record<string, Object>, PROTECT_NUMBERS, 'n.protectDiagnostics.');
    }
    return record;
  }

  private static copyExtra(record: Record<string, Object>, extra: Record<string, Object>): void {
    RuntimeJournal.copyAllowed(record, extra, EXTRA_BOOLEANS, EXTRA_NUMBERS, 'x.');
    const outcome = extra['outcome'];
    if (typeof outcome === 'string' && EXTRA_ENUMS.indexOf(outcome) >= 0) record['x.outcome'] = outcome;
    const reason = extra['reason'];
    if (typeof reason === 'string' && EXTRA_ENUMS.indexOf(reason) >= 0) record['x.reason'] = reason;
    const net = extra['net'];
    if (typeof net === 'string' && EXTRA_ENUMS.indexOf(net) >= 0) record['x.net'] = net;
  }

  private static copyAllowed(record: Record<string, Object>, source: Record<string, Object>, booleans: Array<string>, numbers: Array<string>, prefix: string): void {
    for (let i = 0; i < booleans.length; i++) {
      const value = source[booleans[i]];
      if (typeof value === 'boolean') record[`${prefix}${booleans[i]}`] = value;
    }
    for (let i = 0; i < numbers.length; i++) {
      const value = source[numbers[i]];
      if (typeof value === 'number' && isFinite(value) && value >= 0) record[`${prefix}${numbers[i]}`] = value;
    }
  }

  private static copyNumber(record: Record<string, Object>, source: Record<string, Object>, key: string): void {
    const value = source[key];
    if (typeof value === 'number' && isFinite(value) && value >= 0) record[key] = value;
  }

  private static copySignedNumbers(record: Record<string, Object>, source: Record<string, Object>, keys: Array<string>, prefix: string): void {
    for (let i = 0; i < keys.length; i++) {
      const value = source[keys[i]];
      if (typeof value === 'number' && isFinite(value)) record[`${prefix}${keys[i]}`] = value;
    }
  }

  private static append(context: common.Context, record: Record<string, Object>): void {
    // A leading delimiter also isolates a prior crash's partial trailing line.
    const text = '\n' + JSON.stringify(record) + '\n';
    if (text.length > MAX_LINE_BYTES) return;
    RuntimeJournal.expireWholeSegments(context, false);
    const active = RuntimeJournal.path(context, JOURNAL_FILES[0]);
    const size = fs.accessSync(active) ? fs.statSync(active).size : 0;
    if (size > 0 && size + text.length > SEGMENT_BYTES) RuntimeJournal.rotate(context);
    const file = fs.openSync(active, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    try { fs.writeSync(file.fd, text); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
  }

  private static rotate(context: common.Context): void {
    RuntimeJournal.expireWholeSegments(context, true);
    try { const oldest = RuntimeJournal.path(context, JOURNAL_FILES[3]); if (fs.accessSync(oldest)) fs.unlinkSync(oldest); } catch (error) {}
    for (let i = JOURNAL_FILES.length - 2; i >= 0; i--) {
      const from = RuntimeJournal.path(context, JOURNAL_FILES[i]);
      const to = RuntimeJournal.path(context, JOURNAL_FILES[i + 1]);
      if (fs.accessSync(from)) fs.renameSync(from, to);
    }
  }

  private static expireWholeSegments(context: common.Context, force: boolean): void {
    const key = context.filesDir;
    if (!force && RuntimeJournal.lastCleanupAt[key] !== undefined && Date.now() - RuntimeJournal.lastCleanupAt[key] < 60 * 60 * 1000) return;
    RuntimeJournal.lastCleanupAt[key] = Date.now();
    const cutoff = Date.now() - RETENTION_MS;
    for (let i = 0; i < JOURNAL_FILES.length; i++) {
      const path = RuntimeJournal.path(context, JOURNAL_FILES[i]);
      try {
        if (!fs.accessSync(path)) continue;
        const lines = fs.readTextSync(path).split('\n');
        let newest = 0;
        for (let p = 0; p < lines.length; p++) {
          try { const item = JSON.parse(lines[p]) as Record<string, Object>; const at = item['at']; if (typeof at === 'number' && at > newest) newest = at; } catch (error) {}
        }
        if (newest > 0 && newest < cutoff) fs.unlinkSync(path);
      } catch (error) {
        // Retention cleanup is best effort; it must not break the VPN writer.
      }
    }
  }

  private static parseHev(value: Object): Record<string, Object> {
    if (typeof value !== 'string' || value.length > MAX_LINE_BYTES) return {};
    try { const parsed = JSON.parse(value) as Object; return parsed !== null && typeof parsed === 'object' && !(parsed instanceof Array) ? parsed as Record<string, Object> : {}; } catch (error) { return {}; }
  }

  private static validHev(value: Object): boolean {
    if (typeof value !== 'string' || value.length > MAX_LINE_BYTES) return false;
    try { const parsed = JSON.parse(value) as Object; return parsed !== null && typeof parsed === 'object' && !(parsed instanceof Array); } catch (error) { return false; }
  }

  private static criticalFingerprint(status: Record<string, Object>, native: Record<string, Object>): Record<string, Object> {
    const all = RuntimeJournal.snapshot(status, native);
    const out: Record<string, Object> = {};
    const keys = Object.keys(all);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      if (key === 'generation' || key === 'phase' || key === 'sessionRevision' || key.indexOf('s.') === 0 && typeof all[key] === 'boolean' ||
        key === 'n.xrayRunning' || key === 'n.tunRunning' || key === 'n.poisoned' || key === 'n.protectTimeout' ||
        key === 'n.protectDiagnostics.invalid' || key === 'n.protectDiagnostics.unavailable' || key === 'n.protectDiagnostics.claimRejected' ||
        key === 'n.protectDiagnostics.apiRejected' || key === 'n.hev.rxErrors' || key === 'n.hev.controlErrors' ||
        key === 'n.hev.pollErrors' || key === 'n.hev.lastRxErrno' || key === 'n.hev.lastControlErrno' ||
        key === 'n.appRouting.rejected' || key === 'n.appRouting.ownerQueryFailed' || key === 'n.appRouting.identityMismatch' ||
        key === 'n.appRouting.overloaded' || key === 'n.appRouting.inactive' || key === 'n.appRouting.ackFailed') out[key] = all[key];
    }
    return out;
  }

  private static filterDiskRecord(item: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    const at = item['at']; if (typeof at === 'number' && isFinite(at)) out['at'] = at;
    const generation = item['generation']; if (typeof generation === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(generation)) out['generation'] = generation;
    const phase = item['phase']; if (typeof phase === 'string' && PHASES.indexOf(phase) >= 0) out['phase'] = phase;
    RuntimeJournal.copyNumber(out, item, 'sessionRevision');
    const kind = item['kind']; if (typeof kind === 'string' && EVENT_KINDS.indexOf(kind) >= 0) out['kind'] = kind;
    const permitted = STATUS_BOOLEANS.map(k => `s.${k}`).concat(STATUS_NUMBERS.map(k => `s.${k}`), NATIVE_BOOLEANS.map(k => `n.${k}`), NATIVE_NUMBERS.map(k => `n.${k}`), HEV_NUMBERS.map(k => `n.hev.${k}`), ['n.hevDiagnosticsMissing'], ROUTING_BOOLEANS.map(k => `n.appRouting.${k}`), ROUTING_NUMBERS.map(k => `n.appRouting.${k}`), PROTECT_NUMBERS.map(k => `n.protectDiagnostics.${k}`), EXTRA_BOOLEANS.map(k => `x.${k}`), EXTRA_NUMBERS.map(k => `x.${k}`));
    for (let i = 0; i < permitted.length; i++) { const value = item[permitted[i]]; if ((typeof value === 'boolean') || (typeof value === 'number' && isFinite(value))) out[permitted[i]] = value; }
    const digest = item['payloadDigest']; if (typeof digest === 'string' && /^[A-Fa-f0-9]{8,128}$/.test(digest)) out['payloadDigest'] = digest;
    for (let i = 0; i < 3; i++) { const key = i === 0 ? 'x.outcome' : i === 1 ? 'x.reason' : 'x.net'; const value = item[key]; if (typeof value === 'string' && EXTRA_ENUMS.indexOf(value) >= 0) out[key] = value; }
    const counts = item['n.tunCounts']; if (counts instanceof Array && counts.length === 13) { let okay = true; for (let i = 0; i < counts.length; i++) if (typeof counts[i] !== 'number' || !isFinite(counts[i] as number) || (counts[i] as number) < 0) okay = false; if (okay) out['n.tunCounts'] = counts; }
    return out;
  }

  private static path(context: common.Context, name: string): string { return `${context.filesDir}/${name}`; }
}
