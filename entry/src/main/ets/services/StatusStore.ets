import { AppLog } from './AppLog';
import { CONTROL_FILE, OWNER_TERMINAL_FILE, projectControl } from '../net/OwnerTerminal';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { DATAPLANE_STATUS_FILE, NODE_META_FILE, NodeMeta, parseNodeMeta, XRAY_CONFIG_FILE } from '../core/XrayRuntime';
import { atomicReplaceFile, compareReplaceText, acquireUserDataLease, releaseUserDataLease } from '../native/TunnelNative';
import { DataplaneStatus, parseStatus, PHASE_ERROR, PHASE_IDLE, serializeStatus } from '../net/DataplaneStatus';
import { updateConnectionHealth } from '../net/ConnectionHealth';
import { BUNDLE_NAME } from '../vpn/VpnConstants';
import { NodeRecord, buildSplitOutboundPayload, nodeMetaJson, parseNodeCatalog, splitMetaJson } from './NodeCatalog';

export const NODES_FILE: string = 'nodes.json';
export const OUTBOUND_FILE: string = 'outbound.json';
const GEOIP_RELEASE: string = 'v2fly-geoip-202608050239';
const GEOSITE_RELEASE: string = 'v2fly-geosite-20260831141734';

export class StatusStore {
  private static readVersions: Map<string, string> = new Map<string, string>();
  static statusPath(context: common.Context): string {
    return `${context.filesDir}/${DATAPLANE_STATUS_FILE}`;
  }

  static configPath(context: common.Context): string {
    return `${context.filesDir}/${XRAY_CONFIG_FILE}`;
  }

  static metaPath(context: common.Context): string {
    return `${context.filesDir}/${NODE_META_FILE}`;
  }

  static writeStatus(context: common.Context, status: DataplaneStatus): void {
    updateConnectionHealth(status, StatusStore.readText(context, 'probe-fetch.json'), BUNDLE_NAME, Date.now());
    StatusStore.writeAtomic(StatusStore.statusPath(context), serializeStatus(status));
  }

  static readStatus(context: common.Context): DataplaneStatus {
    try {
      const owner = StatusStore.readOwnerStatus(context);
      if (owner.honestLabel === '状态文件读失败') {
        owner.phase = 'STOP_UNCONFIRMED'; owner.operationKind = 'record-error';
      }
      return projectControl(owner, StatusStore.readStrictText(context, CONTROL_FILE),
        StatusStore.readStrictText(context, OWNER_TERMINAL_FILE), StatusStore.readText(context, 'system-observation.json'));
    } catch (_error) {
      const unknown = new DataplaneStatus();
      unknown.phase = 'STOP_UNCONFIRMED';
      unknown.honestLabel = '连接记录无法读取';
      unknown.lastError = '未能读取连接控制记录；未启动、未清理任何用户数据。';
      return unknown;
    }
  }

  /** Absent is distinct from corrupt/unreadable. Safety decisions must use this reader. */
  static readStrictText(context: common.Context, name: string): string {
    const path = `${context.filesDir}/${name}`;
    try {
      if (!fs.accessSync(path)) return '';
      return fs.readTextSync(path);
    } catch (_error) { throw new Error(`本机记录无法读取：${name}，未覆盖原数据。`); }
  }

  /** Compare-and-replace, including a cross-process comparison under the native lock. */
  static compareText(context: common.Context, name: string, expected: string, value: string): boolean {
    if (!/^[A-Za-z0-9_.-]+$/.test(name) || name.indexOf('..') >= 0) throw new Error('invalid record name');
    const result = compareReplaceText(`${context.filesDir}/${name}`, expected, value);
    if (result.ok) return true;
    if (result.message === 'conflict') return false;
    throw new Error(`本机记录提交失败：${name}；${result.message}`);
  }

  static readOwnerStatus(context: common.Context): DataplaneStatus {
    const path = StatusStore.statusPath(context);
    try {
      const raw = StatusStore.recoverCanonical(path);
      if (raw.length < 8) {
        if (StatusStore.destExists(path)) {
          const broken = new DataplaneStatus();
          broken.phase = PHASE_ERROR;
          broken.lastError = '状态文件损坏或过短';
          broken.honestLabel = '状态文件读失败';
          return broken;
        }
        return new DataplaneStatus();
      }
      const status = parseStatus(raw);
      updateConnectionHealth(status, StatusStore.readText(context, 'probe-fetch.json'), BUNDLE_NAME, Date.now());
      if (status.phase === PHASE_IDLE && raw.replace(/\s/g, '') === '{}') {
        status.phase = PHASE_ERROR;
        status.lastError = '空状态对象不能当成未连接';
        status.honestLabel = '状态文件读失败';
      }
      return status;
    } catch (error) {
      const status = new DataplaneStatus();
      status.phase = PHASE_ERROR;
      status.honestLabel = '状态文件读失败';
      status.lastError = `读取状态失败 ${JSON.stringify(error)}`;
      return status;
    }
  }

  static readConfigJson(context: common.Context): string {
    const path = StatusStore.configPath(context);
    if (!fs.accessSync(path)) {
      return '';
    }
    return fs.readTextSync(path);
  }

  static writeConfigJson(context: common.Context, configJson: string): void {
    StatusStore.writeAtomic(StatusStore.configPath(context), configJson);
  }

  static readNodeMeta(context: common.Context): NodeMeta {
    const path = StatusStore.metaPath(context);
    if (!fs.accessSync(path)) {
      return parseNodeMeta('{}');
    }
    return parseNodeMeta(fs.readTextSync(path));
  }

  static writeNodeMeta(context: common.Context, metaJson: string): void {
    StatusStore.writeAtomic(StatusStore.metaPath(context), metaJson);
  }

  static writeNodeMetaStaging(context: common.Context, metaJson: string): void {
    StatusStore.writeText(context, 'node-meta.json.staging', metaJson);
  }

  static readText(context: common.Context, name: string): string {
    const path = `${context.filesDir}/${name}`;
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      return fs.readTextSync(path);
    } catch (error) {
      return '';
    }
  }

  static seedFromRawfile(context: common.UIAbilityContext): void {
    // HAP must not carry node passwords. Only seed geo databases from the package.
    StatusStore.copyRawBinaryIfPresent(context, 'geo/geoip.dat', 'geoip.dat', GEOIP_RELEASE);
    StatusStore.copyRawBinaryIfPresent(context, 'geo/geosite.dat', 'geosite.dat', GEOSITE_RELEASE);
  }

  static readNodes(context: common.Context): NodeRecord[] {
    const raw = StatusStore.readJsonFile(context, NODES_FILE);
    if (raw.length === 0) {
      return [];
    }
    const catalog = JSON.parse(raw) as Record<string, Object>;
    if (!Array.isArray(catalog['nodes'])) throw new Error('节点目录结构无效，未采用旧线路或写空。');
    return parseNodeCatalog(raw);
  }

  static applyNode(context: common.Context, node: NodeRecord): void {
    StatusStore.writeText(context, OUTBOUND_FILE, node.outboundJson);
    StatusStore.writeNodeMeta(context, nodeMetaJson(node));
  }

  static applySplit(context: common.Context, yt: NodeRecord, us: NodeRecord, yt2: NodeRecord, us2: NodeRecord): void {
    StatusStore.writeText(context, OUTBOUND_FILE, buildSplitOutboundPayload(yt, us, yt2, us2));
    StatusStore.writeNodeMeta(context, splitMetaJson(yt, us, yt2, us2));
  }

  static writeText(context: common.Context, name: string, text: string): void {
    StatusStore.writeAtomic(`${context.filesDir}/${name}`, text);
  }

  // Additive helpers for the import/subscription layer (NodeStore, SubscriptionStore).
  // Reads accept only the committed canonical record. Abandoned temporaries are not authority.
  static readJsonFile(context: common.Context, name: string): string {
    const path = `${context.filesDir}/${name}`;
    const raw = StatusStore.recoverCanonical(path);
    StatusStore.readVersions.set(path, raw);
    return raw;
  }

  static acquireUserDataLease(context: common.Context): number {
    const token = acquireUserDataLease(`${context.filesDir}/user-data-transaction.lock`);
    if (token <= 0) throw new Error('另一数据操作正在进行，未覆盖或清理。');
    return token;
  }
  static releaseUserDataLease(token: number): void { releaseUserDataLease(token); }
  static writeJsonAtomic(context: common.Context, name: string, text: string): void {
    const lease = StatusStore.acquireUserDataLease(context);
    try {
      const control = StatusStore.readStrictText(context, CONTROL_FILE);
      if (control.length > 0) {
        const marker = JSON.parse(control) as Record<string, Object>;
        if (marker['kind'] === 'maintenance' && marker['state'] !== 'confirmed') throw new Error('数据清理尚未完成，未写入新数据。');
      }
      const path = `${context.filesDir}/${name}`;
      const prior = StatusStore.readVersions.get(path);
      const expected = prior !== undefined ? prior : StatusStore.recoverCanonical(path);
      JSON.parse(text);
      if (!StatusStore.compareText(context, name, expected, text)) throw new Error('数据已被另一操作更新，请重新载入；未覆盖其他修改。');
      StatusStore.readVersions.set(path, text);
    } finally { StatusStore.releaseUserDataLease(lease); }
  }

  static removeFile(context: common.Context, name: string): void {
    if (name.length === 0 || name.indexOf('/') >= 0 || name.indexOf('..') >= 0 || name.indexOf('\\') >= 0) {
      throw new Error(`非法文件名，拒绝触碰 filesDir 之外的路径：${name}`);
    }
    const path = `${context.filesDir}/${name}`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      AppLog.error(0x3200, 'StatusStore', '%{public}s', `unlink ${name} failed ${JSON.stringify(error)}`);
      throw new Error(`未能删除本机文件：${name}`);
    }
    const names = StatusStore.listNames(context);
    const prefix = `${name}.`;
    for (let i = 0; i < names.length; i++) {
      const extra = names[i];
      if (extra.indexOf(prefix) !== 0 || extra.indexOf('.tmp') < 0) {
        continue;
      }
      const extraPath = `${context.filesDir}/${extra}`;
      try {
        if (fs.accessSync(extraPath)) {
          fs.unlinkSync(extraPath);
        }
      } catch (error) {
        AppLog.error(0x3200, 'StatusStore', '%{public}s', `unlink tmp ${extra} failed ${JSON.stringify(error)}`);
        throw new Error(`未能删除本机文件：${extra}`);
      }
    }
  }

  private static writeAtomic(path: string, text: string): void {
    let last = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      const nonce = util.generateRandomUUID();
      const tmp = `${path}.${Date.now()}.${nonce}.tmp`;
      const file = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const bytes = new util.TextEncoder().encodeInto(text);
        const written = fs.writeSync(file.fd, bytes.buffer);
        if (written !== bytes.byteLength) throw new Error('incomplete file write');
        fs.fsyncSync(file.fd);
      } finally { fs.closeSync(file); }
      const replaced = atomicReplaceFile(tmp, path);
      if (replaced.ok) {
        return;
      }
      last = replaced.message;
    }
    throw new Error(`atomicReplaceFile ${path}: ${last}`);
  }

  static listNamesStrict(context: common.Context): string[] {
    // Used by deletion only. Listing failure cannot become an empty successful wipe.
    return fs.listFileSync(context.filesDir);
  }

  static listNames(context: common.Context): string[] {
    try {
      return fs.listFileSync(context.filesDir);
    } catch (error) {
      return [];
    }
  }

  static destExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  static destExistsNonempty(path: string): boolean {
    return StatusStore.destExists(path);
  }

  static recoverCanonical(path: string): string {
    // Read-only. A fsynced temporary file is NOT a committed transaction.
    if (!fs.accessSync(path)) {
      const slash = path.lastIndexOf('/');
      const dir = slash >= 0 ? path.substring(0, slash) : '.';
      const base = slash >= 0 ? path.substring(slash + 1) : path;
      const abandoned = fs.listFileSync(dir).some((name: string) =>
        name.startsWith(`${base}.`) && (name.endsWith('.tmp') || name.indexOf('.cas-') >= 0));
      if (abandoned) throw new Error('记录缺失且有未提交临时版本；须从已核验备份恢复，未自动提升或写空。');
      return '';
    }
    const raw = fs.readTextSync(path);
    if (raw.length < 2) throw new Error('本机记录过短，未覆盖原数据。');
    JSON.parse(raw);
    return raw;
  }

  private static copyRawIfPresent(context: common.UIAbilityContext, rawPath: string, destName: string,
    onlyIfMissing: boolean): void {
    try {
      const dest = `${context.filesDir}/${destName}`;
      if (onlyIfMissing && fs.accessSync(dest)) {
        const stat = fs.statSync(dest);
        if (stat.size > 8) {
          return;
        }
      }
      const buf = context.resourceManager.getRawFileContentSync(rawPath);
      const text = new util.TextDecoder('utf-8').decodeToString(buf);
      if (text.length < 8) {
        return;
      }
      const file = fs.openSync(dest, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
    } catch (error) {
      // rawfile optional
    }
  }

  private static copyRawBinaryIfPresent(context: common.UIAbilityContext, rawPath: string, destName: string,
    release: string): void {
    try {
      const dest = `${context.filesDir}/${destName}`;
      const metaPath = `${context.filesDir}/${destName}.release`;
      if (fs.accessSync(dest) && fs.accessSync(metaPath)) {
        const got = fs.readTextSync(metaPath).trim();
        const stat = fs.statSync(dest);
        if (got === release && stat.size > 1000) {
          return;
        }
      }
      const buf = context.resourceManager.getRawFileContentSync(rawPath);
      if (buf.byteLength < 1000) {
        return;
      }
      const file = fs.openSync(dest, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buf.buffer);
      fs.closeSync(file);
      StatusStore.writeText(context, `${destName}.release`, release);
    } catch (error) {
      // rawfile optional
    }
  }
}
