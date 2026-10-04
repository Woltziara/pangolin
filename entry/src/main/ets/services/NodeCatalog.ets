import { hasFreshLatency } from '../core/BackupSelection';
import { outboundIsRunnable } from '../core/OutboundReady';
import { UserRuleRoute } from '../core/UserRuleMap';

export class NodeRecord {
  id: string = '';
  name: string = '';
  region: string = '';
  server: string = '';
  port: number = 0;
  protocol: string = '';
  outboundJson: string = '';
  group: string = '';
  latencyText: string = '';
  latencyMs: number = -1;
  latencyAt: number = 0;
}

export function parseNodeCatalog(raw: string): NodeRecord[] {
  const list: NodeRecord[] = [];
  try {
    const parsed = JSON.parse(raw) as Record<string, Object>;
    const arr = parsed['nodes'];
    if (arr === undefined || !(arr instanceof Array)) {
      return list;
    }
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i] as Record<string, Object>;
      const rec = new NodeRecord();
      rec.id = asString(item['id'], '');
      rec.name = asString(item['name'], '');
      rec.region = asString(item['region'], '其他');
      rec.server = asString(item['server'], '');
      rec.port = asNumber(item['port'], 0);
      rec.protocol = asString(item['protocol'], 'trojan');
      rec.group = asString(item['group'], '');
      const outbound = item['outbound'];
      if (rec.name.length === 0 || outbound === undefined) {
        continue;
      }
      rec.outboundJson = JSON.stringify(outbound);
      if (rec.outboundJson.length < 20) {
        continue;
      }
      rec.latencyMs = asNumber(item['latencyMs'], -1);
      rec.latencyText = asString(item['latencyText'], '');
      rec.latencyAt = asNumber(item['latencyAt'], 0);
      list.push(rec);
    }
  } catch (error) {
    return list;
  }
  return list;
}

export const REGION_HK: string = '中国香港';
export const REGION_US: string = '美国';

export function nodeUsableForSplit(node: NodeRecord): boolean {
  if (node.outboundJson.length < 20) {
    return false;
  }
  return outboundIsRunnable(node.outboundJson);
}

export function nodesInRegion(nodes: NodeRecord[], region: string): NodeRecord[] {
  const list: NodeRecord[] = [];
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].region === region && nodeUsableForSplit(nodes[i])) {
      list.push(nodes[i]);
    }
  }
  return list;
}

export function shortNodeName(name: string): string {
  const idx = name.indexOf('-流量倍率');
  if (idx > 0) {
    return name.substring(0, idx);
  }
  return name;
}

export function pickFastestNode(nodes: NodeRecord[], fallbackNames: string[]): NodeRecord {
  const empty = new NodeRecord();
  if (nodes.length === 0) {
    return empty;
  }
  let best = empty;
  let bestMs = 1000000;
  for (let i = 0; i < nodes.length; i++) {
    const ms = nodes[i].latencyMs;
    if (ms >= 0 && ms < bestMs) {
      bestMs = ms;
      best = nodes[i];
    }
  }
  if (best.name.length > 0) {
    return best;
  }
  for (let i = 0; i < fallbackNames.length; i++) {
    const want = fallbackNames[i];
    for (let j = 0; j < nodes.length; j++) {
      if (nodes[j].name === want) {
        return nodes[j];
      }
    }
  }
  return nodes[0];
}

function sameNode(node: NodeRecord, firstName: string, firstId: string): boolean {
  if (firstId.length > 0 && node.id.length > 0) {
    return node.id === firstId;
  }
  return node.name.length > 0 && node.name === firstName;
}

export function pickSecondBest(nodes: NodeRecord[], firstName: string, fallbackNames: string[],
  firstId: string = '', now: number = 0): NodeRecord {
  const at = now > 0 ? now : Date.now();
  const rest: NodeRecord[] = [];
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].name.length === 0 || sameNode(nodes[i], firstName, firstId)) {
      continue;
    }
    if (!hasFreshLatency(nodes[i].latencyMs, nodes[i].latencyAt, at)) {
      continue;
    }
    rest.push(nodes[i]);
  }
  if (rest.length === 0) {
    return new NodeRecord();
  }
  return pickFastestNode(rest, fallbackNames);
}

export function nodeMetaJson(node: NodeRecord): string {
  const record: Record<string, Object> = {};
  record['name'] = node.name;
  record['region'] = node.region;
  record['server'] = node.server;
  record['port'] = node.port;
  record['protocol'] = node.protocol;
  return JSON.stringify(record);
}

export function splitMetaJson(yt: NodeRecord, us: NodeRecord, yt2: NodeRecord, us2: NodeRecord): string {
  const record: Record<string, Object> = {};
  record['name'] = `YouTube ${shortNodeName(yt.name)} + ChatGPT ${shortNodeName(us.name)}`;
  record['region'] = `${yt.region}+美国`;
  record['server'] = us.server;
  record['port'] = us.port;
  record['protocol'] = us.protocol;
  record['split'] = true;
  record['ytName'] = yt.name;
  record['hkName'] = yt.name;
  record['usName'] = us.name;
  record['ytMs'] = yt.latencyMs;
  record['usMs'] = us.latencyMs;
  record['yt2Name'] = yt2.name;
  record['us2Name'] = us2.name;
  // Phase C：故障切换标记随 meta 落盘，供首页显示“已切换到备用节点”。
  record['ytFailedOver'] = false;
  record['usFailedOver'] = false;
  return JSON.stringify(record);
}

/** Phase C：固定节点（手动选路）的 meta，split=false，两侧标签同指一个节点。 */
export function singleMetaJson(node: NodeRecord): string {
  const record: Record<string, Object> = {};
  record['name'] = node.name;
  record['region'] = node.region;
  record['server'] = node.server;
  record['port'] = node.port;
  record['protocol'] = node.protocol;
  record['split'] = false;
  record['ytName'] = node.name;
  record['hkName'] = node.name;
  record['usName'] = node.name;
  record['ytFailedOver'] = false;
  record['usFailedOver'] = false;
  return JSON.stringify(record);
}

export function buildSplitOutboundPayload(yt: NodeRecord, us: NodeRecord, yt2: NodeRecord, us2: NodeRecord,
  routeMode: string = '', userRules: Array<UserRuleRoute> = [], ytGroup: string = '',
  usGroup: string = ''): string {
  const rec: Record<string, Object> = {};
  rec['v'] = 3;
  rec['yt'] = JSON.parse(yt.outboundJson);
  rec['us'] = JSON.parse(us.outboundJson);
  rec['ytName'] = yt.name;
  rec['usName'] = us.name;
  rec['ytRegion'] = yt.region;
  rec['usRegion'] = us.region;
  rec['ytFailedOver'] = false;
  rec['usFailedOver'] = false;
  rec['ytNodeId'] = yt.id;
  rec['usNodeId'] = us.id;
  rec['chatgptNodeId'] = us.id;
  rec['generalNodeId'] = yt.id;
  if (routeMode.length > 0) {
    rec['routeMode'] = routeMode;
  }
  if (yt2.name.length > 0 && yt2.outboundJson.length >= 20) {
    rec['yt2'] = JSON.parse(yt2.outboundJson);
    rec['yt2Name'] = yt2.name;
    rec['yt2Region'] = yt2.region;
    rec['yt2Id'] = yt2.id;
  }
  if (us2.name.length > 0 && us2.outboundJson.length >= 20) {
    rec['us2'] = JSON.parse(us2.outboundJson);
    rec['us2Name'] = us2.name;
    rec['us2Region'] = us2.region;
    rec['us2Id'] = us2.id;
  }
  // Phase C2：用户分流规则与两条线路的分组（仅在有规则时落字段，默认路径逐字节不变）。
  attachUserRules(rec, userRules, ytGroup, usGroup);
  return JSON.stringify(rec);
}

/**
 * Phase C：v=4 固定节点 payload。XrayRuntime 把 single 同时映射到
 * proxy / proxy-yt 两个标签，既有规则链不变即可工作。
 */
export function buildSingleOutboundPayload(node: NodeRecord, routeMode: string,
  userRules: Array<UserRuleRoute> = [], nodeGroup: string = '', backup: NodeRecord = new NodeRecord()): string {
  const rec: Record<string, Object> = {};
  rec['v'] = 4;
  rec['single'] = JSON.parse(node.outboundJson);
  rec['singleName'] = node.name;
  rec['singleRegion'] = node.region;
  rec['singleNodeId'] = node.id;
  rec['singleFailedOver'] = false;
  if (backup.outboundJson.length >= 20 && (backup.id.length > 0 ? backup.id !== node.id : backup.name !== node.name)) {
    rec['single2'] = JSON.parse(backup.outboundJson);
    rec['single2Name'] = backup.name;
    rec['single2Region'] = backup.region;
    rec['single2Id'] = backup.id;
  }
  if (routeMode.length > 0) {
    rec['routeMode'] = routeMode;
  }
  attachUserRules(rec, userRules, nodeGroup, nodeGroup);
  return JSON.stringify(rec);
}

/**
 * Phase C2：把 enabled 用户规则写进 payload（XrayRuntime 在 buildRuntimeXrayConfig
 * 里读取并注入规则链）。userRules 为空时不落任何字段——settings.json 无规则 /
 * 默认模式下 payload 与 Phase C2 之前逐字节一致。
 */
function attachUserRules(rec: Record<string, Object>, userRules: Array<UserRuleRoute>, ytGroup: string,
  usGroup: string): void {
  if (userRules.length === 0) {
    return;
  }
  const arr: Array<Record<string, Object>> = [];
  for (let i = 0; i < userRules.length; i++) {
    const item: Record<string, Object> = {};
    item['domain'] = userRules[i].domain;
    item['action'] = userRules[i].action;
    item['groupTag'] = userRules[i].groupTag;
    arr.push(item);
  }
  rec['userRules'] = arr;
  rec['ytGroup'] = ytGroup;
  rec['usGroup'] = usGroup;
}

export function failoverSplitPayload(payload: string, swapYt: boolean, swapUs: boolean): string {
  try {
    const rec = JSON.parse(payload) as Record<string, Object>;
    const version = rec['v'];
    if (typeof version === 'number' && version === 4) {
      if ((swapYt || swapUs) && rec['singleFailedOver'] !== true && rec['single2'] !== undefined) {
        const cur = rec['single'];
        rec['single'] = rec['single2'];
        rec['single2'] = cur;
        const curName = asString(rec['singleName'], '');
        rec['singleName'] = asString(rec['single2Name'], '');
        rec['single2Name'] = curName;
        const curRegion = asString(rec['singleRegion'], '');
        rec['singleRegion'] = asString(rec['single2Region'], '');
        rec['single2Region'] = curRegion;
        const curId = asString(rec['singleNodeId'], '');
        rec['singleNodeId'] = asString(rec['single2Id'], '');
        rec['single2Id'] = curId;
        rec['singleFailedOver'] = true;
        return JSON.stringify(rec);
      }
      return payload;
    }
    if (typeof version !== 'number' || version !== 3) {
      return payload;
    }
    let changed = false;
    if (swapYt && rec['ytFailedOver'] !== true && rec['yt2'] !== undefined) {
      const cur = rec['yt'];
      rec['yt'] = rec['yt2'];
      rec['yt2'] = cur;
      const ytName = asString(rec['ytName'], '');
      rec['ytName'] = asString(rec['yt2Name'], '');
      rec['yt2Name'] = ytName;
      const ytRegion = asString(rec['ytRegion'], '');
      rec['ytRegion'] = asString(rec['yt2Region'], '');
      rec['yt2Region'] = ytRegion;
      const ytId = asString(rec['ytNodeId'], '');
      rec['ytNodeId'] = asString(rec['yt2Id'], '');
      rec['yt2Id'] = ytId;
      rec['generalNodeId'] = rec['ytNodeId'];
      rec['ytFailedOver'] = true;
      changed = true;
    }
    if (swapUs && rec['usFailedOver'] !== true && rec['us2'] !== undefined) {
      const cur = rec['us'];
      rec['us'] = rec['us2'];
      rec['us2'] = cur;
      const usName = asString(rec['usName'], '');
      rec['usName'] = asString(rec['us2Name'], '');
      rec['us2Name'] = usName;
      const usRegion = asString(rec['usRegion'], '');
      rec['usRegion'] = asString(rec['us2Region'], '');
      rec['us2Region'] = usRegion;
      const usId = asString(rec['usNodeId'], '');
      rec['usNodeId'] = asString(rec['us2Id'], '');
      rec['us2Id'] = usId;
      rec['chatgptNodeId'] = rec['usNodeId'];
      rec['usFailedOver'] = true;
      changed = true;
    }
    if (!changed) {
      return payload;
    }
    return JSON.stringify(rec);
  } catch (error) {
    return payload;
  }
}

export function failoverSplitMeta(metaRaw: string, payload: string): string {
  try {
    const rec = JSON.parse(payload) as Record<string, Object>;
    const meta = JSON.parse(metaRaw) as Record<string, Object>;
    if (rec['v'] === 4) {
      const name = asString(rec['singleName'], '');
      if (name.length > 0) {
        meta['name'] = name;
        meta['ytName'] = name;
        meta['hkName'] = name;
        meta['usName'] = name;
      }
      const region = asString(rec['singleRegion'], '');
      if (region.length > 0) {
        meta['region'] = region;
      }
      meta['ytFailedOver'] = rec['singleFailedOver'] === true;
      meta['usFailedOver'] = rec['singleFailedOver'] === true;
      return JSON.stringify(meta);
    }
    const ytName = asString(rec['ytName'], '');
    const usName = asString(rec['usName'], '');
    if (ytName.length > 0) {
      meta['ytName'] = ytName;
      meta['hkName'] = ytName;
    }
    if (usName.length > 0) {
      meta['usName'] = usName;
    }
    const ytRegion = asString(rec['ytRegion'], '');
    if (ytName.length > 0 || usName.length > 0) {
      meta['name'] = `YouTube ${shortNodeName(ytName)} + ChatGPT ${shortNodeName(usName)}`;
    }
    if (ytRegion.length > 0) {
      meta['region'] = `${ytRegion}+美国`;
    }
    // Phase C：把故障切换标记透传到 meta，首页据此提示“已切换到备用节点”。
    meta['ytFailedOver'] = rec['ytFailedOver'] === true;
    meta['usFailedOver'] = rec['usFailedOver'] === true;
    return JSON.stringify(meta);
  } catch (error) {
    return metaRaw;
  }
}

export function backupOutboundJson(payload: string, swapYt: boolean, swapUs: boolean): string {
  if (swapYt) {
    return backupOutboundFor(payload, 'yt');
  }
  if (swapUs) {
    return backupOutboundFor(payload, 'us');
  }
  return backupOutboundFor(payload, 'single');
}

export function backupOutboundFor(payload: string, role: string): string {
  try {
    const rec = JSON.parse(payload) as Record<string, Object>;
    if (rec['v'] === 4 || role === 'single') {
      const backup = rec['single2'];
      return backup !== undefined ? JSON.stringify(backup) : '';
    }
    if (role === 'yt') {
      const backup = rec['yt2'];
      return backup !== undefined ? JSON.stringify(backup) : '';
    }
    if (role === 'us') {
      const backup = rec['us2'];
      return backup !== undefined ? JSON.stringify(backup) : '';
    }
  } catch (error) {
    return '';
  }
  return '';
}

export function endpointOfOutbound(outboundJson: string): NodeRecord {
  const rec = new NodeRecord();
  try {
    const outbound = JSON.parse(outboundJson) as Record<string, Object>;
    const settingsValue = outbound['settings'];
    if (settingsValue === undefined || typeof settingsValue !== 'object') {
      return rec;
    }
    const settings = settingsValue as Record<string, Object>;
    const block = firstEndpointBlock(settings['vnext']);
    const server = block !== null ? block : firstEndpointBlock(settings['servers']);
    if (server === null) {
      return rec;
    }
    rec.server = asString(server['address'], '');
    rec.port = asNumber(server['port'], 0);
    rec.outboundJson = outboundJson;
  } catch (error) {
    return rec;
  }
  return rec;
}

function firstEndpointBlock(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || !(value instanceof Array) || value.length === 0) {
    return null;
  }
  const first: Object = value[0];
  if (first === null || typeof first !== 'object') {
    return null;
  }
  return first as Record<string, Object>;
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function asNumber(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number' && value > 0) {
    return value;
  }
  return fallback;
}
