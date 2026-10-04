import { common } from '@kit.AbilityKit';
import { DataplaneStatus } from '../net/DataplaneStatus';
import { SettingsStore } from './SettingsStore';
import { StatusStore } from './StatusStore';

export const EVENTS_FILE: string = 'dataplane-events.jsonl';
export const EVENT_HEAD_FILE: string = 'dataplane-event-head.json';
export const EVENT_SNAPSHOT_FILE: string = 'dataplane-event-snapshot.json';
const MAX_EVENTS: number = 400;

class EventLedger {
  generation: string = '';
  sessionRevision: number = 0;
  seq: number = 0;
  windowStartSeq: number = 0;
  events: Array<Record<string, Object>> = [];
}

export class EventStore {
  /**
   * Phase D：窗口上限可选。keepCount <= 0 时读 settings.json 的 eventKeepCount
   * （诊断信息保留档位）；设置缺失/缺省时回退 MAX_EVENTS=400，与 Phase D 之前
   * 的行为逐字节一致。
   */
  static keepLimit(context: common.Context, keepCount: number = 0): number {
    if (keepCount > 0) {
      return keepCount;
    }
    try {
      const configured = SettingsStore.load(context).eventKeepCount;
      if (configured > 0) {
        return configured;
      }
    } catch (error) {
      // settings unreadable → default
    }
    return MAX_EVENTS;
  }

  static append(context: common.Context, kind: string, status: DataplaneStatus,
    extra: Record<string, Object>, keepCount: number = 0): void {
    const ledger = EventStore.load(context);
    if (ledger.seq < 0) {
      throw new Error('event snapshot corrupt; refuse seq reuse');
    }
    if (ledger.generation.length > 0 && ledger.generation !== status.generation) {
      ledger.generation = status.generation;
      ledger.sessionRevision = status.sessionRevision;
      ledger.seq = 0;
      ledger.windowStartSeq = 0;
      ledger.events = [];
    }
    if (ledger.generation.length === 0) {
      ledger.generation = status.generation;
    }
    if (ledger.generation.length === 0 || status.generation.length === 0) {
      throw new Error('event generation missing');
    }
    if (status.sessionRevision < 1) {
      throw new Error('event revision missing');
    }
    const atNow = Date.now();
    if (ledger.events.length > 0) {
      const prevAt = ledger.events[ledger.events.length - 1]['at'];
      if (typeof prevAt === 'number' && atNow < prevAt) {
        throw new Error('event at rewind');
      }
    }
    ledger.sessionRevision = status.sessionRevision;
    ledger.seq += 1;
    const record: Record<string, Object> = {};
    record['seq'] = ledger.seq;
    record['at'] = atNow;
    record['kind'] = kind;
    record['sessionId'] = status.sessionId;
    record['generation'] = status.generation;
    record['sessionRevision'] = status.sessionRevision;
    record['phase'] = status.phase;
    record['tunRxBytes'] = status.tunRxBytes;
    record['tunTxBytes'] = status.tunTxBytes;
    record['hevUpload'] = status.uploadBytes;
    record['hevDownload'] = status.downloadBytes;
    record['directOk'] = status.directOk;
    record['proxyOk'] = status.proxyOk;
    record['forwarderOk'] = status.forwarderOk;
    record['canaryOk'] = status.canaryOk;
    record['reconnectCount'] = status.reconnectCount;
    const keys = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      record[keys[i]] = extra[keys[i]];
    }
    record['at'] = atNow;
    record['generation'] = status.generation;
    record['sessionRevision'] = status.sessionRevision;
    if (status.phase.length > 0) {
      record['phase'] = status.phase;
    }
    ledger.events.push(record);
    const limit = EventStore.keepLimit(context, keepCount);
    if (ledger.events.length > limit) {
      const keep = ledger.events.slice(ledger.events.length - limit);
      ledger.events = keep;
    }
    if (ledger.events.length > 0) {
      const first = ledger.events[0]['seq'];
      if (typeof first === 'number') {
        ledger.windowStartSeq = first;
      }
      const last = ledger.events[ledger.events.length - 1]['seq'];
      if (typeof last !== 'number' || last !== ledger.seq) {
        throw new Error('event window seq discontinuity');
      }
      if (ledger.events.length > 1) {
        const expected = ledger.windowStartSeq + ledger.events.length - 1;
        if (expected !== ledger.seq) {
          throw new Error('event rolling window gap');
        }
      }
    }
    EventStore.save(context, ledger);
  }

  static load(context: common.Context): EventLedger {
    const ledger = new EventLedger();
    const path = `${context.filesDir}/${EVENT_SNAPSHOT_FILE}`;
    const raw = StatusStore.recoverCanonical(path);
    if (raw.length < 8) {
      if (StatusStore.destExistsNonempty(path)) {
        const broken = new EventLedger();
        broken.seq = -1;
        return broken;
      }
      return ledger;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const seq = parsed['seq'];
      if (typeof seq !== 'number') {
        const broken = new EventLedger();
        broken.seq = -1;
        return broken;
      }
      const gen = parsed['generation'];
      if (typeof gen === 'string') {
        ledger.generation = gen;
      }
      if (seq > 0 && ledger.generation.length === 0) {
        const broken = new EventLedger();
        broken.seq = -1;
        return broken;
      }
      const rev = parsed['sessionRevision'];
      if (typeof rev === 'number') {
        ledger.sessionRevision = rev;
      }
      ledger.seq = seq;
      const windowStart = parsed['windowStartSeq'];
      if (typeof windowStart === 'number') {
        ledger.windowStartSeq = windowStart;
      }
      const events = parsed['events'];
      if (events instanceof Array) {
        ledger.events = events as Array<Record<string, Object>>;
      }
      if (seq > 0 && (!(events instanceof Array) || ledger.events.length === 0)) {
        const broken = new EventLedger();
        broken.seq = -1;
        return broken;
      }
      if (ledger.events.length > 0) {
        const first = ledger.events[0]['seq'];
        const last = ledger.events[ledger.events.length - 1]['seq'];
        if (typeof first !== 'number' || typeof last !== 'number' || last !== ledger.seq) {
          const broken = new EventLedger();
          broken.seq = -1;
          return broken;
        }
        if (first + ledger.events.length - 1 !== last) {
          const broken = new EventLedger();
          broken.seq = -1;
          return broken;
        }
        let prevRev = -1;
        for (let i = 0; i < ledger.events.length; i++) {
          const rec = ledger.events[i];
          const kind = rec['kind'];
          const eg = rec['generation'];
          const er = rec['sessionRevision'];
          const es = rec['seq'];
          if (typeof kind !== 'string' || kind.length === 0) {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          if (typeof es !== 'number') {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          if (typeof eg === 'string' && eg.length > 0 && eg !== ledger.generation) {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          if (typeof er !== 'number') {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          const at = rec['at'];
          const phase = rec['phase'];
          if (typeof at !== 'number' || at < 1) {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          if (typeof phase !== 'string' || phase.length < 1) {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          if (i > 0) {
            const prevSeq = ledger.events[i - 1]['seq'];
            if (typeof prevSeq !== 'number' || es !== prevSeq + 1) {
              const broken = new EventLedger();
              broken.seq = -1;
              return broken;
            }
          }
          if (prevRev >= 0 && er < prevRev) {
            const broken = new EventLedger();
            broken.seq = -1;
            return broken;
          }
          prevRev = er;
        }
        const lastRev = ledger.events[ledger.events.length - 1]['sessionRevision'];
        if (typeof lastRev === 'number') {
          ledger.sessionRevision = lastRev;
        }
        ledger.windowStartSeq = first;
      }
    } catch (error) {
      const broken = new EventLedger();
      broken.seq = -1;
      return broken;
    }
    return ledger;
  }

  static save(context: common.Context, ledger: EventLedger): void {
    const doc: Record<string, Object> = {};
    doc['generation'] = ledger.generation;
    doc['sessionRevision'] = ledger.sessionRevision;
    doc['seq'] = ledger.seq;
    doc['windowStartSeq'] = ledger.windowStartSeq;
    doc['events'] = ledger.events;
    StatusStore.writeText(context, EVENT_SNAPSHOT_FILE, JSON.stringify(doc));
  }
}
