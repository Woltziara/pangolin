import { Revocations } from './Revocations';
// 穿山 (GPL-3.0) — 节点持久化（nodes.json 的唯一写入方）。
// 向后兼容契约：NodeCatalog.parseNodeCatalog 读取 name/region/server/port/protocol/outbound
// 以及测速证据 latencyMs/latencyAt/latencyText；其余未知键忽略。v2 写出必须始终填充
// 目录六键（见本文件尾部 SCHEMA 注释与 tests/test_import_layer.py）。
import { common } from '@kit.AbilityKit';
import { dedupeKeyOfNode } from '../core/NodeDedupe';
import { formatOutboundJsonToShareLink, ParsedNode } from '../core/ShareLinkParser';
import { StatusStore } from './StatusStore';

// nodes.json v2 顶层结构：
// {"v":2,"nodes":[{id,name,region,server,port,protocol,outbound,rawLink,sourceId,
//   favorite,group,customName,addedAt,updatedAt,latencyMs,latencyText}]}
// sourceId 取值：'manual' | 'import' | <subscriptionId>
export const NODES_SCHEMA_VERSION: number = 2;
export const SOURCE_MANUAL: string = 'manual';
export const SOURCE_IMPORT: string = 'import';

export class StoredNode {
  id: string = '';
  name: string = '';
  region: string = '其他';
  server: string = '';
  port: number = 0;
  protocol: string = '';
  outboundJson: string = '';
  rawLink: string = '';
  sourceId: string = SOURCE_IMPORT;
  favorite: boolean = false;
  group: string = '';
  customName: string = '';
  addedAt: number = 0;
  updatedAt: number = 0;
  latencyMs: number = -1;
  latencyText: string = '';
  latencyAt: number = 0;
}

export class UpsertSummary {
  added: number = 0;
  updated: number = 0;
  skippedDuplicates: number = 0;
  rotationAmbiguous: boolean = false;
  nodes: Array<StoredNode> = [];
}

export class NodeStore {
  static loadNodes(context: common.Context): Array<StoredNode> {
    const raw = StatusStore.readJsonFile(context, 'nodes.json');
    if (raw.length < 2) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const arr = parsed['nodes'];
      if (arr === undefined || !(arr instanceof Array)) throw new Error('nodes schema missing');
      const version = typeof parsed['v'] === 'number' ? parsed['v'] as number : 1;
      if (version > NODES_SCHEMA_VERSION || version < 1) throw new Error('unsupported nodes schema');
      const now = Date.now();
      const list: Array<StoredNode> = [];
      const items = arr as Array<Object>;
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (item === null || typeof item !== 'object') {
          throw new Error('invalid node record');
        }
        const node = NodeStore.recordFromJson(item as Record<string, Object>, version, now);
        if (node !== null) {
          list.push(node);
        } else { throw new Error('invalid node definition'); }
      }
      return list;
    } catch (error) {
      throw new Error('节点目录无法完整读取，未覆盖原数据；请从已核验的私有备份恢复。');
    }
  }

  static saveNodes(context: common.Context, nodes: Array<StoredNode>): void {
    const records: Array<Record<string, Object>> = [];
    for (let i = 0; i < nodes.length; i++) {
      records.push(NodeStore.recordToJson(nodes[i]));
    }
    const doc: Record<string, Object> = {};
    doc['v'] = NODES_SCHEMA_VERSION;
    doc['nodes'] = records;
    StatusStore.writeJsonAtomic(context, 'nodes.json', JSON.stringify(doc, null, 2));
  }

  /**
   * 合并 ParsedNode 列表（导入或订阅刷新）：按去重键 upsert，
   * 已存在记录保留 favorite/customName/group/latency 等运行时字段。
   */
  static upsertNodes(context: common.Context, parsed: Array<ParsedNode>, sourceId: string): UpsertSummary {
    const existing = NodeStore.loadNodes(context);
    const summary = NodeStore.mergeParsedNodes(existing, parsed, sourceId);
    NodeStore.saveNodes(context, summary.nodes);
    return summary;
  }

  /**
   * 纯合并逻辑（不落盘），供 importFromText 预览与订阅刷新复用。
   */
  static mergeParsedNodes(existing: Array<StoredNode>, parsed: Array<ParsedNode>, sourceId: string): UpsertSummary {
    const summary = new UpsertSummary();
    const now = Date.now();
    const byScoped = new Map<string, StoredNode>();
    for (let i = 0; i < existing.length; i++) {
      const ident = dedupeKeyOfNode(existing[i].protocol, existing[i].outboundJson, existing[i].rawLink);
      if (ident.length === 0) {
        continue;
      }
      const scoped = NodeStore.scopedDedupeKey(existing[i].sourceId, ident);
      if (!byScoped.has(scoped)) {
        byScoped.set(scoped, existing[i]);
      }
    }

    const merged = existing.slice();
    const seenIncoming = new Set<string>();
    for (let i = 0; i < parsed.length; i++) {
      const p = parsed[i];
      const ident = dedupeKeyOfNode(p.protocol, p.outboundJson, p.rawLink);
      const scoped = ident.length > 0 ? NodeStore.scopedDedupeKey(sourceId, ident) : '';
      if (scoped.length > 0) {
        if (seenIncoming.has(scoped)) {
          summary.skippedDuplicates++;
          continue;
        }
        seenIncoming.add(scoped);
      }
      let matched = scoped.length > 0 ? byScoped.get(scoped) : undefined;
      // A subscription can rotate only its credential while keeping the same
      // endpoint and transport. Preserve the user's pinned node ID only when
      // both the old and the new catalog have exactly one such node.
      if (matched === undefined && sourceId.startsWith('sub-')) {
        const oldPeers = existing.filter((node: StoredNode) =>
          node.sourceId === sourceId && NodeStore.credentialRotationOnly(node, p));
        const newPeers = parsed.filter((item: ParsedNode) =>
          item.name === p.name && item.server === p.server && item.port === p.port &&
          item.protocol === p.protocol && NodeStore.credentialRotationOnly(oldPeers.length === 1 ? oldPeers[0] : new StoredNode(), item));
        if (oldPeers.length === 1 && newPeers.length === 1) matched = oldPeers[0];
        else if (oldPeers.length > 0 && newPeers.length > 1) summary.rotationAmbiguous = true;
      }
      if (matched !== undefined) {
        const rotated = dedupeKeyOfNode(matched.protocol, matched.outboundJson, matched.rawLink) !== ident;
        matched.name = p.name;
        matched.region = p.region;
        matched.server = p.server;
        matched.port = p.port;
        matched.protocol = p.protocol;
        matched.outboundJson = p.outboundJson;
        if (p.rawLink.length > 0) {
          matched.rawLink = p.rawLink;
        }
        matched.updatedAt = now;
        if (rotated) { matched.latencyMs = -1; matched.latencyText = ''; matched.latencyAt = 0; }
        if (scoped.length > 0) byScoped.set(scoped, matched);
        summary.updated++;
        continue;
      }
      const fresh = NodeStore.storedFromParsed(p, sourceId, now);
      if (merged.some((node: StoredNode) => node.id === fresh.id)) throw new Error('节点 ID 冲突，未覆盖原节点或改变选择。');
      merged.push(fresh);
      if (scoped.length > 0) {
        byScoped.set(scoped, fresh);
      }
      summary.added++;
    }
    summary.nodes = merged;
    return summary;
  }

  /**
   * 订阅刷新合并：保留 latency/favorite/customName/group（由 mergeParsedNodes 保证），
   * 并移除该订阅本次没有返回的节点。
   */
  static mergeRuntime(context: common.Context, parsed: Array<ParsedNode>, sourceId: string, allowPrune: boolean = true): UpsertSummary {
    const existing = NodeStore.loadNodes(context);
    const summary = NodeStore.mergeParsedNodes(existing, parsed, sourceId);
    const merged = summary.nodes;
    const incomingKeys = new Set<string>();
    for (let i = 0; i < parsed.length; i++) {
      const key = dedupeKeyOfNode(parsed[i].protocol, parsed[i].outboundJson, parsed[i].rawLink);
      if (key.length > 0) {
        incomingKeys.add(key);
      }
    }
    const kept: Array<StoredNode> = [];
    for (let i = 0; i < merged.length; i++) {
      const node = merged[i];
      if (!allowPrune || summary.rotationAmbiguous || node.sourceId !== sourceId) {
        kept.push(node);
        continue;
      }
      const key = dedupeKeyOfNode(node.protocol, node.outboundJson, node.rawLink);
      if (key.length === 0 || incomingKeys.has(key)) {
        kept.push(node);
      }
    }
    summary.nodes = kept;
    NodeStore.saveNodes(context, kept);
    return summary;
  }

  static toggleFavorite(context: common.Context, id: string): boolean {
    const nodes = NodeStore.loadNodes(context);
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) {
        nodes[i].favorite = !nodes[i].favorite;
        nodes[i].updatedAt = Date.now();
        NodeStore.saveNodes(context, nodes);
        return true;
      }
    }
    return false;
  }

  /** 重命名：customName 非空时展示名以 customName 为准（displayName）。 */
  static rename(context: common.Context, id: string, customName: string): boolean {
    const nodes = NodeStore.loadNodes(context);
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) {
        nodes[i].customName = customName.trim();
        nodes[i].updatedAt = Date.now();
        NodeStore.saveNodes(context, nodes);
        return true;
      }
    }
    return false;
  }

  static setGroup(context: common.Context, id: string, group: string): boolean {
    const nodes = NodeStore.loadNodes(context);
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) {
        nodes[i].group = group.trim();
        nodes[i].updatedAt = Date.now();
        NodeStore.saveNodes(context, nodes);
        return true;
      }
    }
    return false;
  }

  static removeNodes(context: common.Context, ids: Array<string>): number {
    const drop = new Set<string>();
    for (let i = 0; i < ids.length; i++) {
      drop.add(ids[i]);
    }
    const nodes = NodeStore.loadNodes(context);
    const kept: Array<StoredNode> = [];
    let removed = 0;
    for (let i = 0; i < nodes.length; i++) {
      if (drop.has(nodes[i].id)) {
        removed++;
      } else {
        kept.push(nodes[i]);
      }
    }
    if (removed > 0) {
      Revocations.revoke(context, ids.map((id: string) => `node:${id}`));
      NodeStore.saveNodes(context, kept);
    }
    return removed;
  }

  static updateLatency(context: common.Context, id: string, latencyMs: number, latencyText: string): boolean {
    const nodes = NodeStore.loadNodes(context);
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) {
        nodes[i].latencyMs = latencyMs;
        nodes[i].latencyText = latencyText;
        nodes[i].latencyAt = Date.now();
        NodeStore.saveNodes(context, nodes);
        return true;
      }
    }
    return false;
  }

  static displayName(node: StoredNode): string {
    return node.customName.length > 0 ? node.customName : node.name;
  }

  static filterByRegion(nodes: Array<StoredNode>, region: string): Array<StoredNode> {
    const list: Array<StoredNode> = [];
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].region === region) {
        list.push(nodes[i]);
      }
    }
    return list;
  }

  static filterBySource(nodes: Array<StoredNode>, sourceId: string): Array<StoredNode> {
    const list: Array<StoredNode> = [];
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].sourceId === sourceId) {
        list.push(nodes[i]);
      }
    }
    return list;
  }

  static filterFavorites(nodes: Array<StoredNode>): Array<StoredNode> {
    const list: Array<StoredNode> = [];
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].favorite) {
        list.push(nodes[i]);
      }
    }
    return list;
  }

  /** 按延迟排序：测过的升序在前，未测（-1）排最后。 */
  static sortByLatency(nodes: Array<StoredNode>): Array<StoredNode> {
    const sorted = nodes.slice();
    sorted.sort((a: StoredNode, b: StoredNode): number => {
      const aMs = a.latencyMs >= 0 ? a.latencyMs : 1000000;
      const bMs = b.latencyMs >= 0 ? b.latencyMs : 1000000;
      return aMs - bMs;
    });
    return sorted;
  }

  static sortByName(nodes: Array<StoredNode>): Array<StoredNode> {
    const sorted = nodes.slice();
    sorted.sort((a: StoredNode, b: StoredNode): number => {
      const an = NodeStore.displayName(a);
      const bn = NodeStore.displayName(b);
      if (an < bn) {
        return -1;
      }
      if (an > bn) {
        return 1;
      }
      return 0;
    });
    return sorted;
  }

  /** 收藏在前、其余保持原顺序。 */
  static sortFavoriteFirst(nodes: Array<StoredNode>): Array<StoredNode> {
    const favorites: Array<StoredNode> = [];
    const rest: Array<StoredNode> = [];
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].favorite) {
        favorites.push(nodes[i]);
      } else {
        rest.push(nodes[i]);
      }
    }
    return favorites.concat(rest);
  }

  /** 导出分享链接（分享/导出功能）；优先 rawLink，否则从 outbound JSON 反向生成。 */
  static exportShareLinks(nodes: Array<StoredNode>, ids: Array<string>): Array<string> {
    const want = new Set<string>();
    for (let i = 0; i < ids.length; i++) {
      want.add(ids[i]);
    }
    const links: Array<string> = [];
    for (let i = 0; i < nodes.length; i++) {
      const node = nodes[i];
      if (!want.has(node.id)) {
        continue;
      }
      if (node.rawLink.length > 0) {
        links.push(node.rawLink);
        continue;
      }
      const link = formatOutboundJsonToShareLink(node.outboundJson, NodeStore.displayName(node));
      if (link.length > 0) {
        links.push(link);
      }
    }
    return links;
  }

  /** UI 展示用地址脱敏：IPv4 隐藏最后一段，IPv6 只保留前两组。 */
  static maskEndpointAddress(server: string): string {
    if (server.length === 0) {
      return '';
    }
    if (server.indexOf(':') >= 0) {
      // IPv6
      const groups = server.split(':');
      if (groups.length >= 2) {
        return `${groups[0]}:${groups[1]}:***`;
      }
      return '***';
    }
    const parts = server.split('.');
    if (parts.length === 4) {
      let allNumeric = true;
      for (let i = 0; i < 4; i++) {
        if (parts[i].length === 0 || Number.isNaN(Number(parts[i]))) {
          allNumeric = false;
          break;
        }
      }
      if (allNumeric) {
        return `${parts[0]}.${parts[1]}.${parts[2]}.*`;
      }
    }
    // 域名：保留首段与顶级域之外的形态，隐藏中间段。
    if (parts.length >= 3) {
      return `${parts[0]}.***.${parts[parts.length - 1]}`;
    }
    return server;
  }

  private static storedFromParsed(p: ParsedNode, sourceId: string, now: number): StoredNode {
    const node = new StoredNode();
    node.id = NodeStore.makeNodeId(p.protocol, p.outboundJson, p.rawLink, sourceId);
    node.name = p.name;
    node.region = p.region;
    node.server = p.server;
    node.port = p.port;
    node.protocol = p.protocol;
    node.outboundJson = p.outboundJson;
    node.rawLink = p.rawLink;
    node.sourceId = sourceId;
    node.favorite = false;
    node.group = '';
    node.customName = '';
    node.addedAt = now;
    node.updatedAt = now;
    node.latencyMs = -1;
    node.latencyText = '';
    return node;
  }

  static scopedDedupeKey(sourceId: string, identity: string): string {
    return `${sourceId}\n${identity}`;
  }

  private static credentialRotationOnly(oldNode: StoredNode, next: ParsedNode): boolean {
    if (oldNode.name !== next.name || oldNode.region !== next.region ||
      oldNode.server !== next.server || oldNode.port !== next.port ||
      oldNode.protocol !== next.protocol || next.protocol.toLowerCase() !== 'trojan') return false;
    try {
      const old = JSON.parse(oldNode.outboundJson) as Record<string, Object>;
      const incoming = JSON.parse(next.outboundJson) as Record<string, Object>;
      const oldServers = (old['settings'] as Record<string, Object>)['servers'] as Array<Record<string, Object>>;
      const newServers = (incoming['settings'] as Record<string, Object>)['servers'] as Array<Record<string, Object>>;
      if (oldServers.length !== 1 || newServers.length !== 1 ||
        typeof oldServers[0]['password'] !== 'string' || typeof newServers[0]['password'] !== 'string' ||
        (oldServers[0]['password'] as string).length === 0 || (newServers[0]['password'] as string).length === 0 ||
        oldServers[0]['password'] === newServers[0]['password']) return false;
      oldServers[0]['password'] = ''; newServers[0]['password'] = '';
      return JSON.stringify(old) === JSON.stringify(incoming);
    } catch (_error) { return false; }
  }

  /** 稳定 id：去重键的 FNV-1a 哈希。已有记录保留原 id；新副本按来源区分以免碰撞。 */
  static makeNodeId(protocol: string, outboundJson: string, rawLink: string, sourceId: string = ''): string {
    const key = dedupeKeyOfNode(protocol, outboundJson, rawLink);
    const value = `${key.length > 0 ? key : `${protocol}|${rawLink}|${outboundJson.length}`}|src:${sourceId}`;
    let hash = 2166136261;
    for (let index = 0; index < value.length; index++) {
      hash = (hash ^ value.charCodeAt(index)) * 16777619;
      hash = hash >>> 0;
    }
    return `node-${hash.toString(16)}`;
  }

  private static recordFromJson(item: Record<string, Object>, version: number, now: number): StoredNode | null {
    const outbound = item['outbound'];
    if (outbound === undefined || typeof outbound !== 'object') {
      return null;
    }
    const outboundJson = JSON.stringify(outbound);
    if (outboundJson.length < 20) {
      return null;
    }
    const node = new StoredNode();
    node.name = asString(item['name'], '');
    if (node.name.length === 0) {
      return null;
    }
    node.region = asString(item['region'], '其他');
    node.server = asString(item['server'], '');
    node.port = asInt(item['port'], 0);
    node.protocol = asString(item['protocol'], 'trojan');
    node.outboundJson = outboundJson;
    if (version >= NODES_SCHEMA_VERSION) {
      node.id = asString(item['id'], '');
      node.rawLink = asString(item['rawLink'], '');
      node.sourceId = asString(item['sourceId'], SOURCE_IMPORT);
      node.favorite = asBool(item['favorite'], false);
      node.group = asString(item['group'], '');
      node.customName = asString(item['customName'], '');
      node.addedAt = asInt(item['addedAt'], now);
      node.updatedAt = asInt(item['updatedAt'], now);
      node.latencyMs = asIntAllowNegative(item['latencyMs'], -1);
      node.latencyText = asString(item['latencyText'], '');
      node.latencyAt = asInt(item['latencyAt'], 0);
    } else {
      // v1 → v2 原地升级：生成稳定 id，来源记为 'import'。
      node.id = '';
      node.rawLink = '';
      node.sourceId = SOURCE_IMPORT;
      node.favorite = false;
      node.group = '';
      node.customName = '';
      node.addedAt = now;
      node.updatedAt = now;
      node.latencyMs = -1;
      node.latencyText = '';
    }
    if (node.id.length === 0) {
      node.id = NodeStore.makeNodeId(node.protocol, node.outboundJson, node.rawLink, node.sourceId);
    }
    return node;
  }

  private static recordToJson(node: StoredNode): Record<string, Object> {
    const record: Record<string, Object> = {};
    record['id'] = node.id;
    // NodeCatalog 兼容六键必须始终存在且有值。
    record['name'] = node.name;
    record['region'] = node.region;
    record['server'] = node.server;
    record['port'] = node.port;
    record['protocol'] = node.protocol;
    record['outbound'] = JSON.parse(node.outboundJson) as Object;
    record['rawLink'] = node.rawLink;
    record['sourceId'] = node.sourceId;
    record['favorite'] = node.favorite;
    record['group'] = node.group;
    record['customName'] = node.customName;
    record['addedAt'] = node.addedAt;
    record['updatedAt'] = node.updatedAt;
    record['latencyMs'] = node.latencyMs;
    record['latencyText'] = node.latencyText;
    record['latencyAt'] = node.latencyAt;
    return record;
  }
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function asInt(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number' && value > 0) {
    return value;
  }
  return fallback;
}

function asIntAllowNegative(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number') {
    return value;
  }
  return fallback;
}

function asBool(value: Object | undefined, fallback: boolean): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  return fallback;
}
