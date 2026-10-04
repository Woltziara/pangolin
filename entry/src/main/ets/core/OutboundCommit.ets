// 运行配置提交合同：同一修订绑定 payload、选择 meta 与 applied policy。
// 新配置包装失败时明确拒绝应用，上一版可恢复，不得把旧密文伪装成新选择。

export const COMMIT_FILE: string = 'outbound-commit.json';
export const PREV_COMMIT_FILE: string = 'outbound-commit.json.prev';
export const COMMIT_NEXT_FILE: string = 'outbound-commit.json.next';
export const META_FILE: string = 'node-meta.json';
export const META_STAGING_FILE: string = 'node-meta.json.staging';
export const PREV_META_FILE: string = 'node-meta.json.prev';
export const ENVELOPE_FILE: string = 'outbound.json.huks';
export const PREV_ENVELOPE_FILE: string = 'outbound.json.huks.prev';
export const ENVELOPE_NEXT_FILE: string = 'outbound.json.huks.next';
export const OUTBOUND_PLAIN_FILE: string = 'outbound.json';
export const APPLIED_FILE: string = 'outbound-applied.json';
export const PREV_APPLIED_FILE: string = 'outbound-applied.json.prev';
export const NEW_CONFIG_NOT_APPLIED: string = '新配置未应用，上一版仍可恢复';
export const NEW_CONFIG_REJECTED: string = '新配置未应用';
export const STAGING_CLEANUP_WARNING: string = '新配置已应用，暂存清理未完成';
export const HUKS_UNAVAILABLE: string = '节点加密不可用，新配置未应用';
export const RUNNING_DIGEST_FILE: string = 'running-payload-digest.json';

export function digestText(text: string): string {
  let hash = 2166136261;
  for (let i = 0; i < text.length; i++) {
    hash = (hash ^ text.charCodeAt(i)) * 16777619;
    hash = hash >>> 0;
  }
  return hash.toString(16);
}

export function makeCommit(payload: string, meta: string, channelMode: string, singleNodeId: string,
  chatgptNodeId: string, generalNodeId: string, revision: number, at: number): Record<string, Object> {
  const rec: Record<string, Object> = {};
  rec['v'] = 1;
  rec['revision'] = revision;
  rec['payloadDigest'] = digestText(payload);
  rec['metaDigest'] = digestText(meta);
  rec['channelMode'] = channelMode;
  rec['singleNodeId'] = singleNodeId;
  rec['chatgptNodeId'] = chatgptNodeId;
  rec['generalNodeId'] = generalNodeId;
  rec['at'] = at;
  rec['status'] = 'applied';
  return rec;
}

export class CommitDecision {
  applied: boolean = false;
  keepPrevious: boolean = false;
  snapshotPrevious: boolean = false;
  payload: string = '';
  meta: string = '';
  error: string = '';
}

export function decideProtect(wrapOk: boolean, huksAvailable: boolean, newPayload: string, newMeta: string,
  previousPayload: string, previousMeta: string): CommitDecision {
  const out = new CommitDecision();
  if (newPayload.length < 20) {
    out.keepPrevious = previousPayload.length >= 20;
    out.payload = previousPayload;
    out.meta = previousMeta;
    out.error = '节点配置不完整';
    return out;
  }
  if (!huksAvailable) {
    out.keepPrevious = previousPayload.length >= 20;
    out.payload = previousPayload;
    out.meta = previousMeta;
    out.error = HUKS_UNAVAILABLE;
    return out;
  }
  if (!wrapOk) {
    out.keepPrevious = true;
    out.payload = previousPayload;
    out.meta = previousMeta;
    out.error = NEW_CONFIG_NOT_APPLIED;
    return out;
  }
  out.applied = true;
  out.snapshotPrevious = previousPayload.length >= 20;
  out.payload = newPayload;
  out.meta = newMeta.length > 2 ? newMeta : previousMeta;
  return out;
}

export interface CommitFileOps {
  read(name: string): string;
  write(name: string, text: string): void;
  remove(name: string): void;
}

export class MemoryCommitFiles {
  data: Record<string, string> = {};
  failAt: string = '';
  failAlso: string[] = [];
  writes: string[] = [];

  read(name: string): string {
    const keys = Object.keys(this.data);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === name) {
        return this.data[name];
      }
    }
    return '';
  }

  matchesFail(op: string): boolean {
    if (this.failAt.length > 0 && this.failAt === op) {
      return true;
    }
    for (let i = 0; i < this.failAlso.length; i++) {
      if (this.failAlso[i] === op) {
        return true;
      }
    }
    return false;
  }

  write(name: string, text: string): void {
    this.writes.push(name);
    if (this.matchesFail(name)) {
      throw new Error(`inject:${name}`);
    }
    const next: Record<string, string> = {};
    const keys = Object.keys(this.data);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.data[keys[i]];
    }
    next[name] = text;
    this.data = next;
  }

  remove(name: string): void {
    this.writes.push(`remove:${name}`);
    if (this.matchesFail(`remove:${name}`)) {
      throw new Error(`inject:remove:${name}`);
    }
    const next: Record<string, string> = {};
    const keys = Object.keys(this.data);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== name) {
        next[keys[i]] = this.data[keys[i]];
      }
    }
    this.data = next;
  }
}

function writeBestEffort(files: CommitFileOps, name: string, text: string): boolean {
  try {
    files.write(name, text);
    return true;
  } catch (error) {
    return files.read(name) === text;
  }
}

function removeBestEffort(files: CommitFileOps, name: string): void {
  try {
    files.remove(name);
  } catch (error) {
  }
}

function packJson(envelope: string, meta: string, commit: string): string {
  const rec: Record<string, Object> = {};
  rec['v'] = 2;
  rec['envelope'] = envelope;
  rec['meta'] = meta;
  rec['commit'] = commit;
  return JSON.stringify(rec);
}

function parsePack(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  out['envelope'] = '';
  out['meta'] = '';
  out['commit'] = '';
  out['source'] = '';
  if (raw.length < 8) {
    return out;
  }
  try {
    const rec = JSON.parse(raw) as Record<string, Object>;
    const envelope = rec['envelope'];
    const meta = rec['meta'];
    const commit = rec['commit'];
    out['envelope'] = typeof envelope === 'string' ? envelope : '';
    out['meta'] = typeof meta === 'string' ? meta : '';
    out['commit'] = typeof commit === 'string' ? commit : '';
    if (out['envelope'].length > 20) {
      out['source'] = 'pack';
    }
  } catch (error) {
    return out;
  }
  return out;
}

function loadLegacyPack(files: CommitFileOps): Record<string, string> {
  const out: Record<string, string> = {};
  out['envelope'] = files.read(ENVELOPE_FILE);
  out['meta'] = files.read(META_FILE);
  out['commit'] = files.read(COMMIT_FILE);
  out['source'] = 'legacy';
  return out;
}

function loadAppliedPack(files: CommitFileOps): Record<string, string> {
  const packed = parsePack(files.read(APPLIED_FILE));
  if (packed['envelope'].length > 20) {
    return packed;
  }
  const prev = loadPrevPack(files);
  if (prev['envelope'].length > 20) {
    const empty: Record<string, string> = {};
    empty['envelope'] = '';
    empty['meta'] = '';
    empty['commit'] = '';
    empty['source'] = '';
    return empty;
  }
  return loadLegacyPack(files);
}

function loadPrevPack(files: CommitFileOps): Record<string, string> {
  const packed = parsePack(files.read(PREV_APPLIED_FILE));
  if (packed['envelope'].length > 20) {
    return packed;
  }
  const out: Record<string, string> = {};
  out['envelope'] = files.read(PREV_ENVELOPE_FILE);
  out['meta'] = files.read(PREV_META_FILE);
  out['commit'] = files.read(PREV_COMMIT_FILE);
  out['source'] = out['envelope'].length > 20 ? 'pack' : '';
  return out;
}

function packPlain(pack: Record<string, string>, unwrap: (envelope: string) => string): string {
  if (pack['envelope'].length > 20) {
    return unwrap(pack['envelope']);
  }
  return '';
}

function isDirtyApply(files: CommitFileOps): boolean {
  return files.read(COMMIT_NEXT_FILE).length > 0 || files.read(ENVELOPE_NEXT_FILE).length > 0;
}

function packUsable(pack: Record<string, string>, unwrap: (envelope: string) => string): boolean {
  const plain = packPlain(pack, unwrap);
  if (plain.length < 20) {
    return false;
  }
  if (pack['commit'].length >= 8) {
    return verifyAppliedRead(plain, pack['commit'], pack['meta']).length === 0;
  }
  return pack['source'] === 'pack';
}

function snapshotPrevPack(files: CommitFileOps, pack: Record<string, string>): void {
  files.write(PREV_APPLIED_FILE, packJson(pack['envelope'], pack['meta'], pack['commit']));
  if (pack['envelope'].length > 20) {
    files.write(PREV_ENVELOPE_FILE, pack['envelope']);
  }
  if (pack['meta'].length > 2) {
    files.write(PREV_META_FILE, pack['meta']);
  }
  if (pack['commit'].length >= 8) {
    files.write(PREV_COMMIT_FILE, pack['commit']);
  }
}

function projectPack(files: CommitFileOps, pack: Record<string, string>): void {
  writeBestEffort(files, ENVELOPE_FILE, pack['envelope']);
  if (pack['meta'].length > 2) {
    writeBestEffort(files, META_FILE, pack['meta']);
  }
  if (pack['commit'].length >= 8) {
    writeBestEffort(files, COMMIT_FILE, pack['commit']);
  } else {
    removeBestEffort(files, COMMIT_FILE);
  }
  writeBestEffort(files, APPLIED_FILE, packJson(pack['envelope'], pack['meta'], pack['commit']));
  removeBestEffort(files, ENVELOPE_NEXT_FILE);
  removeBestEffort(files, COMMIT_NEXT_FILE);
  removeBestEffort(files, META_STAGING_FILE);
  removeBestEffort(files, OUTBOUND_PLAIN_FILE);
}

function packFingerprint(pack: Record<string, string>): string {
  return `${pack['envelope']}\n${pack['meta']}\n${pack['commit']}`;
}

export function restorePreviousCommit(files: CommitFileOps): boolean {
  const prev = loadPrevPack(files);
  if (prev['envelope'].length < 20) {
    return false;
  }
  const expected = packFingerprint(prev);
  projectPack(files, prev);
  const applied = parsePack(files.read(APPLIED_FILE));
  return applied['envelope'].length >= 20 && packFingerprint(applied) === expected;
}

export function applyNewCommit(files: CommitFileOps, newPlain: string, newMeta: string, newEnvelope: string,
  huksAvailable: boolean, wrapOk: boolean): string {
  const current = loadAppliedPack(files);
  const hadPrevious = current['envelope'].length > 20;
  const decision = decideProtect(wrapOk, huksAvailable, newPlain, newMeta, current['envelope'], current['meta']);
  if (!decision.applied) {
    removeBestEffort(files, OUTBOUND_PLAIN_FILE);
    removeBestEffort(files, META_STAGING_FILE);
    return hadPrevious ? decision.error : NEW_CONFIG_REJECTED;
  }
  if (hadPrevious) {
    snapshotPrevPack(files, current);
    if (files.read(APPLIED_FILE).length < 8) {
      writeBestEffort(files, APPLIED_FILE, packJson(current['envelope'], current['meta'], current['commit']));
    }
  }
  const commit = makeCommit(newPlain, decision.meta, '', '', '', '', nextRevision(current['commit']), 1);
  const commitJson = JSON.stringify(commit);
  try {
    files.write(COMMIT_NEXT_FILE, commitJson);
    files.write(ENVELOPE_NEXT_FILE, newEnvelope);
    files.write(ENVELOPE_FILE, newEnvelope);
    files.write(META_FILE, decision.meta);
    files.write(COMMIT_FILE, commitJson);
    files.remove(OUTBOUND_PLAIN_FILE);
    files.remove(META_STAGING_FILE);
    files.write(APPLIED_FILE, packJson(newEnvelope, decision.meta, commitJson));
  } catch (error) {
    if (hadPrevious) {
      try {
        restorePreviousCommit(files);
      } catch (restoreError) {
      }
      return NEW_CONFIG_NOT_APPLIED;
    }
    removeBestEffort(files, ENVELOPE_FILE);
    removeBestEffort(files, META_FILE);
    removeBestEffort(files, COMMIT_FILE);
    removeBestEffort(files, APPLIED_FILE);
    removeBestEffort(files, OUTBOUND_PLAIN_FILE);
    removeBestEffort(files, META_STAGING_FILE);
    if (files.read(ENVELOPE_FILE).length < 20) {
      removeBestEffort(files, ENVELOPE_NEXT_FILE);
      removeBestEffort(files, COMMIT_NEXT_FILE);
    }
    return NEW_CONFIG_REJECTED;
  }
  removeBestEffort(files, ENVELOPE_NEXT_FILE);
  removeBestEffort(files, COMMIT_NEXT_FILE);
  if (isDirtyApply(files)) {
    return STAGING_CLEANUP_WARNING;
  }
  return '';
}

export function readCommittedEnvelope(files: CommitFileOps, unwrap: (envelope: string) => string): string {
  const applied = loadAppliedPack(files);
  if (packUsable(applied, unwrap)) {
    return packPlain(applied, unwrap);
  }
  const prev = loadPrevPack(files);
  if (packUsable(prev, unwrap)) {
    projectPack(files, prev);
    return packPlain(prev, unwrap);
  }
  if (isDirtyApply(files)) {
    throw new Error(NEW_CONFIG_REJECTED);
  }
  const envelope = files.read(ENVELOPE_FILE);
  const plain = envelope.length > 20 ? unwrap(envelope) : files.read(OUTBOUND_PLAIN_FILE);
  const commitJson = files.read(COMMIT_FILE);
  if (commitJson.length < 8 && prev['envelope'].length < 20 && files.read(APPLIED_FILE).length < 8) {
    if (plain.length >= 20) {
      return plain;
    }
  }
  const mismatch = verifyAppliedRead(plain, commitJson, files.read(META_FILE));
  throw new Error(mismatch.length > 0 ? mismatch : '节点配置不完整');
}

export async function readCommittedEnvelopeAsync(files: CommitFileOps,
  unwrap: (envelope: string) => Promise<string>): Promise<string> {
  const applied = loadAppliedPack(files);
  const appliedPlain = await packPlainAsync(applied, unwrap);
  if (await packUsableAsync(applied, unwrap, appliedPlain)) {
    return appliedPlain;
  }
  const prev = loadPrevPack(files);
  const prevPlain = await packPlainAsync(prev, unwrap);
  if (await packUsableAsync(prev, unwrap, prevPlain)) {
    projectPack(files, prev);
    return prevPlain;
  }
  if (isDirtyApply(files)) {
    throw new Error(NEW_CONFIG_REJECTED);
  }
  const envelope = files.read(ENVELOPE_FILE);
  const plain = envelope.length > 20 ? await unwrap(envelope) : files.read(OUTBOUND_PLAIN_FILE);
  const commitJson = files.read(COMMIT_FILE);
  if (commitJson.length < 8 && prev['envelope'].length < 20 && files.read(APPLIED_FILE).length < 8 &&
    plain.length >= 20) {
    return plain;
  }
  const mismatch = verifyAppliedRead(plain, commitJson, files.read(META_FILE));
  throw new Error(mismatch.length > 0 ? mismatch : '节点配置不完整');
}

async function packPlainAsync(pack: Record<string, string>, unwrap: (envelope: string) => Promise<string>): Promise<string> {
  if (pack['envelope'].length > 20) {
    return unwrap(pack['envelope']);
  }
  return '';
}

async function packUsableAsync(pack: Record<string, string>, unwrap: (envelope: string) => Promise<string>,
  plain: string): Promise<boolean> {
  if (plain.length < 20) {
    return false;
  }
  if (pack['commit'].length >= 8) {
    return verifyAppliedRead(plain, pack['commit'], pack['meta']).length === 0;
  }
  return pack['source'] === 'pack';
}

export function verifyAppliedRead(plain: string, commitJson: string, meta: string): string {
  if (plain.length < 20) {
    return '节点配置不完整';
  }
  if (commitJson.length < 8) {
    return '';
  }
  try {
    const commit = JSON.parse(commitJson) as Record<string, Object>;
    const payloadDigest = commit['payloadDigest'];
    if (typeof payloadDigest === 'string' && payloadDigest.length > 0 && payloadDigest !== digestText(plain)) {
      return '运行配置与已提交版本不一致';
    }
    const metaDigest = commit['metaDigest'];
    if (typeof metaDigest === 'string' && metaDigest.length > 0 && meta.length > 2 &&
      metaDigest !== digestText(meta)) {
      return '节点元数据与已提交版本不一致';
    }
  } catch (error) {
    return '提交记录无法解析';
  }
  return '';
}

export function nextRevision(commitJson: string): number {
  if (commitJson.length < 8) {
    return 1;
  }
  try {
    const commit = JSON.parse(commitJson) as Record<string, Object>;
    const prev = commit['revision'];
    if (typeof prev === 'number' && prev >= 1) {
      return prev + 1;
    }
  } catch (error) {
    return 1;
  }
  return 1;
}
