export const PHASE_IDLE: string = 'IDLE';
export const PHASE_STARTING: string = 'STARTING';
export const PHASE_VPN_CREATED: string = 'VPN_CREATED';
export const PHASE_PROBE_SNIFFING: string = 'PROBE_SNIFFING';
export const PHASE_CORE_RUNNING: string = 'CORE_RUNNING';
export const PHASE_FORWARDER_RUNNING: string = 'FORWARDER_RUNNING';
export const PHASE_CANARY_OK: string = 'CANARY_OK';
export const PHASE_UNPROVEN: string = 'UNPROVEN';
export const PHASE_DEGRADED_UNPROVEN: string = 'DEGRADED_UNPROVEN';
export const PHASE_DEGRADED: string = 'DEGRADED';
export const PHASE_RECONNECTING: string = 'RECONNECTING';
export const PHASE_ERROR: string = 'ERROR';
export const PHASE_STOPPED: string = 'STOPPED';
export const PHASE_STALE: string = 'STALE';
export const PHASE_POISONED: string = 'POISONED';

export class DataplaneStatus {
  phase: string = PHASE_IDLE;
  honestLabel: string = '未连接';
  tunFd: number = -1;
  vpnCreated: boolean = false;
  tunFdValid: boolean = false;
  tunRxBytes: number = 0;
  tunTxBytes: number = 0;
  tunRxPackets: number = 0;
  tunTxPackets: number = 0;
  tunDropped: number = 0;
  tunReceiving: boolean = false;
  dnsOk: boolean = false;
  forwarderOk: boolean = false;
  protectOk: boolean = false;
  nodeTcpOk: boolean = false;
  canaryOk: boolean = false;
  socksCanaryOk: boolean = false;
  directOk: boolean = false;
  proxyOk: boolean = false;
  uploadBytes: number = 0;
  downloadBytes: number = 0;
  lastError: string = '';
  lastCanary: string = '';
  nodeName: string = '';
  nodeRegion: string = '';
  reconnectCount: number = 0;
  at: number = 0;
  sessionId: string = '';
  generation: string = '';
  mode: string = '';
  sniffLog: string = '';
  sessionRevision: number = 0;
  evidenceAt: number = 0;
  lastSampleTunBytes: number = 0;
  lastSampleHevBytes: number = 0;
  lastSampleTunRx: number = 0;
  lastSampleTunTx: number = 0;
  lastSampleHevUp: number = 0;
  lastSampleHevDown: number = 0;
  evidenceRid: string = '';
  accessOffset: number = -1;
  probeRevision: number = 0;
  probeEpoch: number = 0;
  nativePoisoned: boolean = false;
  commandEpoch: number = 0;
  desiredRunning: boolean = false;
  lastProvenRid: string = '';
  probePending: boolean = false;
  probeGoogleUrl: string = '';
  probeDirectUrl: string = '';
  probeIssuedAt: number = 0;
  selfProbe: boolean = false;
  fetchGoogleHttp: number = 0;
  fetchDirectHttp: number = 0;
  fetchDnsOk: boolean = false;
  fetchPid: string = '';
  fetchUid: string = '';
  fetchBundle: string = '';
  xrayRunning: boolean = false;
  connectionHealth: string = '';
  lastReachableAt: number = 0;
  healthCheckedAt: number = 0;
  healthLastOutcome: string = '';
  healthGeneration: string = '';
  healthRevision: number = 0;
  payloadDigest: string = '';
}

export function honestLabelOf(status: DataplaneStatus): string {
  if (status.phase === PHASE_CANARY_OK && status.canaryOk && status.forwarderOk) {
    return '数据面可用';
  }
  if (status.phase === PHASE_DEGRADED_UNPROVEN) {
    return '路由证据待核验，不代表连接已中断';
  }
  if (status.phase === PHASE_UNPROVEN) {
    return '本轮尚未完成路由证据核验';
  }
  if (status.phase === PHASE_DEGRADED) {
    return '数据面降级，正在恢复';
  }
  if (status.phase === PHASE_RECONNECTING) {
    return '正在重连，不要把它当成在线';
  }
  if (status.phase === PHASE_ERROR) {
    return '数据面失败';
  }
  if (status.phase === PHASE_POISONED || status.nativePoisoned) {
    return '内核停不干净，已禁止重启';
  }
  if (status.phase === PHASE_FORWARDER_RUNNING) {
    return '转发已启动，等待探测';
  }
  if (status.phase === PHASE_CORE_RUNNING) {
    return '内核已启动，转发未确认';
  }
  if (status.phase === PHASE_PROBE_SNIFFING) {
    return '接管探针已打开，正在读 TUN 包（不含 UID）';
  }
  if (status.phase === PHASE_VPN_CREATED) {
    return '系统已授权隧道，尚未转发';
  }
  if (status.phase === PHASE_STARTING) {
    return '正在启动';
  }
  if (status.phase === PHASE_STOPPED) {
    return '已停止';
  }
  if (status.phase === PHASE_STALE) {
    return '状态过期，不能当成已断开';
  }
  return '未连接';
}

export function serializeStatus(status: DataplaneStatus): string {
  const record: Record<string, Object> = {};
  record['phase'] = status.phase;
  record['honestLabel'] = status.honestLabel;
  record['tunFd'] = status.tunFd;
  record['vpnCreated'] = status.vpnCreated;
  record['tunFdValid'] = status.tunFdValid;
  record['tunRxBytes'] = status.tunRxBytes;
  record['tunTxBytes'] = status.tunTxBytes;
  record['tunRxPackets'] = status.tunRxPackets;
  record['tunTxPackets'] = status.tunTxPackets;
  record['tunDropped'] = status.tunDropped;
  record['tunReceiving'] = status.tunReceiving;
  record['dnsOk'] = status.dnsOk;
  record['forwarderOk'] = status.forwarderOk;
  record['protectOk'] = status.protectOk;
  record['nodeTcpOk'] = status.nodeTcpOk;
  record['canaryOk'] = status.canaryOk;
  record['socksCanaryOk'] = status.socksCanaryOk;
  record['directOk'] = status.directOk;
  record['proxyOk'] = status.proxyOk;
  record['uploadBytes'] = status.uploadBytes;
  record['downloadBytes'] = status.downloadBytes;
  record['lastError'] = status.lastError;
  record['lastCanary'] = status.lastCanary;
  record['nodeName'] = status.nodeName;
  record['nodeRegion'] = status.nodeRegion;
  record['reconnectCount'] = status.reconnectCount;
  record['at'] = status.at;
  record['sessionId'] = status.sessionId;
  record['generation'] = status.generation;
  record['mode'] = status.mode;
  record['sniffLog'] = status.sniffLog;
  record['sessionRevision'] = status.sessionRevision;
  record['evidenceAt'] = status.evidenceAt;
  record['lastSampleTunBytes'] = status.lastSampleTunBytes;
  record['lastSampleHevBytes'] = status.lastSampleHevBytes;
  record['lastSampleTunRx'] = status.lastSampleTunRx;
  record['lastSampleTunTx'] = status.lastSampleTunTx;
  record['lastSampleHevUp'] = status.lastSampleHevUp;
  record['lastSampleHevDown'] = status.lastSampleHevDown;
  record['evidenceRid'] = status.evidenceRid;
  record['accessOffset'] = status.accessOffset;
  record['probeRevision'] = status.probeRevision;
  record['probeEpoch'] = status.probeEpoch;
  record['nativePoisoned'] = status.nativePoisoned;
  record['commandEpoch'] = status.commandEpoch;
  record['desiredRunning'] = status.desiredRunning;
  record['lastProvenRid'] = status.lastProvenRid;
  record['probePending'] = status.probePending;
  record['probeGoogleUrl'] = status.probeGoogleUrl;
  record['probeDirectUrl'] = status.probeDirectUrl;
  record['probeIssuedAt'] = status.probeIssuedAt;
  record['selfProbe'] = status.selfProbe;
  record['fetchGoogleHttp'] = status.fetchGoogleHttp;
  record['fetchDirectHttp'] = status.fetchDirectHttp;
  record['fetchDnsOk'] = status.fetchDnsOk;
  record['fetchPid'] = status.fetchPid;
  record['fetchUid'] = status.fetchUid;
  record['fetchBundle'] = status.fetchBundle;
  record['xrayRunning'] = status.xrayRunning;
  record['connectionHealth'] = status.connectionHealth;
  record['lastReachableAt'] = status.lastReachableAt;
  record['healthCheckedAt'] = status.healthCheckedAt;
  record['healthLastOutcome'] = status.healthLastOutcome;
  record['healthGeneration'] = status.healthGeneration;
  record['healthRevision'] = status.healthRevision;
  record['payloadDigest'] = status.payloadDigest;
  return JSON.stringify(record);
}

export function parseStatus(raw: string): DataplaneStatus {
  const status = new DataplaneStatus();
  try {
    const parsed = JSON.parse(raw) as Record<string, Object>;
    status.phase = asString(parsed['phase'], PHASE_IDLE);
    status.honestLabel = asString(parsed['honestLabel'], '未连接');
    status.tunFd = asNumber(parsed['tunFd'], -1);
    status.vpnCreated = asBool(parsed['vpnCreated']);
    status.tunFdValid = asBool(parsed['tunFdValid']);
    status.tunRxBytes = asNumber(parsed['tunRxBytes'], 0);
    status.tunTxBytes = asNumber(parsed['tunTxBytes'], 0);
    status.tunRxPackets = asNumber(parsed['tunRxPackets'], 0);
    status.tunTxPackets = asNumber(parsed['tunTxPackets'], 0);
    status.tunDropped = asNumber(parsed['tunDropped'], 0);
    status.tunReceiving = asBool(parsed['tunReceiving']);
    status.dnsOk = asBool(parsed['dnsOk']);
    status.forwarderOk = asBool(parsed['forwarderOk']);
    status.protectOk = asBool(parsed['protectOk']);
    status.nodeTcpOk = asBool(parsed['nodeTcpOk']);
    status.canaryOk = asBool(parsed['canaryOk']);
    status.socksCanaryOk = asBool(parsed['socksCanaryOk']);
    status.directOk = asBool(parsed['directOk']);
    status.proxyOk = asBool(parsed['proxyOk']);
    status.uploadBytes = asNumber(parsed['uploadBytes'], 0);
    status.downloadBytes = asNumber(parsed['downloadBytes'], 0);
    status.lastError = asString(parsed['lastError'], '');
    status.lastCanary = asString(parsed['lastCanary'], '');
    status.nodeName = asString(parsed['nodeName'], '');
    status.nodeRegion = asString(parsed['nodeRegion'], '');
    status.reconnectCount = asNumber(parsed['reconnectCount'], 0);
    status.at = asNumber(parsed['at'], 0);
    status.sessionId = asString(parsed['sessionId'], '');
    status.generation = asString(parsed['generation'], '');
    status.mode = asString(parsed['mode'], '');
    status.sniffLog = asString(parsed['sniffLog'], '');
    status.sessionRevision = asNumber(parsed['sessionRevision'], 0);
    status.evidenceAt = asNumber(parsed['evidenceAt'], 0);
    status.lastSampleTunBytes = asNumber(parsed['lastSampleTunBytes'], 0);
    status.lastSampleHevBytes = asNumber(parsed['lastSampleHevBytes'], 0);
    status.lastSampleTunRx = asNumber(parsed['lastSampleTunRx'], 0);
    status.lastSampleTunTx = asNumber(parsed['lastSampleTunTx'], 0);
    status.lastSampleHevUp = asNumber(parsed['lastSampleHevUp'], 0);
    status.lastSampleHevDown = asNumber(parsed['lastSampleHevDown'], 0);
    status.evidenceRid = asString(parsed['evidenceRid'], '');
    status.accessOffset = asNumber(parsed['accessOffset'], -1);
    status.probeRevision = asNumber(parsed['probeRevision'], 0);
    status.probeEpoch = asNumber(parsed['probeEpoch'], 0);
    status.nativePoisoned = asBool(parsed['nativePoisoned']);
    status.commandEpoch = asNumber(parsed['commandEpoch'], 0);
    status.desiredRunning = asBool(parsed['desiredRunning']);
    status.lastProvenRid = asString(parsed['lastProvenRid'], '');
    status.probePending = asBool(parsed['probePending']);
    status.probeGoogleUrl = asString(parsed['probeGoogleUrl'], '');
    status.probeDirectUrl = asString(parsed['probeDirectUrl'], '');
    status.probeIssuedAt = asNumber(parsed['probeIssuedAt'], 0);
    status.selfProbe = asBool(parsed['selfProbe']);
    status.fetchGoogleHttp = asNumber(parsed['fetchGoogleHttp'], 0);
    status.fetchDirectHttp = asNumber(parsed['fetchDirectHttp'], 0);
    status.fetchDnsOk = asBool(parsed['fetchDnsOk']);
    status.fetchPid = asString(parsed['fetchPid'], '');
    status.fetchUid = asString(parsed['fetchUid'], '');
    status.fetchBundle = asString(parsed['fetchBundle'], '');
    status.xrayRunning = asBool(parsed['xrayRunning']);
    status.connectionHealth = asString(parsed['connectionHealth'], '');
    status.lastReachableAt = asNumber(parsed['lastReachableAt'], 0);
    status.healthCheckedAt = asNumber(parsed['healthCheckedAt'], 0);
    status.healthLastOutcome = asString(parsed['healthLastOutcome'], '');
    status.healthGeneration = asString(parsed['healthGeneration'], '');
    status.healthRevision = asNumber(parsed['healthRevision'], 0);
    status.payloadDigest = asString(parsed['payloadDigest'], '');
    const phaseRaw = parsed['phase'];
    if (typeof phaseRaw !== 'string' || phaseRaw.length < 1) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '状态文件缺 phase，不能当成空闲';
      status.lastError = 'status missing phase';
    }
  } catch (error) {
    status.phase = PHASE_ERROR;
    status.honestLabel = '状态文件读失败';
    status.lastError = JSON.stringify(error);
  }
  return status;
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string') {
    return value;
  }
  return fallback;
}

function asNumber(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number') {
    return value;
  }
  return fallback;
}

function asBool(value: Object | undefined): boolean {
  return value === true;
}
