import { systemBootId } from '../native/TunnelNative';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { StatusStore } from './StatusStore';
import { deadline } from './AsyncDeadline';

export const PLATFORM_OPERATIONS_FILE: string = 'platform-operations-v2.json';
export class PlatformOperation {
  bootId: string = ''; operationId: string = '';
  id: string = ''; kind: string = ''; generation: string = ''; controller: string = '';
  state: string = 'pending'; startedAt: number = 0; finishedAt: number = 0;
}
/** One UI controller instance writes this ledger. Delayed callbacks update only their exact op.
 * A foreign unresolved system-stop is NEVER erased because a timeout/empty process was observed. */
export class PlatformOperations {
  readonly instance: string = util.generateRandomUUID();
  private pending: number = 0;
  private read(context: common.Context): PlatformOperation[] {
    const raw = StatusStore.readStrictText(context, PLATFORM_OPERATIONS_FILE);
    if (raw.length === 0) return [];
    const doc = JSON.parse(raw) as Record<string, Object>;
    if (doc['schema'] !== 2 || !Array.isArray(doc['operations'])) throw new Error('系统操作账本无法核验');
    return this.validate(doc['operations']);
  }
  private validate(value: Object): PlatformOperation[] {
    if (!Array.isArray(value) || value.length > 64) throw new Error('系统操作账本结构损坏');
    const rows = value as PlatformOperation[];
    const ids = new Set<string>();
    rows.forEach((row: PlatformOperation) => {
      if (row === null || typeof row !== 'object' || typeof row.id !== 'string' || row.id.length === 0 || ids.has(row.id) ||
        typeof row.controller !== 'string' || row.controller.length === 0 || typeof row.generation !== 'string' ||
        ['start','owner-stop','system-stop','diagnostic'].indexOf(row.kind) < 0 ||
        ['pending','completed','rejected','ended-by-system-reboot'].indexOf(row.state) < 0 ||
        typeof row.startedAt !== 'number' || !Number.isFinite(row.startedAt)) throw new Error('系统操作账本记录损坏');
      ids.add(row.id);
    });
    return rows;
  }
  completedControl(context: common.Context, id: string): boolean {
    if (id.length === 0) return false;
    const rows = this.read(context).filter((row: PlatformOperation) => row.operationId === id);
    return rows.length > 0 && rows.some((row: PlatformOperation) => row.kind === 'system-stop' && row.state === 'completed') &&
      rows.every((row: PlatformOperation) => row.state !== 'pending');
  }
  private update(context: common.Context, op: PlatformOperation, begin: boolean): void {
    for (let attempt = 0; attempt < 3; attempt++) {
      const before = StatusStore.readStrictText(context, PLATFORM_OPERATIONS_FILE);
      let rows: PlatformOperation[] = [];
      if (before.length > 0) {
        const doc = JSON.parse(before) as Record<string, Object>;
        if (doc['schema'] !== 2 || !Array.isArray(doc['operations'])) throw new Error('系统操作账本无法核验');
        rows = this.validate(doc['operations']);
      }
      const index = rows.findIndex((row: PlatformOperation) => row.id === op.id);
      if (begin) {
        if (rows.filter((row: PlatformOperation) => row.state === 'pending').length >= 8) throw new Error('未决系统操作过多，请完成系统处理。');
        rows.push(op);
      } else {
        if (index < 0 || rows[index].controller !== this.instance) return;
        rows[index] = op;
      }
      const waiting = rows.filter((row: PlatformOperation) => row.state === 'pending');
      const done = rows.filter((row: PlatformOperation) => row.state !== 'pending')
        .sort((a: PlatformOperation, b: PlatformOperation) => a.finishedAt - b.finishedAt).slice(-16);
      const record: Record<string, Object> = { 'schema': 2, 'operations': waiting.concat(done) };
      if (StatusStore.compareText(context, PLATFORM_OPERATIONS_FILE, before, JSON.stringify(record))) return;
    }
    throw new Error('系统操作账本并发变化，未覆盖');
  }
  unresolvedStop(context: common.Context): boolean {
    return this.read(context).some((row: PlatformOperation) => row.kind === 'system-stop' && row.state === 'pending');
  }
  requireSettled(context: common.Context): string {
    if (StatusStore.readStrictText(context, PLATFORM_OPERATIONS_FILE).length === 0) {
      throw new Error('系统操作记录缺失，未解除连接保护');
    }
    if (this.pending > 0 || this.read(context).some((row: PlatformOperation) => row.state === 'pending')) {
      throw new Error('上一次系统操作还未结束，请稍后重试');
    }
    return StatusStore.readStrictText(context, PLATFORM_OPERATIONS_FILE);
  }
  retireBeforeBoot(context: common.Context, boot: string): void {
    if (boot.length === 0) return;
    const before = StatusStore.readStrictText(context, PLATFORM_OPERATIONS_FILE);
    if (before.length === 0) return;
    const rows = this.read(context);
    rows.forEach((row: PlatformOperation) => {
      if (typeof row.bootId === 'string' && row.bootId.length > 0 && row.bootId !== boot && row.state === 'pending') {
        row.state = 'ended-by-system-reboot'; row.finishedAt = Date.now();
      }
    });
    const record: Record<string, Object> = { 'schema': 2, 'operations': rows };
    if (!StatusStore.compareText(context, PLATFORM_OPERATIONS_FILE, before, JSON.stringify(record))) throw new Error('重启核验期间操作记录变化');
  }
  inFlight(): number { return this.pending; }
  async run(context: common.Context, kind: string, generation: string, action: () => Promise<void>,
    budget: number, settled: () => void = (): void => {}): Promise<void> {
    const op = new PlatformOperation(); op.id = util.generateRandomUUID(); op.kind = kind;
    try { op.bootId = systemBootId(); } catch (_error) {}
    const control = JSON.parse(StatusStore.readStrictText(context, 'connection-control.json') || '{}') as Record<string, Object>;
    op.operationId = typeof control['operationId'] === 'string' ? control['operationId'] as string : '';
    op.generation = generation; op.controller = this.instance; op.startedAt = Date.now();
    this.update(context, op, true); // write BEFORE side effects
    this.pending += 1;
    const actual = Promise.resolve().then(action);
    const tracked = actual.then(() => {
      this.pending -= 1; op.state = 'completed'; op.finishedAt = Date.now();
      this.update(context, op, false); settled();
    }, (error: Object) => {
      this.pending -= 1; op.state = 'rejected'; op.finishedAt = Date.now();
      this.update(context, op, false); settled(); throw error as Error;
    });
    await deadline(tracked, budget, '系统操作尚未返回；继续保留真实回执责任');
  }
}
