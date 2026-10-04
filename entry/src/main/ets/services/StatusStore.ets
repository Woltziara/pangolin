import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { DATAPLANE_STATUS_FILE, NODE_META_FILE, NodeMeta, parseNodeMeta, XRAY_CONFIG_FILE } from '../core/XrayRuntime';
import { atomicReplaceFile } from '../native/TunnelNative';
import { DataplaneStatus, parseStatus, PHASE_ERROR, PHASE_IDLE, serializeStatus } from '../net/DataplaneStatus';
import { updateConnectionHealth } from '../net/ConnectionHealth';
import { BUNDLE_NAME } from '../vpn/VpnConstants';
import { NodeRecord, buildSplitOutboundPayload, nodeMetaJson, parseNodeCatalog, splitMetaJson } from './NodeCatalog';

export const NODES_FILE: string = 'nodes.json';
export const OUTBOUND_FILE: string = 'outbound.json';
const GEOIP_RELEASE: string = 'v2fly-geoip-202608050239';
const GEOSITE_RELEASE: string = 'v2fly-geosite-20260831141734';

export class StatusStore {
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
    const raw = StatusStore.readText(context, NODES_FILE);
    if (raw.length === 0) {
      return [];
    }
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
  // readJsonFile goes through recoverCanonical so a crashed write heals from the
  // newest durable tmp file, same as the dataplane status file.
  static readJsonFile(context: common.Context, name: string): string {
    const path = `${context.filesDir}/${name}`;
    try {
      return StatusStore.recoverCanonical(path);
    } catch (error) {
      console.error(`readJsonFile ${name} failed ${JSON.stringify(error)}`);
      return '';
    }
  }

  static writeJsonAtomic(context: common.Context, name: string, text: string): void {
    StatusStore.writeAtomic(`${context.filesDir}/${name}`, text);
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
      console.error(`unlink ${name} failed ${JSON.stringify(error)}`);
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
        console.error(`unlink tmp ${extra} failed ${JSON.stringify(error)}`);
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
      fs.writeSync(file.fd, text);
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      const replaced = atomicReplaceFile(tmp, path);
      if (replaced.ok) {
        return;
      }
      last = replaced.message;
    }
    throw new Error(`atomicReplaceFile ${path}: ${last}`);
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
    try {
      if (fs.accessSync(path)) {
        const raw = fs.readTextSync(path);
        if (raw.length >= 2) {
          JSON.parse(raw);
          return raw;
        }
      }
    } catch (error) {
      // dest missing or invalid; try promoting a durable tmp
    }
    const slash = path.lastIndexOf('/');
    const dir = slash >= 0 ? path.substring(0, slash) : '.';
    const base = slash >= 0 ? path.substring(slash + 1) : path;
    let bestPath = '';
    let bestMtime = -1;
    try {
      const names = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (name.indexOf(`${base}.`) !== 0 || name.indexOf('.tmp') < 0) {
          continue;
        }
        const cand = `${dir}/${name}`;
        try {
          const raw = fs.readTextSync(cand);
          if (raw.length < 2) {
            continue;
          }
          JSON.parse(raw);
          const st = fs.statSync(cand);
          if (st.mtime > bestMtime) {
            bestMtime = st.mtime;
            bestPath = cand;
          }
        } catch (error) {
          // skip
        }
      }
    } catch (error) {
      // no listing
    }
    if (bestPath.length === 0) {
      return '';
    }
    const promoted = atomicReplaceFile(bestPath, path);
    if (!promoted.ok) {
      throw new Error(`status promotion failed ${promoted.message}`);
    }
    try {
      return fs.readTextSync(path);
    } catch (error) {
      return '';
    }
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
