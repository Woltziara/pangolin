import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { huks } from '@kit.UniversalKeystoreKit';
import {
  APPLIED_FILE,
  applyNewCommit,
  COMMIT_FILE,
  COMMIT_NEXT_FILE,
  CommitFileOps,
  ENVELOPE_FILE,
  ENVELOPE_NEXT_FILE,
  META_FILE,
  META_STAGING_FILE,
  OUTBOUND_PLAIN_FILE,
  PREV_APPLIED_FILE,
  PREV_COMMIT_FILE,
  PREV_ENVELOPE_FILE,
  PREV_META_FILE,
  readCommittedEnvelopeAsync,
  restorePreviousCommit,
  STAGING_CLEANUP_WARNING
} from '../core/OutboundCommit';
import { StatusStore } from './StatusStore';

class StatusCommitFiles implements CommitFileOps {
  private context: common.Context;
  constructor(context: common.Context) {
    this.context = context;
  }
  read(name: string): string {
    return StatusStore.readText(this.context, name);
  }
  write(name: string, text: string): void {
    StatusStore.writeText(this.context, name, text);
  }
  remove(name: string): void {
    StatusStore.removeFile(this.context, name);
  }
}

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'HuksStore';
const ALIAS: string = 'tongdao.outbound.v1';
const AAD_TEXT: string = 'tongdao-outbound-v1';

export class HuksSecretStore {
  static async isAvailable(): Promise<boolean> {
    try {
      await huks.isKeyItemExist(ALIAS, HuksSecretStore.emptyOptions());
      return true;
    } catch (error) {
      const text = JSON.stringify(error);
      if (text.indexOf('801') >= 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'HUKS unavailable %{public}s', text);
        return false;
      }
      return true;
    }
  }

  static async protectOutbound(context: common.Context, commitAllowed: () => boolean = (): boolean => true): Promise<void> {
    const newPlain = StatusStore.readText(context, OUTBOUND_PLAIN_FILE);
    if (newPlain.length < 20) {
      return;
    }
    const files = new StatusCommitFiles(context);
    const stagingMeta = files.read(META_STAGING_FILE);
    const currentMeta = files.read(META_FILE);
    const newMeta = stagingMeta.length > 2 ? stagingMeta : currentMeta;
    const huksAvailable = await HuksSecretStore.isAvailable();
    let wrapOk = false;
    let envelope = '';
    if (huksAvailable) {
      try {
        await HuksSecretStore.ensureKey();
        const nonce = HuksSecretStore.randomNonce();
        const cipher = await HuksSecretStore.cipher(true, nonce, HuksSecretStore.encode(newPlain));
        envelope = HuksSecretStore.envelopeJson(nonce, cipher);
        const roundtrip = HuksSecretStore.decode(await HuksSecretStore.cipher(false, nonce, cipher));
        if (roundtrip !== newPlain) {
          throw new Error('HUKS roundtrip mismatch');
        }
        wrapOk = true;
      } catch (error) {
        wrapOk = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'HUKS wrap failed %{public}s', JSON.stringify(error));
      }
    }
    if (!commitAllowed()) return;
    const err = applyNewCommit(files, newPlain, newMeta, envelope, huksAvailable, wrapOk);
    if (err === STAGING_CLEANUP_WARNING) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', err);
    } else if (err.length > 0) {
      throw new Error(err);
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'outbound commit applied');
  }

  static async readOutbound(context: common.Context): Promise<string> {
    const files = new StatusCommitFiles(context);
    return readCommittedEnvelopeAsync(files, (envelope: string) => HuksSecretStore.unwrapEnvelope(envelope));
  }

  private static localRecordName(name: string): boolean {
    return name === 'running-recovery.huks' || /^running-recovery-[A-Za-z0-9_-]{3,160}\.huks$/.test(name);
  }
  static async writeLocalRecord(context: common.Context, name: string, text: string, commitAllowed: () => boolean = (): boolean => true): Promise<void> {
    if (!HuksSecretStore.localRecordName(name)) throw new Error('不支持的加密记录');
    if (!await HuksSecretStore.isAvailable()) throw new Error('HUKS 不可用，运行快照未保存');
    await HuksSecretStore.ensureKey();
    const bytes = HuksSecretStore.encode(text);
    if (bytes.length > 512 * 1024) throw new Error('运行快照超出有界存储预算');
    const count = Math.max(1, Math.ceil(bytes.length / 1024));
    const recordId = util.generateRandomUUID();
    const chunks: string[] = [];
    for (let index = 0; index < count; index++) {
      if (!commitAllowed()) return;
      const part: Record<string, Object> = { 'purpose': 'pangolin-local-record-v2', 'name': name,
        'recordId': recordId, 'index': index, 'count': count, 'bytes': bytes.length,
        'data': HuksSecretStore.b64encode(bytes.slice(index * 1024, (index + 1) * 1024)) };
      const plain = JSON.stringify(part); const nonce = HuksSecretStore.randomNonce();
      const cipher = await HuksSecretStore.cipher(true, nonce, HuksSecretStore.encode(plain));
      const envelope = HuksSecretStore.envelopeJson(nonce, cipher);
      if (await HuksSecretStore.unwrapEnvelope(envelope) !== plain) throw new Error('运行快照回读失败');
      chunks.push(envelope);
    }
    if (!commitAllowed()) return;
    const wrapper: Record<string, Object> = { 'v': 2, 'chunks': chunks };
    StatusStore.writeText(context, name, JSON.stringify(wrapper));
  }

  static async readLocalRecord(context: common.Context, name: string): Promise<string> {
    if (!HuksSecretStore.localRecordName(name)) throw new Error('不支持的加密记录');
    const raw = StatusStore.readStrictText(context, name);
    const wrapper = JSON.parse(raw) as Record<string, Object>;
    if (wrapper['v'] !== 2) return HuksSecretStore.unwrapEnvelope(raw); // legacy read-only compatibility
    if (!Array.isArray(wrapper['chunks'])) throw new Error('运行快照缺少分块');
    const chunks = wrapper['chunks'] as string[];
    if (chunks.length < 1 || chunks.length > 512) throw new Error('运行快照分块数量无效');
    let recordId = ''; let totalBytes = -1; const parts: Uint8Array[] = [];
    for (let index = 0; index < chunks.length; index++) {
      const part = JSON.parse(await HuksSecretStore.unwrapEnvelope(chunks[index])) as Record<string, Object>;
      if (part['purpose'] !== 'pangolin-local-record-v2' || part['name'] !== name ||
        part['index'] !== index || part['count'] !== chunks.length || typeof part['recordId'] !== 'string' ||
        typeof part['data'] !== 'string' || typeof part['bytes'] !== 'number') throw new Error('运行快照分块认证或顺序错误');
      if (index === 0) { recordId = part['recordId'] as string; totalBytes = part['bytes'] as number; }
      if (part['recordId'] !== recordId || part['bytes'] !== totalBytes || totalBytes < 0 || totalBytes > 512 * 1024) throw new Error('运行快照混合版本');
      const bytes = HuksSecretStore.b64decode(part['data'] as string);
      if (bytes.length > 1024 || (index < chunks.length - 1 && bytes.length !== 1024)) throw new Error('运行快照分块长度错误');
      parts.push(bytes);
    }
    const out = new Uint8Array(totalBytes); let offset = 0;
    for (let i = 0; i < parts.length; i++) {
      if (offset + parts[i].length > out.length) throw new Error('运行快照长度超出');
      out.set(parts[i], offset); offset += parts[i].length;
    }
    if (offset !== totalBytes) throw new Error('运行快照不完整');
    return HuksSecretStore.decode(out);
  }

  static restorePrevious(context: common.Context): boolean {
    return restorePreviousCommit(new StatusCommitFiles(context));
  }

  private static async unwrapEnvelope(envelope: string): Promise<string> {
    try {
      const parsed = JSON.parse(envelope) as Record<string, Object>;
      const nonceB64 = parsed['nonce'];
      const ctB64 = parsed['ct'];
      if (typeof nonceB64 === 'string' && typeof ctB64 === 'string') {
        const nonce = HuksSecretStore.b64decode(nonceB64);
        const ct = HuksSecretStore.b64decode(ctB64);
        const plain = HuksSecretStore.decode(await HuksSecretStore.cipher(false, nonce, ct));
        if (plain.length >= 20) {
          return plain;
        }
      }
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'HUKS unwrap failed %{public}s', JSON.stringify(error));
      throw new Error('节点密文无法解开');
    }
    throw new Error('节点密文无法解开');
  }

  static notePending(context: common.Context): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'HUKS store pending; filesDir import only. context=%{public}s',
      context.filesDir);
  }

  /**
   * Phase D「清空全部数据」：删除缓存的节点凭据——filesDir 里的 HUKS 信封文件 +
   * HUKS 密钥本体。两者都允许不存在（静默跳过）。
   */
  static async removeProtected(context: common.Context): Promise<void> {
    StatusStore.listNamesStrict(context).filter((name: string) => HuksSecretStore.localRecordName(name) || name === 'running-recovery-pointer.json')
      .forEach((name: string) => StatusStore.removeFile(context, name));
    StatusStore.removeFile(context, ENVELOPE_FILE);
    StatusStore.removeFile(context, PREV_ENVELOPE_FILE);
    StatusStore.removeFile(context, ENVELOPE_NEXT_FILE);
    StatusStore.removeFile(context, COMMIT_FILE);
    StatusStore.removeFile(context, PREV_COMMIT_FILE);
    StatusStore.removeFile(context, COMMIT_NEXT_FILE);
    StatusStore.removeFile(context, META_STAGING_FILE);
    StatusStore.removeFile(context, PREV_META_FILE);
    StatusStore.removeFile(context, APPLIED_FILE);
    StatusStore.removeFile(context, PREV_APPLIED_FILE);
    try {
      await huks.deleteKeyItem(ALIAS, HuksSecretStore.emptyOptions());
      hilog.info(LOG_DOMAIN, LOG_TAG, 'HUKS key deleted');
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'deleteKeyItem %{public}s', JSON.stringify(error));
      if (await HuksSecretStore.keyExists()) {
        throw new Error('节点加密密钥未能清理');
      }
    }
  }

  private static async keyExists(): Promise<boolean> {
    try {
      return await huks.isKeyItemExist(ALIAS, HuksSecretStore.emptyOptions());
    } catch (error) {
      // This API reports a missing alias by rejecting, not only by returning false.
      const record = error as Record<string, Object>;
      if (record['code'] === 12000011) { return false; }
      throw new Error(`无法确认节点加密密钥状态（${record['code']}）`);
    }
  }

  private static async ensureKey(): Promise<void> {
    const exists = await HuksSecretStore.keyExists();
    if (exists) {
      return;
    }
    await huks.generateKeyItem(ALIAS, {
      properties: HuksSecretStore.keyProperties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT)
    });
  }

  private static async cipher(encrypt: boolean, nonce: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const purpose = encrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT :
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT;
    const properties: Array<huks.HuksParam> = HuksSecretStore.keyProperties(purpose);
    const nonceParam: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_NONCE,
      value: nonce
    };
    const aadParam: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA,
      value: HuksSecretStore.encode(AAD_TEXT)
    };
    properties.push(nonceParam);
    properties.push(aadParam);
    let input: Uint8Array = data;
    if (!encrypt) {
      if (data.length <= 16) { throw new Error('节点密文缺少认证标签'); }
      properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: data.slice(data.length - 16) });
      input = data.slice(0, data.length - 16);
    }
    const session = await huks.initSession(ALIAS, { properties: properties });
    try {
      const finished = await huks.finishSession(session.handle, {
        properties: [],
        inData: input
      });
      if (finished.outData === undefined) {
        throw new Error('HUKS empty outData');
      }
      return finished.outData;
    } catch (error) {
      try {
        await huks.abortSession(session.handle, { properties: [] });
      } catch (abortError) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'abort %{public}s', JSON.stringify(abortError));
      }
      throw new Error(`HUKS cipher failed ${JSON.stringify(error)}`);
    }
  }

  private static keyProperties(purpose: number): Array<huks.HuksParam> {
    const properties: Array<huks.HuksParam> = [];
    const alg: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
      value: huks.HuksKeyAlg.HUKS_ALG_AES
    };
    const pur: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: purpose
    };
    const size: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
      value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256
    };
    const pad: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_PADDING,
      value: huks.HuksKeyPadding.HUKS_PADDING_NONE
    };
    const mode: huks.HuksParam = {
      tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE,
      value: huks.HuksCipherMode.HUKS_MODE_GCM
    };
    properties.push(alg);
    properties.push(pur);
    properties.push(size);
    properties.push(pad);
    properties.push(mode);
    return properties;
  }

  private static emptyOptions(): huks.HuksOptions {
    return { properties: [] };
  }

  private static randomNonce(): Uint8Array {
    const uuid = util.generateRandomBinaryUUID();
    const nonce = new Uint8Array(12);
    for (let i = 0; i < 12; i++) {
      nonce[i] = uuid[i];
    }
    return nonce;
  }

  private static envelopeJson(nonce: Uint8Array, cipher: Uint8Array): string {
    const record: Record<string, Object> = {};
    record['v'] = 1;
    record['alg'] = 'AES-256-GCM';
    record['alias'] = ALIAS;
    record['nonce'] = HuksSecretStore.b64encode(nonce);
    record['ct'] = HuksSecretStore.b64encode(cipher);
    return JSON.stringify(record);
  }

  private static encode(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  private static decode(bytes: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeToString(bytes);
  }

  private static b64encode(bytes: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  private static b64decode(text: string): Uint8Array {
    return new util.Base64Helper().decodeSync(text);
  }
}
