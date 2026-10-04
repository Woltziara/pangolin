import { common } from '@kit.AbilityKit';
import { StatusStore } from './StatusStore';
const FILE: string = 'recovery-revocations-v1.json';
export class Revocations {
  static keys(context: common.Context, authorizedRevision: number = 0): string[] {
    const raw = StatusStore.readStrictText(context, FILE);
    if (raw.length === 0) return [];
    const doc = JSON.parse(raw) as Record<string, Object>;
    if (doc['v'] !== 1 || !Array.isArray(doc['keys'])) throw new Error('无法核验节点撤销记录，未重连旧快照。');
    const keys = doc['keys'] as Object[];
    if (!keys.every((key: Object) => typeof key === 'string')) throw new Error('节点撤销记录损坏');
    const revisions = typeof doc['revisions'] === 'object' && doc['revisions'] !== null ? doc['revisions'] as Record<string, Object> : JSON.parse('{}') as Record<string, Object>;
    return (keys as string[]).filter((key: string) => typeof revisions[key] !== 'number' || (revisions[key] as number) > authorizedRevision);
  }
  static revision(context: common.Context): number {
    const raw = StatusStore.readStrictText(context, FILE);
    if (raw.length === 0) return 0;
    const doc = JSON.parse(raw) as Record<string, Object>;
    if (doc['v'] !== 1 || !Array.isArray(doc['keys'])) throw new Error('节点撤销记录损坏');
    return typeof doc['revision'] === 'number' && Number.isSafeInteger(doc['revision']) && (doc['revision'] as number) >= 0 ? doc['revision'] as number : 1;
  }
  static revoke(context: common.Context, keys: string[]): void {
    for (let attempt = 0; attempt < 3; attempt++) {
      const before = StatusStore.readStrictText(context, FILE);
      const next = Array.from(new Set<string>(Revocations.keys(context).concat(keys)));
      const previous = JSON.parse(before || '{}') as Record<string, Object>;
      const revision = Revocations.revision(context) + 1;
      const revisions = typeof previous['revisions'] === 'object' && previous['revisions'] !== null ? previous['revisions'] as Record<string, Object> : JSON.parse('{}') as Record<string, Object>;
      keys.forEach((key: string) => { revisions[key] = revision; });
      const doc: Record<string, Object> = { 'v': 1, 'keys': next, 'revision': revision, 'revisions': revisions };
      if (StatusStore.compareText(context, FILE, before, JSON.stringify(doc))) return;
    }
    throw new Error('节点撤销记录并发变化，请重试。');
  }
}
