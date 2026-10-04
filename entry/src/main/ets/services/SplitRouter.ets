import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { tcpConnectCanary } from '../net/DataplaneCanary';
import {
  NodeRecord,
  REGION_US,
  buildSingleOutboundPayload,
  buildSplitOutboundPayload,
  nodeUsableForSplit,
  nodesInRegion,
  pickFastestNode,
  pickSecondBest,
  shortNodeName,
  singleMetaJson,
  splitMetaJson
} from './NodeCatalog';
import { NodeStore, StoredNode } from './NodeStore';
import { SettingsStore } from './SettingsStore';
import { OUTBOUND_FILE, StatusStore } from './StatusStore';
import { UserRuleRoute } from '../core/UserRuleMap';
import { UserRuleStore } from './UserRuleStore';
import { CONNECTION_POLICY } from './ConnectionPolicy';
import { routesForChannel } from '../core/ChannelPolicy';
import { hasFreshLatency } from '../core/BackupSelection';
import { AppRouteStore } from './AppRouteStore';
import { AppNodeOutbound, AppRoutePayload } from '../core/AppRoutePayload';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'Split';
const PING_TIMEOUT_MS: number = 2500;
const PING_BATCH: number = 4;

// Phase C：prepare 阶段的可见提示（固定节点失效回退自动 / 组内无备用节点），
// 首页读取后显示一行人话。每次 prepare 前由 ConnectionController 清除。
export const PREPARE_HINT_FILE: string = 'prepare-hint.json';

const US_FALLBACK: string[] = []; // Public build: no personal node-name preferences.


function annotateRolePolicy(payload: string, context: common.Context): string {
  const record = JSON.parse(payload) as Record<string, Object>;
  record['routingProfile'] = 'chatgpt-general';
  record['channelMode'] = CONNECTION_POLICY.mode(context);
  const appRouting = new AppRoutePayload();
  appRouting.config = AppRouteStore.load(context);
  if (appRouting.config.enabled && record['routeMode'] !== 'direct') {
    const nodes = NodeStore.loadNodes(context);
    const included = new Set<string>();
    appRouting.config.rules.forEach((rule) => {
      if (!rule.enabled || included.has(rule.nodeId)) { return; }
      const stored = nodes.find((node: StoredNode) => node.id === rule.nodeId);
      if (stored === undefined || !nodeUsableForSplit(storedToRecord(stored))) {
        throw new Error(`App「${rule.label}」指定的节点已不存在或不支持连接，请重新选择`);
      }
      const node = new AppNodeOutbound();
      node.nodeId = stored.id;
      node.outbound = JSON.parse(stored.outboundJson) as Record<string, Object>;
      appRouting.nodes.push(node); included.add(node.nodeId);
    });
  }
  record['appRouting'] = appRouting;
  return JSON.stringify(record);
}

function pinnedRoleNode(context: common.Context, id: string, label: string): NodeRecord | null {
  if (id.length === 0) { return null; }
  const nodes = NodeStore.loadNodes(context);
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].id === id) {
      const record = storedToRecord(nodes[i]);
      if (!nodeUsableForSplit(record)) { throw new Error(`${label}选择的节点暂不支持连接，请重新选择`); }
      return record;
    }
  }
  throw new Error(`${label}选择的节点已不存在，请重新选择`);
}

export async function prepareSingleProxy(context: common.Context): Promise<string> {
  return prepareYtUsPlan(context, false);
}

export async function prepareYtUsPlanLight(context: common.Context): Promise<string> {
  return prepareYtUsPlan(context, true);
}

/**
 * Phase C 手动选路：把固定节点写成 v=4 单节点 payload（proxy 与 proxy-yt
 * 同指该节点），不做任何全网测速。返回节点名；固定 id 失效（节点被删/改名
 * 导致 id 变化）时返回 ''，由调用方回退自动路径并提示用户。
 */
export function prepareManualPlan(context: common.Context, nodeId: string): string {
  if (nodeId.length === 0) {
    return '';
  }
  const stored = NodeStore.loadNodes(context);
  for (let i = 0; i < stored.length; i++) {
    const node = stored[i];
    if (node.id !== nodeId || node.outboundJson.length < 20) {
      continue;
    }
    const rec = new NodeRecord();
    rec.name = node.name;
    rec.region = node.region;
    rec.server = node.server;
    rec.port = node.port;
    rec.protocol = node.protocol;
    rec.outboundJson = node.outboundJson;
    if (!nodeUsableForSplit(rec)) {
      return '';
    }
    const settings = SettingsStore.load(context);
    const userRules = routesForChannel(UserRuleStore.enabledRoutes(context), CONNECTION_POLICY.mode(context));
    rec.id = node.id;
    rec.group = node.group;
    const nodeGroup = node.group;
    const backup = CONNECTION_POLICY.autoFailoverEnabled(context) ?
      pickManualBackup(context, rec, settings.failoverGroup) : new NodeRecord();
    StatusStore.writeText(context, OUTBOUND_FILE,
      annotateRolePolicy(buildSingleOutboundPayload(rec, settings.routeMode, userRules, nodeGroup, backup), context));
    StatusStore.writeNodeMetaStaging(context, singleMetaJson(rec));
    hilog.info(LOG_DOMAIN, LOG_TAG, 'manual pin %{public}s', shortNodeName(node.name));
    return NodeStore.displayName(node);
  }
  return '';
}

/** Phase C：prepare 阶段可见提示（首页读取展示）。 */
export function writePrepareHint(context: common.Context, text: string): void {
  const rec: Record<string, Object> = {};
  rec['text'] = text;
  rec['at'] = Date.now();
  StatusStore.writeText(context, PREPARE_HINT_FILE, JSON.stringify(rec));
}

export async function prepareYtUsPlan(context: common.Context, light: boolean): Promise<string> {
  if (CONNECTION_POLICY.mode(context) === 'single') { return prepareFreeSingle(context); }
  const nodes = StatusStore.readNodes(context);
  if (nodes.length === 0) {
    return '';
  }
  const usable: NodeRecord[] = [];
  const probe: NodeRecord[] = [];
  for (let i = 0; i < nodes.length; i++) {
    if (!nodeUsableForSplit(nodes[i])) {
      continue;
    }
    usable.push(nodes[i]);
    if (!light || nodes[i].region === REGION_US || nodes[i].region === '中国香港' ||
      nodes[i].region === '日本' || nodes[i].region === '新加坡' || nodes[i].region === '中国台湾') {
      probe.push(nodes[i]);
    }
  }
  if (usable.length === 0) {
    throw new Error('没有可连接的节点');
  }
  let usList = nodesInRegion(nodes, REGION_US);
  if (usList.length === 0) {
    usList = usable;
  }
  const ytPool = light ? probe : usable;
  const roleSettings = SettingsStore.load(context);
  const previous = StatusStore.readNodeMeta(context);
  let yt = pinnedRoleNode(context, roleSettings.generalNodeId, '通用线路') ??
    reusableNode(ytPool, previous.ytName);
  let us = pinnedRoleNode(context, roleSettings.chatgptNodeId, 'ChatGPT 线路') ??
    reusableNode(usList, previous.usName.length > 0 ? previous.usName : previous.name);
  // Selection is reusable; reachability is checked by the running VPN. Only
  // first selection / a missing catalog entry needs foreground ranking.
  if (yt === null || us === null) {
    await pingAll(probe);
    persistPingResults(context, NodeStore.loadNodes(context), probe);
    yt = yt ?? pickFastestNode(ytPool, US_FALLBACK);
    us = us ?? pickFastestNode(usList, US_FALLBACK);
  }
  if (yt.name.length === 0 || us.name.length === 0) {
    throw new Error('无法选出可用节点');
  }
  // Phase C：主选不变（保持既有行为）；备用候选按 failoverGroup 限定分组，
  // 组内没有备用时 yt2/us2 为空，payload 不含第二节点，故障切换自然不发生。
  const settings = SettingsStore.load(context);
  let ytBackupPool = ytPool;
  let usBackupPool = usList;
  if (settings.failoverGroup.length > 0) {
    ytBackupPool = filterByGroup(ytPool, settings.failoverGroup);
    usBackupPool = filterByGroup(usList, settings.failoverGroup);
    if (pickSecondBest(ytBackupPool, yt.name, US_FALLBACK, yt.id).name.length === 0 &&
      pickSecondBest(usBackupPool, us.name, US_FALLBACK, us.id).name.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'failover group %{public}s has no backup', settings.failoverGroup);
      writePrepareHint(context, `分组「${settings.failoverGroup}」内无备用节点`);
    }
  }
  let yt2 = CONNECTION_POLICY.autoFailoverEnabled(context) ?
    pickSecondBest(ytBackupPool, yt.name, US_FALLBACK, yt.id) : new NodeRecord();
  let us2 = CONNECTION_POLICY.autoFailoverEnabled(context) ?
    pickSecondBest(usBackupPool, us.name, US_FALLBACK, us.id) : new NodeRecord();
  if (CONNECTION_POLICY.autoFailoverEnabled(context) && (yt2.name.length === 0 || us2.name.length === 0)) {
    await pingBackupCandidates(context, ytBackupPool, yt);
    await pingBackupCandidates(context, usBackupPool, us);
    yt2 = pickSecondBest(ytBackupPool, yt.name, US_FALLBACK, yt.id);
    us2 = pickSecondBest(usBackupPool, us.name, US_FALLBACK, us.id);
  }
  // Phase C2：用户分流规则随 payload 下发（XrayRuntime 注入规则链）。
  const userRules = UserRuleStore.enabledRoutes(context);
  const ytGroup = yt.group;
  const usGroup = us.group;
  StatusStore.writeText(context, OUTBOUND_FILE,
    annotateRolePolicy(buildSplitOutboundPayload(yt, us, yt2, us2, settings.routeMode, userRules, ytGroup, usGroup), context));
  StatusStore.writeNodeMetaStaging(context, splitMetaJson(yt, us, yt2, us2));
  const summary =
    `通用 ${shortNodeName(yt.name)}${msSuffix(yt)} · ChatGPT ${shortNodeName(us.name)}${msSuffix(us)}`;
  hilog.info(LOG_DOMAIN, LOG_TAG, 'yt/us %{public}s yt2=%{public}s us2=%{public}s',
    summary, shortNodeName(yt2.name), shortNodeName(us2.name));
  return summary;
}

async function prepareFreeSingle(context: common.Context): Promise<string> {
  const settings = SettingsStore.load(context);
  if (settings.singleNodeId.length > 0) {
    await discoverBackupsForId(context, settings.singleNodeId);
    const manual = prepareManualPlan(context, settings.singleNodeId);
    if (manual.length > 0) { return manual; }
    throw new Error('选定节点不存在或暂不支持连接，请重新选择节点。');
  }
  const nodes = NodeStore.loadNodes(context).filter((node: StoredNode) => nodeUsableForSplit(storedToRecord(node)));
  if (nodes.length === 0) { throw new Error('请先导入可连接的节点'); }
  const previous = StatusStore.readNodeMeta(context);
  let selected = nodes.find((node: StoredNode) => node.name === (previous.ytName || previous.name));
  if (selected === undefined) {
    const pool = nodes.map((node: StoredNode) => storedToRecord(node));
    await pingAll(pool);
    persistPingResults(context, nodes, pool);
    const fastest = pickFastestNode(pool, []);
    selected = nodes.find((node: StoredNode) => node.name === fastest.name) ?? nodes[0];
  }
  await discoverBackupsForId(context, selected.id);
  return prepareManualPlan(context, selected.id);
}

async function discoverBackupsForId(context: common.Context, nodeId: string): Promise<void> {
  if (!CONNECTION_POLICY.autoFailoverEnabled(context) || nodeId.length === 0) {
    return;
  }
  const stored = NodeStore.loadNodes(context);
  let current: NodeRecord | null = null;
  for (let i = 0; i < stored.length; i++) {
    if (stored[i].id === nodeId) {
      current = storedToRecord(stored[i]);
      break;
    }
  }
  if (current === null) {
    return;
  }
  const settings = SettingsStore.load(context);
  if (pickManualBackup(context, current, settings.failoverGroup).name.length > 0) {
    return;
  }
  const pool: NodeRecord[] = [];
  const group = settings.failoverGroup;
  for (let i = 0; i < stored.length; i++) {
    const rec = storedToRecord(stored[i]);
    if (group.length > 0 && rec.group !== group) {
      continue;
    }
    pool.push(rec);
  }
  await pingBackupCandidates(context, pool, current);
}

function persistPingResults(context: common.Context, stored: StoredNode[], probed: NodeRecord[]): void {
  for (let i = 0; i < probed.length; i++) {
    const rec = probed[i];
    for (let j = 0; j < stored.length; j++) {
      if ((rec.id.length > 0 && stored[j].id === rec.id) || (rec.id.length === 0 && stored[j].name === rec.name)) {
        NodeStore.updateLatency(context, stored[j].id, rec.latencyMs, rec.latencyText);
        stored[j].latencyMs = rec.latencyMs;
        stored[j].latencyText = rec.latencyText;
        stored[j].latencyAt = rec.latencyAt;
        break;
      }
    }
  }
}

function pickManualBackup(context: common.Context, current: NodeRecord, failoverGroup: string): NodeRecord {
  const stored: StoredNode[] = NodeStore.loadNodes(context);
  const pool: NodeRecord[] = [];
  const now = Date.now();
  for (let i = 0; i < stored.length; i++) {
    const rec = storedToRecord(stored[i]);
    if (!nodeUsableForSplit(rec) || sameStoredNode(rec, current)) {
      continue;
    }
    if (failoverGroup.length > 0 && rec.group !== failoverGroup) {
      continue;
    }
    if (!hasFreshLatency(rec.latencyMs, rec.latencyAt, now)) {
      continue;
    }
    pool.push(rec);
  }
  return pickSecondBest(pool, current.name, [], current.id, now);
}

const MAX_BACKUP_PROBES: number = 3;

async function pingBackupCandidates(context: common.Context, pool: NodeRecord[], current: NodeRecord): Promise<void> {
  const now = Date.now();
  const need: NodeRecord[] = [];
  for (let i = 0; i < pool.length && need.length < MAX_BACKUP_PROBES; i++) {
    if (sameStoredNode(pool[i], current) || !nodeUsableForSplit(pool[i])) {
      continue;
    }
    if (hasFreshLatency(pool[i].latencyMs, pool[i].latencyAt, now)) {
      continue;
    }
    need.push(pool[i]);
  }
  if (need.length === 0) {
    return;
  }
  await pingAll(need);
  persistPingResults(context, NodeStore.loadNodes(context), need);
}

function sameStoredNode(left: NodeRecord, right: NodeRecord): boolean {
  if (left.id.length > 0 && right.id.length > 0) {
    return left.id === right.id;
  }
  return left.name.length > 0 && left.name === right.name;
}

function storedToRecord(node: StoredNode): NodeRecord {
  const rec = new NodeRecord();
  rec.id = node.id;
  rec.name = node.name;
  rec.region = node.region;
  rec.server = node.server;
  rec.port = node.port;
  rec.protocol = node.protocol;
  rec.outboundJson = node.outboundJson;
  rec.group = node.group;
  rec.latencyMs = node.latencyMs;
  rec.latencyText = node.latencyText;
  rec.latencyAt = node.latencyAt;
  return rec;
}

function filterByGroup(nodes: NodeRecord[], group: string): NodeRecord[] {
  const list: NodeRecord[] = [];
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].group === group) {
      list.push(nodes[i]);
    }
  }
  return list;
}

function msSuffix(node: NodeRecord): string {
  if (node.latencyMs >= 0) {
    return ` ${node.latencyMs}ms`;
  }
  return '';
}

async function pingAll(nodes: NodeRecord[]): Promise<void> {
  for (let start = 0; start < nodes.length; start += PING_BATCH) {
    const jobs: Array<Promise<void>> = [];
    const end = Math.min(start + PING_BATCH, nodes.length);
    for (let i = start; i < end; i++) {
      jobs.push(pingOne(nodes[i]));
    }
    await Promise.all(jobs);
  }
}

function reusableNode(nodes: NodeRecord[], name: string): NodeRecord | null {
  if (name.length === 0) { return null; }
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].name === name && nodeUsableForSplit(nodes[i])) { return nodes[i]; }
  }
  return null;
}

async function pingOne(node: NodeRecord): Promise<void> {
  const result = await tcpConnectCanary(node.server, node.port, PING_TIMEOUT_MS);
  if (result.ok) {
    node.latencyMs = result.elapsedMs;
    node.latencyText = `${result.elapsedMs}ms`;
    node.latencyAt = Date.now();
    return;
  }
  node.latencyMs = -1;
  node.latencyText = '超时';
  node.latencyAt = 0;
}
