import { AppliedPolicy } from '../services/AppliedPolicy';
import { AppRouteRuntime } from '../services/AppRouteRuntime';
import { RuntimeJournal } from '../services/RuntimeJournal';
import { CONNECTION_POLICY } from '../services/ConnectionPolicy';
import { runtimeMayPromoteBackup } from '../core/ChannelPolicy';
import { emptyLeg, legShouldPromote, LINE_HEALTH_HOST, LINE_HEALTH_HOST_B, LegObservation, probeOutboundTag, recordProbeResult, trialLegsProven } from '../core/LineHealth';
import { digestText, META_STAGING_FILE } from '../core/OutboundCommit';
import { NODE_LATENCY_TEST } from '../services/NodeLatencyTest';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import Want from '@ohos.app.ability.Want';
import { buildHevTunConfigYaml } from '../core/HevTunConfig';
import { buildRuntimeXrayConfig, NODE_META_FILE, newSocksSession, parseNodeMeta, SocksSession } from '../core/XrayRuntime';
import { outboundTimingEvents, chatAppTimingEvents } from '../core/OutboundTiming';
import { withSystemResolvedNodes } from '../net/NodeAddressResolver';
import { socksHttpCanary, tcpConnectCanary } from '../net/DataplaneCanary';
import {
  DataplaneStatus,
  serializeStatus,
  honestLabelOf,
  PHASE_CANARY_OK,
  PHASE_CORE_RUNNING,
  PHASE_DEGRADED,
  PHASE_DEGRADED_UNPROVEN,
  PHASE_ERROR,
  PHASE_FORWARDER_RUNNING,
  PHASE_POISONED,
  PHASE_UNPROVEN,
  PHASE_RECONNECTING,
  PHASE_STARTING,
  PHASE_STOPPED,
  PHASE_VPN_CREATED
} from '../net/DataplaneStatus';
import { readVpnTunCounters, TunCounters } from '../net/ProcNet';
import {
  NativeResult,
  RuntimeStats,
  abortPoisonedNative,
  ackProtectFd,
  claimProtectFd,
  clearProtectCallback,
  getNativeStats,
  setProtectCallback,
  startNativeHevTun,
  startNativeXray,
  stopNativeTun2Socks,
  stopNativeXray,
  stopNativeXrayOwned
} from '../native/TunnelNative';
import { EventStore } from '../services/EventStore';
import { HuksSecretStore } from '../services/HuksSecretStore';
import { backupOutboundFor, endpointOfOutbound, failoverSplitMeta, failoverSplitPayload } from '../services/NodeCatalog';
import { SettingsStore } from '../services/SettingsStore';
import { LATENCY_PROBE } from '../services/LatencyProbe';
import { updateConnectionHealth } from '../net/ConnectionHealth';
import { NODE_ENDPOINT_PROBE } from '../net/NodeEndpointProbe';
import { OUTBOUND_FILE, StatusStore } from '../services/StatusStore';
import {
  BUNDLE_NAME,
  createTunnelVpnConfig,
  MODE_FULL,
  MODE_PROBE_BROWSER,
  MODE_PROBE_SELF,
  trustedAppsForMode,
  VPN_COMMAND_KEY,
  VPN_COMMAND_STOP,
  VPN_GENERATION_KEY,
  VPN_MODE_KEY,
  VPN_MTU
} from './VpnConstants';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'TunnelVpn';
const BROWSER_BUNDLE: string = 'com.huawei.hmos.browser';
const CANARY_INTERVAL_MS: number = 480000;
const SUPERVISOR_INTERVAL_MS: number = 15000;
const CANARY_FAIL_LIMIT: number = 3;
const NODE_FAIL_LIMIT: number = 2;
const CORE_RESTART_LIMIT: number = 2;
const PROBE_GRACE_MS: number = 20000;

class VpnCommand {
  token: number = 0;
  kind: string = '';
  generation: string = '';
  mode: string = MODE_FULL;
  outboundTrace: boolean = false;
  nodeSystemDns: boolean = true;
}

export default class TunnelVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private cleaningUp: boolean = false;
  private canaryTimerId: number = -1;
  private supervisorTimerId: number = -1;
  private status: DataplaneStatus = new DataplaneStatus();
  private failStreak: number = 0;
  private generalLeg: LegObservation = emptyLeg('proxy-yt');
  private proxyLeg: LegObservation = emptyLeg('proxy');
  private ytFailoverLocked: boolean = false;
  private usFailoverLocked: boolean = false;
  private coreRestarts: number = 0;
  private lastTunRx: number = 0;
  private polling: boolean = false;
  private generation: string = '';
  private mode: string = MODE_FULL;
  private socks: SocksSession = new SocksSession();
  private appRoutes: AppRouteRuntime | null = null;
  // Aggregate only; never write a file in the socket-protection callback.
  private protectDiagnostics: Record<string, Object> = {
    'requests': 0, 'invalid': 0, 'unavailable': 0, 'claimRejected': 0,
    'apiRejected': 0, 'apiSucceeded': 0, 'lastErrorCode': 0
  };
  private outboundJson: string = '';
  private xrayOwnerSeq: number = 0;
  private outboundTrace: boolean = false;
  private nodeSystemDns: boolean = true;
  private networkWasLost: boolean = false;
  private lastAvailableNetId: number = -1;
  private addressRefreshAttempted: boolean = false;
  private observedHealthAt: number = 0;
  private healthFailureReceipts: number = 0;
  private lastHealthCanaryAt: number = 0;
  private cancelled: boolean = false;
  private recoverInFlight: boolean = false;
  private startInFlight: boolean = false;
  private netConn: connection.NetConnection | null = null;
  private everProven: boolean = false;
  private createEpoch: number = 0;
  private pendingStart: boolean = false;
  private pendingGeneration: string = '';
  private pendingMode: string = '';
  private desiredRunning: boolean = false;
  private commandEpoch: number = 0;
  private startFlightEpoch: number = 0;
  private lastProvenRid: string = '';
  private probeFailCount: number = 0;
  private latestCommand: VpnCommand | null = null;
  private committedToken: number = 0;
  private destroyInFlight: boolean = false;
  // Phase C：故障切换用户开关。在 startTunnel 读取一次并缓存整个会话，
  // 不在 canary 周期里反复读盘——canary/恢复时序经过 soak 验证，中途插入
  // 文件 IO 有 timing 风险；因此开关切换对下一次连接生效（设置页有说明）。
  private failoverEnabled: boolean = true;
  private failoverTrial: boolean = false;
  private failoverTrialYt: boolean = false;
  private failoverTrialUs: boolean = false;
  private lastGoogleOk: boolean = false;
  private lastYoutubeOk: boolean = false;
  private lastLineHealthOk: boolean = false;
  private lastLineHealthBOk: boolean = false;
  private failoverGroup: string = '';

  onCreate(want: Want): void {
    // A diagnostic request must never start or restart a stopped VPN.
    if (this.wantString(want, VPN_COMMAND_KEY, '').startsWith('diagnose-')) {
      return;
    }
    this.cancelled = false;
    this.recoverInFlight = false;
    this.startInFlight = false;
    this.generation = this.wantString(want, VPN_GENERATION_KEY, Date.now().toString());
    this.mode = this.wantString(want, VPN_MODE_KEY, MODE_FULL);
    this.status.sessionId = this.generation;
    this.status.generation = this.generation;
    this.status.mode = this.mode;
    this.status.sessionRevision = 1;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onCreate gen=%{public}s mode=%{public}s', this.generation, this.mode);
    if (this.isStopCommand(want)) {
      this.enqueue('stop', this.wantString(want, VPN_GENERATION_KEY, this.generation), this.mode);
      return;
    }
    this.enqueue('start', this.generation, this.mode, this.wantString(want, 'outboundTrace', '') === 'true',
      this.wantString(want, 'nodeSystemDns', 'true') !== 'false');
  }

  onRequest(want: Want, startId: number): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onRequest %{public}d', startId);
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-node-latency') {
      const generation = this.wantString(want, VPN_GENERATION_KEY, '');
      if (generation === this.generation && this.desiredRunning && !this.cleaningUp) {
        NODE_LATENCY_TEST.run(this.context, this.wantString(want, 'runId', ''), generation,
          this.wantString(want, 'selectedNodeId', '')).catch(() => {});
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-connection-status') {
      const requestedGeneration = this.wantString(want, 'statusGeneration', '');
      if (this.generation.length > 0) {
        if (this.generation === requestedGeneration) { this.forcePublish(); }
      } else {
        const stats = getNativeStats();
        const previous = StatusStore.readStatus(this.context);
        const requestedAt = Number(this.wantString(want, 'statusAt', '0'));
        if (!stats.xrayRunning && !stats.tunRunning && previous.generation === requestedGeneration &&
          previous.at === requestedAt && requestedAt > 0) {
          this.generation = previous.generation;
          this.status = previous;
          this.desiredRunning = false;
          this.resetPlaneTruth();
          this.status.phase = PHASE_STOPPED;
          this.forcePublish();
        }
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-outbound-timing') {
      if (this.wantString(want, VPN_GENERATION_KEY, '') === this.generation && this.outboundTrace &&
        this.desiredRunning && !this.cleaningUp) {
        const report: Record<string, Object> = {};
        report['generation'] = this.generation;
        report['at'] = Date.now();
        report['nodeSystemDns'] = this.nodeSystemDns;
        report['events'] = outboundTimingEvents(StatusStore.readText(this.context, 'xray-timing.log'));
        report['appEvents'] = chatAppTimingEvents(StatusStore.readText(this.context, 'xray-timing.log'));
        StatusStore.writeText(this.context, 'latency-outbound-timing.json', JSON.stringify(report));
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-node-endpoint') {
      const generation = this.wantString(want, VPN_GENERATION_KEY, '');
      const runId = this.wantString(want, 'runId', '');
      if (generation === this.generation && this.desiredRunning && !this.cleaningUp) {
        NODE_ENDPOINT_PROBE.run(this.context, this.outboundJson, generation, runId).catch(() => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'node endpoint diagnostic did not complete');
        });
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-native-socks') {
      const generation = this.wantString(want, VPN_GENERATION_KEY, '');
      const runId = this.wantString(want, 'runId', '');
      if (generation === this.generation && this.desiredRunning && !this.cleaningUp) {
        LATENCY_PROBE.runHttp(this.context, runId, this.socks, true).catch(() => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'native SOCKS diagnostic did not complete');
        });
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-android-endpoint') {
      const generation = this.wantString(want, VPN_GENERATION_KEY, '');
      const runId = this.wantString(want, 'runId', '');
      if (generation === this.generation && this.desiredRunning && !this.cleaningUp) {
        LATENCY_PROBE.runHttp(this.context, runId, this.socks, true, true).catch(() => {});
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '') === 'diagnose-latency') {
      const generation = this.wantString(want, VPN_GENERATION_KEY, '');
      const runId = this.wantString(want, 'runId', '');
      if (generation === this.generation && this.desiredRunning && !this.cleaningUp) {
        LATENCY_PROBE.runSocks(this.context, this.socks, generation, runId).catch(() => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'latency diagnostic did not complete');
        });
      }
      return;
    }
    if (this.wantString(want, VPN_COMMAND_KEY, '').startsWith('diagnose-')) {
      return;
    }
    if (this.isStopCommand(want)) {
      this.enqueue('stop', this.wantString(want, VPN_GENERATION_KEY, this.generation), this.mode);
      return;
    }
    const generation = this.wantString(want, VPN_GENERATION_KEY,
      this.generation.length > 0 ? this.generation : Date.now().toString());
    const mode = this.wantString(want, VPN_MODE_KEY, MODE_FULL);
    this.enqueue('start', generation, mode, this.wantString(want, 'outboundTrace', '') === 'true',
      this.wantString(want, 'nodeSystemDns', 'true') !== 'false');
  }

  private enqueue(kind: string, generation: string, mode: string, outboundTrace: boolean = false,
    nodeSystemDns: boolean = true): void {
    const dns = !outboundTrace || nodeSystemDns;
    if (kind === 'start' && this.latestCommand !== null && this.latestCommand.kind === 'start' &&
      this.latestCommand.generation === generation && this.latestCommand.mode === mode &&
      this.latestCommand.outboundTrace === outboundTrace && this.latestCommand.nodeSystemDns === dns) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'ignore duplicate start command gen=%{public}s token=%{public}d',
        generation, this.latestCommand.token);
      return;
    }
    this.commandEpoch += 1;
    const cmd = new VpnCommand();
    cmd.token = this.commandEpoch;
    cmd.kind = kind;
    cmd.generation = generation;
    cmd.mode = mode;
    cmd.outboundTrace = outboundTrace;
    cmd.nodeSystemDns = dns;
    this.latestCommand = cmd;
    this.status.commandEpoch = cmd.token;
    this.dispatchLatest();
  }

  private isSameStartIntent(cmd: VpnCommand | null, generation: string): boolean {
    return cmd !== null && cmd.kind === 'start' && cmd.generation === generation;
  }

  private dispatchLatest(): void {
    const cmd = this.latestCommand;
    if (cmd === null) {
      return;
    }
    if (cmd.kind === 'stop') {
      this.desiredRunning = false;
      this.cancelled = true;
      this.status.desiredRunning = false;
      if (this.cleaningUp) {
        return;
      }
      this.commitCommand(cmd);
      return;
    }
    if (this.startInFlight || this.cleaningUp || this.recoverInFlight || this.destroyInFlight) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'queue start until in-flight command finishes token=%{public}d kind=%{public}s',
        cmd.token, cmd.kind);
      return;
    }
    this.commitCommand(cmd);
  }

  private commitCommand(cmd: VpnCommand): void {
    if (this.latestCommand === null || this.latestCommand.token !== cmd.token) {
      return;
    }
    this.committedToken = cmd.token;
    this.status.commandEpoch = cmd.token;
    if (cmd.kind === 'stop') {
      if (cmd.generation.length > 0 && this.generation.length > 0 && cmd.generation !== this.generation) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stop token ignored gen=%{public}s current=%{public}s',
          cmd.generation, this.generation);
        return;
      }
      const alreadyDown = !this.status.vpnCreated && this.tunFd < 0 &&
        (this.status.phase === PHASE_STOPPED || this.status.phase === PHASE_ERROR ||
          this.status.phase === PHASE_POISONED);
      this.desiredRunning = false;
      this.pendingStart = false;
      this.pendingGeneration = '';
      this.pendingMode = '';
      this.status.desiredRunning = false;
      if (alreadyDown && !this.cleaningUp) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'stop token already applied');
        return;
      }
      this.requestCleanup('stop command', this.generation);
      return;
    }
    this.desiredRunning = true;
    this.status.desiredRunning = true;
    this.pendingGeneration = cmd.generation;
    this.pendingMode = cmd.mode;
    if (this.status.vpnCreated && this.tunFd >= 0 && !this.cancelled && this.generation === cmd.generation) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'ignore duplicate start token');
      return;
    }
    if (this.status.vpnCreated && this.tunFd >= 0 && this.generation !== cmd.generation) {
      this.pendingStart = true;
      this.requestCleanup('switch session', this.generation);
      return;
    }
    this.beginSession(cmd.generation, cmd.mode, cmd.token);
  }

  private beginSession(generation: string, mode: string, token: number): void {
    this.networkWasLost = false;
    this.lastAvailableNetId = -1;
    this.addressRefreshAttempted = false;
    this.observedHealthAt = 0;
    this.healthFailureReceipts = 0;
    this.lastHealthCanaryAt = 0;
    this.outboundTrace = this.latestCommand !== null && this.latestCommand.token === token &&
      this.latestCommand.outboundTrace;
    this.nodeSystemDns = this.latestCommand !== null && this.latestCommand.token === token &&
      this.latestCommand.nodeSystemDns;
    this.status.connectionHealth = '';
    this.status.lastReachableAt = 0;
    this.status.healthCheckedAt = 0;
    this.status.healthLastOutcome = '';
    this.cancelled = false;
    this.startInFlight = false;
    this.failStreak = 0;
    this.generalLeg = emptyLeg('proxy-yt');
    this.proxyLeg = emptyLeg('proxy');
    this.ytFailoverLocked = false;
    this.usFailoverLocked = false;
    this.clearFailoverTrial();
    this.coreRestarts = 0;
    this.generation = generation;
    this.mode = mode;
    this.status.sessionId = this.generation;
    this.status.generation = this.generation;
    this.status.mode = this.mode;
    this.status.sessionRevision = 1;
    this.status.accessOffset = -1;
    this.status.probeRevision = 0;
    this.status.evidenceRid = '';
    this.status.nativePoisoned = false;
    this.status.commandEpoch = token;
    this.status.desiredRunning = true;
    this.lastProvenRid = '';
    this.status.lastProvenRid = '';
    this.status.probePending = false;
    this.pendingStart = false;
    this.captureBaseline();
    this.startTunnel(token, generation);
  }

  onDestroy(): void {
    // System may destroy this ability without waiting for async cleanup.
    // Cancel is recorded immediately; native stop completion is not proven here.
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onDestroy');
    this.desiredRunning = false;
    this.status.desiredRunning = false;
    this.cancelled = true;
    this.enqueue('stop', this.generation, this.mode);
    this.requestCleanup('onDestroy', this.generation);
  }

  private isStopCommand(want: Want): boolean {
    const value = want.parameters?.[VPN_COMMAND_KEY];
    return value !== undefined && value.toString() === VPN_COMMAND_STOP;
  }

  private wantString(want: Want, key: string, fallback: string): string {
    const value = want.parameters?.[key];
    if (value === undefined) {
      return fallback;
    }
    const text = value.toString();
    return text.length > 0 ? text : fallback;
  }

  private isAlreadyRunning(message: string): boolean {
    return message.indexOf('already running') >= 0;
  }

  private guard(gen: string, rev: number, socksPort: number, where: string): boolean {
    if (this.cancelled || this.cleaningUp || !this.desiredRunning) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'stale %{public}s cancelled', where);
      return false;
    }
    if (this.generation !== gen || this.status.sessionRevision !== rev) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'stale %{public}s gen/rev', where);
      return false;
    }
    if (this.socks.port !== socksPort) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'stale %{public}s socks snapshot %{public}d != %{public}d',
        where, socksPort, this.socks.port);
      return false;
    }
    return true;
  }

  private issueSelfProbe(): string {
    const rid = `s${Date.now()}-${this.commandEpoch}-${util.generateRandomUUID().substring(0, 8)}`;
    const accessRaw = this.readAccessLog();
    const cursor = accessRaw.length;
    this.refreshCounters();
    this.status.lastSampleTunRx = this.status.tunRxBytes;
    this.status.lastSampleTunTx = this.status.tunTxBytes;
    this.status.lastSampleHevUp = this.status.uploadBytes;
    this.status.lastSampleHevDown = this.status.downloadBytes;
    this.status.lastSampleTunBytes = this.status.tunRxBytes + this.status.tunTxBytes;
    this.status.lastSampleHevBytes = this.status.uploadBytes + this.status.downloadBytes;
    this.status.evidenceRid = rid;
    this.status.accessOffset = cursor;
    this.status.probeRevision = this.status.sessionRevision;
    this.status.probeEpoch = this.createEpoch;
    this.status.evidenceAt = 0;
    this.status.probePending = true;
    this.status.selfProbe = true;
    this.status.probeGoogleUrl = `http://www.google.com/generate_204?rid=${rid}`;
    this.status.probeDirectUrl = `https://www.qq.com/?rid=${rid}`;
    this.status.probeIssuedAt = Date.now();
    this.status.fetchGoogleHttp = 0;
    this.status.fetchDirectHttp = 0;
    this.status.fetchDnsOk = false;
    const issued: Record<string, Object> = {};
    issued['rid'] = rid;
    issued['generation'] = this.generation;
    issued['revision'] = this.status.sessionRevision;
    issued['accessOffset'] = cursor;
    issued['accessFile'] = 'xray-access.log';
    issued['rawCursor'] = cursor;
    issued['epoch'] = this.createEpoch;
    issued['at'] = this.status.probeIssuedAt;
    issued['googleUrl'] = this.status.probeGoogleUrl;
    issued['directUrl'] = this.status.probeDirectUrl;
    issued['source'] = 'self';
    issued['kind'] = 'issued';
    StatusStore.writeText(this.context, 'probe-issued.json', JSON.stringify(issued));
    StatusStore.removeFile(this.context, 'probe-consumed.json');
    StatusStore.removeFile(this.context, 'probe-request.json');
    return rid;
  }

  private writeProbeCommit(rid: string, tags: string): void {
    const commit: Record<string, Object> = {};
    commit['kind'] = 'commit';
    commit['rid'] = rid;
    commit['generation'] = this.generation;
    commit['revision'] = this.status.sessionRevision;
    commit['accessOffset'] = this.status.accessOffset;
    commit['accessFile'] = 'xray-access.log';
    commit['rawCursor'] = this.status.accessOffset;
    commit['epoch'] = this.status.probeEpoch;
    commit['issuedAt'] = this.status.probeIssuedAt;
    commit['at'] = Date.now();
    commit['evidenceAt'] = this.status.evidenceAt;
    commit['lastProvenRid'] = rid;
    commit['phase'] = PHASE_CANARY_OK;
    commit['tunRxBytes'] = this.status.tunRxBytes;
    commit['tunTxBytes'] = this.status.tunTxBytes;
    commit['hevUp'] = this.status.uploadBytes;
    commit['hevDown'] = this.status.downloadBytes;
    commit['accessTags'] = tags;
    commit['fetchGoogleHttp'] = this.status.fetchGoogleHttp;
    commit['fetchDirectHttp'] = this.status.fetchDirectHttp;
    commit['fetchDnsOk'] = this.status.fetchDnsOk;
    commit['fetchPid'] = this.status.fetchPid;
    commit['fetchUid'] = this.status.fetchUid;
    commit['fetchBundle'] = this.status.fetchBundle;
    commit['source'] = 'self';
    StatusStore.writeText(this.context, 'probe-commit.json', JSON.stringify(commit));
  }

  private readFetchAck(rid: string): boolean {
    const raw = StatusStore.readText(this.context, 'probe-fetch.json');
    if (raw.length < 8) {
      return false;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const ackRid = parsed['rid'];
      if (typeof ackRid !== 'string' || ackRid !== rid) {
        return false;
      }
      if (parsed['generation'] !== this.generation) {
        return false;
      }
      if (parsed['revision'] !== this.status.sessionRevision) {
        return false;
      }
      const ackAt = parsed['at'];
      if (typeof ackAt !== 'number' || ackAt < this.status.probeIssuedAt) {
        return false;
      }
      if (parsed['bundle'] !== BUNDLE_NAME) {
        return false;
      }
      const googleHttp = parsed['googleHttp'];
      const directHttp = parsed['directHttp'];
      const dnsOk = parsed['dnsOk'];
      this.status.fetchGoogleHttp = typeof googleHttp === 'number' ? googleHttp : 0;
      this.status.fetchDirectHttp = typeof directHttp === 'number' ? directHttp : 0;
      this.status.fetchDnsOk = dnsOk === true;
      this.status.fetchBundle = BUNDLE_NAME;
      if (this.status.fetchGoogleHttp !== 204) {
        return false;
      }
      if (this.status.fetchDirectHttp < 200 || this.status.fetchDirectHttp >= 400) {
        return false;
      }
      return this.status.fetchDnsOk;
    } catch (error) {
      return false;
    }
  }

  private readFailAck(rid: string): boolean {
    const raw = StatusStore.readText(this.context, 'probe-fetch.json');
    if (raw.length < 8) {
      return false;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const ackRid = parsed['rid'];
      if (typeof ackRid !== 'string' || ackRid !== rid) {
        return false;
      }
      if (parsed['generation'] !== this.generation) {
        return false;
      }
      if (parsed['revision'] !== this.status.sessionRevision) {
        return false;
      }
      if (parsed['ackOk'] === true) {
        return false;
      }
      if (parsed['failAck'] === true || parsed['ackOk'] === false) {
        return true;
      }
      const googleHttp = parsed['googleHttp'];
      if (typeof googleHttp === 'number' && googleHttp !== 204) {
        return true;
      }
      const error = parsed['error'];
      return typeof error === 'string' && error.length > 0;
    } catch (error) {
      return false;
    }
  }

  private captureBaseline(): void {
    this.status.lastReachableAt = 0;
    this.status.healthCheckedAt = 0;
    this.status.healthLastOutcome = '';
    this.refreshCounters();
    this.status.lastSampleTunRx = this.status.tunRxBytes;
    this.status.lastSampleTunTx = this.status.tunTxBytes;
    this.status.lastSampleHevUp = this.status.uploadBytes;
    this.status.lastSampleHevDown = this.status.downloadBytes;
    this.status.lastSampleTunBytes = this.status.tunRxBytes + this.status.tunTxBytes;
    this.status.lastSampleHevBytes = this.status.uploadBytes + this.status.downloadBytes;
    this.status.evidenceAt = 0;
    this.status.evidenceRid = '';
    this.status.accessOffset = -1;
    this.status.probeRevision = 0;
    this.status.probeEpoch = 0;
    this.status.probePending = false;
    this.status.selfProbe = false;
    this.status.probeGoogleUrl = '';
    this.status.probeDirectUrl = '';
    this.status.probeIssuedAt = 0;
    this.everProven = false;
    this.status.canaryOk = false;
  }

  private mergeTunCounters(): TunCounters {
    const counters = readVpnTunCounters();
    if (counters.found) {
      return counters;
    }
    const stats = getNativeStats();
    if (stats.tunFound) {
      counters.found = true;
      counters.rxBytes = stats.tunRxBytes;
      counters.txBytes = stats.tunTxBytes;
    }
    return counters;
  }

  private refreshCounters(): void {
    const counters = this.mergeTunCounters();
    const stats = getNativeStats();
    this.status.uploadBytes = stats.uploadBytes;
    this.status.downloadBytes = stats.downloadBytes;
    this.status.forwarderOk = stats.tunRunning;
    this.status.xrayRunning = stats.xrayRunning;
    if (counters.found) {
      this.status.tunRxBytes = counters.rxBytes;
      this.status.tunTxBytes = counters.txBytes;
      this.status.tunRxPackets = counters.rxPackets;
      this.status.tunTxPackets = counters.txPackets;
      this.status.tunDropped = counters.txDropped;
      this.status.tunReceiving = counters.rxBytes > this.lastTunRx;
      this.lastTunRx = counters.rxBytes;
    }
  }

  private hasFreshPlaneEvidence(): boolean {
    if (this.cancelled || this.cleaningUp) {
      return false;
    }
    if (this.status.generation !== this.generation || this.status.sessionId !== this.generation) {
      return false;
    }
    if (this.status.sessionRevision < 1) {
      return false;
    }
    if (!this.status.tunFdValid || this.tunFd < 0) {
      return false;
    }
    const stats = getNativeStats();
    if (stats.poisoned) {
      this.status.nativePoisoned = true;
      return false;
    }
    if (!stats.xrayRunning || !stats.tunRunning) {
      return false;
    }
    const counters = this.mergeTunCounters();
    if (StatusStore.readText(this.context, 'oracle-hold.json').length > 2) {
      return false;
    }
    if (!this.status.probePending || this.status.probeGoogleUrl.length < 8) {
      this.issueSelfProbe();
      return false;
    }
    const rid = this.status.evidenceRid;
    if (!this.readFetchAck(rid)) {
      if (this.readFailAck(rid)) {
        this.probeFailCount += 1;
        let wait = 2000;
        for (let i = 1; i < this.probeFailCount && wait < 120000; i++) {
          wait = wait * 2;
        }
        if (Date.now() - this.status.probeIssuedAt >= wait) {
          this.issueSelfProbe();
        }
      }
      return false;
    }
    this.probeFailCount = 0;
    const tags = this.accessTagSummary();
    if (!this.tagsMatchRoute(tags)) {
      this.status.lastError = `204 已到，访问标签与当前模式不符：${tags}`;
      return false;
    }
    this.lastProvenRid = rid;
    this.status.lastProvenRid = rid;
    this.status.probePending = false;
    this.status.evidenceRid = rid;
    this.status.evidenceAt = Date.now();
    this.status.uploadBytes = stats.uploadBytes;
    this.status.downloadBytes = stats.downloadBytes;
    this.status.forwarderOk = stats.tunRunning;
    this.status.tunRxBytes = counters.rxBytes;
    this.status.tunTxBytes = counters.txBytes;
    this.status.tunRxPackets = counters.rxPackets;
    this.status.tunTxPackets = counters.txPackets;
    this.status.tunDropped = counters.txDropped;
    this.status.tunReceiving = counters.rxBytes > this.lastTunRx;
    this.lastTunRx = counters.rxBytes;
    return true;
  }

  private applyLiveEvidence(): void {
    // Remember an actual failure/success before the strict audit rolls its RID.
    updateConnectionHealth(this.status, StatusStore.readText(this.context, 'probe-fetch.json'),
      BUNDLE_NAME, Date.now());
    if (this.status.phase === PHASE_RECONNECTING || this.status.phase === PHASE_ERROR ||
      this.status.phase === PHASE_STOPPED) {
      this.status.canaryOk = false;
      return;
    }
    const fresh = this.hasFreshPlaneEvidence();
    if (fresh) {
      this.failStreak = 0;
      this.coreRestarts = 0;
      this.status.lastSampleTunRx = this.status.tunRxBytes;
      this.status.lastSampleTunTx = this.status.tunTxBytes;
      this.status.lastSampleHevUp = this.status.uploadBytes;
      this.status.lastSampleHevDown = this.status.downloadBytes;
      this.status.lastSampleTunBytes = this.status.tunRxBytes + this.status.tunTxBytes;
      this.status.lastSampleHevBytes = this.status.uploadBytes + this.status.downloadBytes;
      this.status.evidenceAt = Date.now();
      this.everProven = true;
      this.status.canaryOk = true;
      this.status.phase = PHASE_CANARY_OK;
      this.status.lastError = '';
      this.writeProbeCommit(this.status.evidenceRid, this.accessTagSummary());
      return;
    }
    const stats = getNativeStats();
    const liveCore = stats.xrayRunning && stats.tunRunning && !stats.poisoned && this.status.tunFdValid;
    if (this.lastProvenRid.length > 2 && liveCore && this.status.probePending &&
      this.status.evidenceAt > 0 && Date.now() - this.status.evidenceAt < PROBE_GRACE_MS) {
      this.status.canaryOk = true;
      this.status.phase = PHASE_CANARY_OK;
      this.status.lastError = '';
      return;
    }
    this.status.canaryOk = false;
    if (this.everProven || this.status.phase === PHASE_CANARY_OK ||
      this.status.phase === PHASE_DEGRADED_UNPROVEN) {
      this.status.phase = PHASE_DEGRADED_UNPROVEN;
      if (this.status.lastError.length === 0) {
        this.status.lastError = '本轮证据失效';
      }
      return;
    }
    this.status.phase = PHASE_UNPROVEN;
    if (this.status.lastError.length === 0) {
      this.status.lastError = '本轮还没有 204 和访问日志证据';
    }
  }

  private async startTunnel(token: number, gen: string): Promise<void> {
    if (!this.desiredRunning || this.cancelled || this.cleaningUp || this.startInFlight ||
      (this.status.vpnCreated && this.tunFd >= 0)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'drop duplicate start');
      return;
    }
    this.startInFlight = true;
    const capturedEpoch = token;
    this.startFlightEpoch = capturedEpoch;
    const rev = this.status.sessionRevision;
    let coreResult: NativeResult | undefined = undefined;
    try {
      if (this.breakerBlocks()) {
        this.parkStop(gen);
        throw new Error('circuit breaker open; refuse start');
      }
      const stats = getNativeStats();
      if (stats.poisoned) {
        this.status.nativePoisoned = true;
        this.tripBreaker('native-poisoned');
        throw new Error('native poisoned; refuse start');
      }
      this.status.phase = PHASE_STARTING;
      this.status.honestLabel = honestLabelOf(this.status);
      this.publish();

      const meta = StatusStore.readNodeMeta(this.context);
      this.status.nodeName = meta.name;
      this.status.nodeRegion = meta.region;
      // Phase C：会话开始时读一次故障切换设置；缺省（无 settings.json）= 开启，
      // 与 Phase C 之前行为一致。
      const userSettings = SettingsStore.load(this.context);
      this.failoverEnabled = CONNECTION_POLICY.autoFailoverEnabled(this.context);
      this.failoverGroup = userSettings.failoverGroup;
      this.socks = newSocksSession();
      const socksPort = this.socks.port;

      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      const conn = this.vpnConnection;
      try {
        await conn.protectProcessNet();
        this.status.protectOk = true;
        this.installProtectCallback();
        hilog.info(LOG_DOMAIN, LOG_TAG, 'protectProcessNet + TSFN protect ready before tun/core');
      } catch (error) {
        this.status.protectOk = false;
        throw new Error(`protectProcessNet 失败，已中止：${this.errorMessage(error)}`);
      }
      if (!this.guard(gen, rev, socksPort, 'protect')) {
        this.requestCleanup('stale after protect', gen);
        return;
      }

      this.outboundJson = await HuksSecretStore.readOutbound(this.context);
      this.outboundJson = CONNECTION_POLICY.enforcePayload(this.context, this.outboundJson);
      if (!this.guard(gen, rev, socksPort, 'huks')) {
        this.requestCleanup('stale after huks', gen);
        return;
      }
      if (this.outboundJson.length < 20) {
        throw new Error('没有可运行的节点配置。请先导入节点。安装包不含节点密码。');
      }
      const appRoutes = await AppRouteRuntime.prepare(this.context, this.outboundJson, this.socks.port);
      if (!this.guard(gen, rev, socksPort, 'app-identities')) {
        this.requestCleanup('stale after app identities', gen);
        return;
      }
      this.appRoutes = appRoutes;
      let configJson = buildRuntimeXrayConfig(this.outboundJson, this.socks, this.context.filesDir, '', this.outboundTrace,
        this.appRoutes.ports);
      if (this.nodeSystemDns) { configJson = await withSystemResolvedNodes(configJson); }
      if (!this.guard(gen, rev, socksPort, 'diagnostic-dns')) {
        this.requestCleanup('stale after diagnostic dns', gen);
        return;
      }
      const preStop = stopNativeXray();
      if (!this.outboundTrace && preStop.ok) {
        StatusStore.removeFile(this.context, 'xray-timing.log');
      }
      if (!preStop.ok && this.isAlreadyRunning(preStop.message) === false &&
        preStop.message.indexOf('already stopped') < 0) {
        throw new Error(`无法停下旧内核：${preStop.message}`);
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'starting xray socksPort=%{public}d bytes=%{public}d',
        this.socks.port, configJson.length);
      coreResult = await this.startXrayWithPortRetry(configJson);
      if (!this.guard(gen, rev, this.socks.port, 'xray-start')) {
        this.stopStartedXray(coreResult);
        this.requestCleanup('stale after xray start', gen);
        return;
      }
      if (!coreResult.ok || this.isAlreadyRunning(coreResult.message)) {
        throw new Error(`内核启动失败或 already-running 错配：${coreResult.message}`);
      }
      this.commitXrayStartRecords(coreResult);
      const socksUp = await tcpConnectCanary(this.socks.host, this.socks.port, 4000);
      if (!this.guard(gen, rev, this.socks.port, 'socks-up')) {
        this.stopStartedXray(coreResult);
        this.requestCleanup('stale after socks', gen);
        return;
      }
      if (!socksUp.ok) {
        this.stopStartedXray(coreResult);
        throw new Error(`内核已启动但本地 SOCKS 未起来：${socksUp.message}`);
      }
      this.status.phase = PHASE_CORE_RUNNING;
      this.status.honestLabel = honestLabelOf(this.status);
      this.status.lastCanary = `${coreResult.message}；SOCKS ${this.socks.port} 已起来`;
      this.publish();

      const trusted = trustedAppsForMode(this.mode);
      const config = createTunnelVpnConfig(trusted);
      this.createEpoch += 1;
      const epoch = this.createEpoch;
      const localFd = await conn.create(config);
      if (localFd < 0) {
        this.status.tunFd = -1;
        this.status.tunFdValid = false;
        this.status.vpnCreated = false;
        this.fail('创建隧道失败', 'tunFd<0');
        this.requestCleanup('tun create fd invalid', gen);
        return;
      }
      if (this.cancelled || this.cleaningUp || this.generation !== gen || epoch !== this.createEpoch ||
        capturedEpoch !== this.committedToken || !this.desiredRunning) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'late tun create, destroying orphan via local handle');
        this.vpnConnection = null;
        try {
          await this.destroyBounded(conn, 4000);
        } catch (error) {
          this.failClosed('拆除孤儿隧道失败', this.errorMessage(error));
          this.destroyInFlight = true;
          this.desiredRunning = false;
          this.status.desiredRunning = false;
          this.tripBreaker('orphan-destroy-timeout');
          this.parkStop(gen);
          return;
        }
        this.failClosed('晚创建的隧道已拆除', `fd=${localFd}`);
        this.requestCleanup('late tun create', gen);
        return;
      }
      this.tunFd = localFd;
      if (!this.guard(gen, rev, this.socks.port, 'tun-create')) {
        this.requestCleanup('stale after tun create', gen);
        return;
      }
      this.status.vpnCreated = true;
      this.status.tunFd = this.tunFd;
      this.status.tunFdValid = this.tunFd >= 0;
      this.status.phase = PHASE_VPN_CREATED;
      this.status.honestLabel = honestLabelOf(this.status);
      this.publish();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'vpn created tunFd=%{public}d mode=%{public}s', this.tunFd, this.mode);

      if (this.mode === MODE_PROBE_BROWSER || this.mode === MODE_PROBE_SELF) {
        throw new Error('探测模式已从生产面移除，只支持完整规则 VPN');
      }

      // Start forwarding immediately. A separate node-port probe neither
      // proves Internet access nor gates this session; canaries run below.
      const preHev = stopNativeTun2Socks();
      if (!preHev.ok && preHev.message.indexOf('already stopped') < 0) {
        throw new Error(`无法停下旧 HEV：${preHev.message}`);
      }
      const hevYaml = buildHevTunConfigYaml(VPN_MTU, this.socks.host, this.socks.port, this.socks.user, this.socks.pass);
      this.appRoutes?.install();
      const hevResult = startNativeHevTun(this.tunFd, hevYaml);
      if (!hevResult.ok || this.isAlreadyRunning(hevResult.message)) {
        this.stopStartedXray(coreResult);
        throw new Error(`hev 转发启动失败或 already-running 错配：${hevResult.message}`);
      }
      this.status.lastCanary = `${this.status.lastCanary}；${hevResult.message}`;
      this.status.forwarderOk = true;
      this.status.phase = PHASE_FORWARDER_RUNNING;
      this.status.honestLabel = honestLabelOf(this.status);
      this.captureBaseline();
      this.issueSelfProbe();
      this.publish();

      await this.runCanaryCycle();
      if (!this.guard(gen, this.status.sessionRevision, this.socks.port, 'first-canary')) {
        this.requestCleanup('stale after first canary', gen);
        return;
      }
      this.startCanaryTimer();
      this.startSupervisor();
      this.startNetWatch();
      this.publish();
      const started: Record<string, Object> = {};
      this.emit('session-start', started);
    } catch (error) {
      this.stopStartedXray(coreResult);
      const latest = this.latestCommand;
      if (latest !== null && latest.token !== capturedEpoch && !this.isSameStartIntent(latest, gen)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stale start catch token=%{public}d latest=%{public}d',
          capturedEpoch, latest.token);
        this.requestCleanup('stale start failed', gen);
        return;
      }
      this.fail('启动失败', this.errorMessage(error));
      if (this.errorMessage(error).indexOf('circuit breaker') < 0) {
        this.tripBreaker('start-failed');
      }
      this.parkStop(gen);
      this.requestCleanup('start failed', gen);
    } finally {
      if (this.startFlightEpoch === capturedEpoch) {
        this.startInFlight = false;
        const latest = this.latestCommand;
        if (latest !== null && latest.token !== capturedEpoch && !this.isSameStartIntent(latest, gen)) {
          this.dispatchLatest();
        }
      }
    }
  }

  private startCanaryTimer(): void {
    this.stopCanaryTimer();
    this.canaryTimerId = setInterval(() => {
      this.runCanaryCycle().catch((error: Object) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'canary cycle %{public}s', this.errorMessage(error));
      });
    }, CANARY_INTERVAL_MS);
  }

  private stopCanaryTimer(): void {
    if (this.canaryTimerId >= 0) {
      clearInterval(this.canaryTimerId);
      this.canaryTimerId = -1;
    }
  }

  private installProtectCallback(): void {
    const installed = setProtectCallback((fd: number, token: number) => {
      this.handleProtectFd(fd, token);
    });
    if (installed !== 1) {
      throw new Error('无法注册系统 protect 回调');
    }
  }

  private handleProtectFd(fd: number, token: number): void {
    this.countProtect('requests');
    const conn = this.vpnConnection;
    if (conn === null || fd < 0 || token <= 0 || this.cleaningUp || this.cancelled) {
      this.countProtect(fd < 0 || token <= 0 ? 'invalid' : 'unavailable');
      ackProtectFd(fd, -1, token);
      return;
    }
    if (claimProtectFd(fd, token) !== 1) {
      this.countProtect('claimRejected');
      ackProtectFd(fd, -1, token);
      return;
    }
    conn.protect(fd).then(() => {
      this.countProtect('apiSucceeded');
      ackProtectFd(fd, 0, token);
    }).catch((error: Object) => {
      this.countProtect('apiRejected');
      const code = (error as BusinessError).code;
      this.protectDiagnostics['lastErrorCode'] = typeof code === 'number' && Number.isFinite(code) ? code : 0;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'protect fd=%{public}d token=%{public}d %{public}s',
        fd, token, this.errorMessage(error));
      ackProtectFd(fd, -1, token);
    });
  }

  private countProtect(key: string): void {
    this.protectDiagnostics[key] = (this.protectDiagnostics[key] as number) + 1;
  }

  private clearProtectBridge(): void {
    try {
      clearProtectCallback();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'clearProtectCallback %{public}s', this.errorMessage(error));
    }
  }

  private startSupervisor(): void {
    this.stopSupervisor();
    this.supervisorTimerId = setInterval(() => {
      this.superviseOnce();
    }, SUPERVISOR_INTERVAL_MS);
  }

  private stopSupervisor(): void {
    if (this.supervisorTimerId >= 0) {
      clearInterval(this.supervisorTimerId);
      this.supervisorTimerId = -1;
    }
  }

  private superviseOnce(): void {
    if (this.cleaningUp || this.cancelled) {
      return;
    }
    const live: boolean = this.status.phase === PHASE_CANARY_OK || this.status.phase === PHASE_DEGRADED ||
      this.status.phase === PHASE_DEGRADED_UNPROVEN || this.status.phase === PHASE_UNPROVEN ||
      this.status.phase === PHASE_FORWARDER_RUNNING || this.status.phase === PHASE_CORE_RUNNING;
    if (!live) {
      return;
    }
    const stats = getNativeStats();
    this.refreshCounters();
    this.publishAccessSlice();
    this.applyLiveEvidence();
    this.status.honestLabel = honestLabelOf(this.status);
    this.publish();
    const tickExtra: Record<string, Object> = {};
    this.emit('tick', tickExtra);
    if (this.status.healthCheckedAt > this.observedHealthAt) {
      this.observedHealthAt = this.status.healthCheckedAt;
      this.healthFailureReceipts = this.status.healthLastOutcome === 'failure' ? this.healthFailureReceipts + 1 : 0;
    }
    // Failed browser checks request an independent SOCKS check, not an
    // immediate reconnect or a user-facing loss of the connection state.
    if (this.healthFailureReceipts >= 2 && !this.polling && !this.recoverInFlight &&
      !this.startInFlight && Date.now() - this.lastHealthCanaryAt >= 60000) {
      this.lastHealthCanaryAt = Date.now();
      this.runCanaryCycle().catch(() => { hilog.warn(LOG_DOMAIN, LOG_TAG, 'background verification incomplete'); });
    }
    if (!stats.xrayRunning || !stats.tunRunning) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'supervisor dead xray=%{public}s tun=%{public}s',
        stats.xrayRunning ? '1' : '0', stats.tunRunning ? '1' : '0');
      this.requestRecover('supervisor');
      return;
    }
    if (this.status.generation !== this.generation || this.status.sessionRevision < 1) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'supervisor session mismatch');
      this.requestRecover('supervisor-session');
    }
  }

  private startNetWatch(): void {
    this.stopNetWatch();
    const conn = connection.createNetConnection();
    this.netConn = conn;
    conn.on('netLost', (handle: Object) => {
      this.onNetEvent('lost', handle);
    });
    conn.on('netUnavailable', () => {
      this.onNetEvent('unavailable', null);
    });
    conn.on('netAvailable', (handle: Object) => {
      this.onNetEvent('available', handle);
    });
    conn.register((error: BusinessError) => {
      if (error !== undefined && error.message !== undefined && error.message.length > 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'net watch register %{public}s', error.message);
      }
    });
  }

  private stopNetWatch(): void {
    const conn = this.netConn;
    this.netConn = null;
    if (conn === null) {
      return;
    }
    try {
      conn.unregister((error: BusinessError) => {
        if (error !== undefined && error.message !== undefined && error.message.length > 0) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'net watch unregister %{public}s', error.message);
        }
      });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'net watch stop %{public}s', this.errorMessage(error));
    }
  }

  private onNetEvent(kind: string, handle: Object | null): void {
    if (this.cancelled || this.cleaningUp) {
      return;
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'net event %{public}s', kind);
    if (kind === 'lost' || kind === 'unavailable') {
      this.networkWasLost = true;
      this.status.phase = PHASE_DEGRADED;
      this.status.canaryOk = false;
      this.status.honestLabel = honestLabelOf(this.status);
      this.publish();
    }
    const extra: Record<string, Object> = {};
    extra['net'] = kind;
    if (kind === 'lost' || kind === 'unavailable') {
      extra['recoveryRequested'] = false;
      this.emit('net', extra);
      return;
    }
    if (kind === 'available') {
      let netId = -1;
      if (handle !== null) {
        const value = (handle as Record<string, Object>)['netId'];
        if (typeof value === 'number') { netId = value; }
      }
      const changed = netId >= 0 && this.lastAvailableNetId >= 0 && netId !== this.lastAvailableNetId;
      const needsRefresh = this.networkWasLost || changed || this.status.phase === PHASE_DEGRADED;
      extra['netChanged'] = changed;
      extra['recoveryRequested'] = needsRefresh;
      this.emit('net', extra);
      if (netId >= 0) { this.lastAvailableNetId = netId; }
      this.networkWasLost = false;
      if (needsRefresh) { this.requestRecover('netAvailable'); }
    }
  }

  private requestRecover(reason: string): void {
    if (this.cancelled || this.cleaningUp || this.recoverInFlight) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'skip recover reason=%{public}s cancelled=%{public}s inflight=%{public}s',
        reason, this.cancelled ? '1' : '0', this.recoverInFlight ? '1' : '0');
      return;
    }
    const gen = this.generation;
    this.recover().catch((error: Object) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'recover %{public}s %{public}s', reason, this.errorMessage(error));
      this.requestCleanup('recover catch', gen);
    });
  }

  private async runCanaryCycle(): Promise<void> {
    if (this.cleaningUp || this.polling || this.cancelled) {
      return;
    }
    this.polling = true;
    const gen = this.generation;
    const rev = this.status.sessionRevision;
    const socksPort = this.socks.port;
    let needFailoverRecover = false;
    let needAddressRefresh = false;
    try {
      this.refreshCounters();
      this.publishAccessSlice();

      const direct = await socksHttpCanary(
        this.socks.host,
        this.socks.port,
        'www.baidu.com',
        80,
        'www.baidu.com',
        '/',
        6000,
        this.socks.user,
        this.socks.pass
      );
      if (!this.guard(gen, rev, socksPort, 'canary-direct')) {
        return;
      }
      const proxy = await socksHttpCanary(
        this.socks.host,
        this.socks.port,
        'www.google.com',
        80,
        'www.google.com',
        '/generate_204',
        8000,
        this.socks.user,
        this.socks.pass
      );
      if (!this.guard(gen, rev, socksPort, 'canary-proxy')) {
        return;
      }
      const yt = await socksHttpCanary(
        this.socks.host,
        this.socks.port,
        'www.youtube.com',
        80,
        'www.youtube.com',
        '/generate_204',
        8000,
        this.socks.user,
        this.socks.pass
      );
      if (!this.guard(gen, rev, socksPort, 'canary-yt')) {
        return;
      }
      const lineHealth = await socksHttpCanary(
        this.socks.host,
        this.socks.port,
        LINE_HEALTH_HOST,
        80,
        LINE_HEALTH_HOST,
        '/generate_204',
        8000,
        this.socks.user,
        this.socks.pass
      );
      if (!this.guard(gen, rev, socksPort, 'canary-line-health')) {
        return;
      }
      const lineHealthB = await socksHttpCanary(
        this.socks.host,
        this.socks.port,
        LINE_HEALTH_HOST_B,
        80,
        LINE_HEALTH_HOST_B,
        '/',
        8000,
        this.socks.user,
        this.socks.pass
      );
      if (!this.guard(gen, rev, socksPort, 'canary-line-health-b')) {
        return;
      }
      this.lastGoogleOk = proxy.ok;
      this.lastYoutubeOk = yt.ok;
      this.lastLineHealthOk = lineHealth.ok;
      this.lastLineHealthBOk = lineHealthB.ok;
      this.status.directOk = direct.ok;
      this.status.proxyOk = proxy.ok;
      this.status.socksCanaryOk = direct.ok && proxy.ok;
      this.status.lastCanary =
        `diag SOCKS DIRECT baidu ${direct.ok ? 'ok' : 'fail'} ${direct.elapsedMs}ms ${direct.message}；` +
        `PROXY google ${proxy.ok ? 'ok' : 'fail'} ${proxy.elapsedMs}ms ${proxy.message}；` +
        `YT youtube ${yt.ok ? 'ok' : 'fail'} ${yt.elapsedMs}ms ${yt.message}；` +
        `LINE ${LINE_HEALTH_HOST} ${lineHealth.ok ? 'ok' : 'fail'} ${lineHealth.elapsedMs}ms ${lineHealth.message}；` +
        `LINEB ${LINE_HEALTH_HOST_B} ${lineHealthB.ok ? 'ok' : 'fail'} ${lineHealthB.elapsedMs}ms ${lineHealthB.message}`;
      this.status.dnsOk = this.status.dnsOk || direct.ok || proxy.ok || yt.ok || lineHealth.ok || lineHealthB.ok;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'socks diagnostic %{public}s', this.status.lastCanary);

      this.applyLiveEvidence();
      const nativeLive = getNativeStats().xrayRunning && getNativeStats().tunRunning;
      if (direct.ok && proxy.ok && yt.ok && nativeLive) {
        this.coreRestarts = 0;
        this.addressRefreshAttempted = false;
        this.healthFailureReceipts = 0;
        this.clearOrdinaryBreaker();
      }
      let nativeRecover = false;
      if (!this.status.canaryOk) {
        this.failStreak += 1;
        if (this.failStreak >= CANARY_FAIL_LIMIT && !nativeLive) {
          nativeRecover = true;
          this.requestRecover('canary-native-dead');
        }
      }
      if (!nativeRecover && direct.ok && nativeLive && !this.recoverInFlight) {
        const profile = this.payloadRoutingProfile();
        const channel = this.payloadChannelMode();
        this.noteProbe(probeOutboundTag('google', profile, channel), 'www.google.com', proxy.ok);
        this.noteProbe(probeOutboundTag('youtube', profile, channel), 'www.youtube.com', yt.ok);
        this.noteProbe(probeOutboundTag('line-health', profile, channel), LINE_HEALTH_HOST, lineHealth.ok);
        this.noteProbe(probeOutboundTag('line-health-b', profile, channel), LINE_HEALTH_HOST_B, lineHealthB.ok);
        const swapGeneral = runtimeMayPromoteBackup(this.failoverEnabled, this.ytFailoverLocked) &&
          legShouldPromote(this.generalLeg, NODE_FAIL_LIMIT);
        const swapProxy = runtimeMayPromoteBackup(this.failoverEnabled, this.usFailoverLocked) &&
          legShouldPromote(this.proxyLeg, NODE_FAIL_LIMIT);
        if (this.nodeSystemDns && (!proxy.ok || !yt.ok) && !this.startInFlight && !this.addressRefreshAttempted) {
          this.addressRefreshAttempted = true;
          needAddressRefresh = true;
        } else if (swapGeneral || swapProxy) {
          needFailoverRecover = await this.promoteSecondBest(swapGeneral, swapProxy);
        }
      }
      this.status.honestLabel = honestLabelOf(this.status);
      this.publishAccessSlice();
      if (!this.guard(gen, this.status.sessionRevision, socksPort, 'canary-publish')) {
        return;
      }
      this.publish();
      const extra: Record<string, Object> = {};
      extra['lastCanary'] = this.status.lastCanary;
      extra['socksCanaryOk'] = this.status.socksCanaryOk;
      extra['planeEvidence'] = this.status.canaryOk;
      this.emit('canary', extra);
    } finally {
      this.polling = false;
    }
    if (needFailoverRecover && this.generation === gen && !this.cancelled && !this.cleaningUp) {
      this.requestRecover('node-failover');
    } else if (needAddressRefresh && this.generation === gen && !this.cancelled && !this.cleaningUp) {
      this.requestRecover('node-address-refresh');
    }
  }

  private async promoteSecondBest(swapYt: boolean, swapUs: boolean): Promise<boolean> {
    let doYt = swapYt;
    let doUs = swapUs;
    if (doYt) {
      doYt = await this.backupPortReachable(backupOutboundFor(this.outboundJson, 'yt'));
    }
    if (doUs) {
      doUs = await this.backupPortReachable(backupOutboundFor(this.outboundJson, 'us'));
    }
    if (!doYt && !doUs && (swapYt || swapUs)) {
      const singleBackup = backupOutboundFor(this.outboundJson, 'single');
      if (!await this.backupPortReachable(singleBackup)) {
        return false;
      }
      doYt = swapYt;
      doUs = swapUs;
    } else if (!doYt && !doUs) {
      return false;
    }
    const next = failoverSplitPayload(this.outboundJson, doYt, doUs);
    if (next.length < 20 || next === this.outboundJson) {
      if (swapYt) {
        this.ytFailoverLocked = true;
      }
      if (swapUs) {
        this.usFailoverLocked = true;
      }
      // Phase C：限定分组时无第二节点属于预期（组内无备用节点），单独记日志。
      if (this.failoverGroup.length > 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, '组内无备用节点 group=%{public}s', this.failoverGroup);
      }
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no second-best to promote yt=%{public}s us=%{public}s',
        swapYt ? '1' : '0', swapUs ? '1' : '0');
      return false;
    }
    const metaRaw = StatusStore.readText(this.context, NODE_META_FILE);
    const nextMeta = failoverSplitMeta(metaRaw.length >= 8 ? metaRaw : '{}', next);
    try {
      StatusStore.writeText(this.context, OUTBOUND_FILE, next);
      StatusStore.writeText(this.context, META_STAGING_FILE, nextMeta);
      await HuksSecretStore.protectOutbound(this.context);
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'failover wrap %{public}s', this.errorMessage(error));
      return false;
    }
    this.outboundJson = next;
    this.failoverTrial = true;
    this.failoverTrialYt = doYt;
    this.failoverTrialUs = doUs;
    const meta = parseNodeMeta(nextMeta);
    this.status.nodeName = meta.name;
    this.status.nodeRegion = meta.region;
    if (doYt) {
      this.ytFailoverLocked = true;
      this.generalLeg = emptyLeg('proxy-yt');
    }
    if (doUs) {
      this.usFailoverLocked = true;
      this.proxyLeg = emptyLeg('proxy');
    }
    this.coreRestarts = 0;
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'prepared backup swap, waiting canary name=%{public}s', meta.name);
    return true;
  }

  private clearFailoverTrial(): void {
    this.failoverTrial = false;
    this.failoverTrialYt = false;
    this.failoverTrialUs = false;
  }

  private failoverTrialActive(): boolean {
    return this.failoverTrial || this.failoverTrialYt || this.failoverTrialUs;
  }

  private abandonUnrestoredTrial(): void {
    this.desiredRunning = false;
    this.status.desiredRunning = false;
    this.pendingStart = false;
    this.pendingGeneration = '';
    this.pendingMode = '';
    const cmd = this.latestCommand;
    if (cmd !== null && cmd.kind === 'start') {
      this.latestCommand = null;
    }
  }

  private revertFailoverIfNeeded(): boolean {
    if (!this.failoverTrialActive()) {
      return true;
    }
    let restored = false;
    try {
      restored = HuksSecretStore.restorePrevious(this.context) === true;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'failover restore %{public}s', this.errorMessage(error));
      restored = false;
    }
    if (restored) {
      this.clearFailoverTrial();
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'failover trial restored previous commit');
      return true;
    }
    hilog.error(LOG_DOMAIN, LOG_TAG, 'failover trial previous commit not restored');
    return false;
  }

  private async backupPortReachable(outboundJson: string): Promise<boolean> {
    const backup = endpointOfOutbound(outboundJson);
    if (backup.server.length === 0 || backup.port <= 0) {
      return false;
    }
    const live = await tcpConnectCanary(backup.server, backup.port, 2500);
    if (!live.ok) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'failover backup port closed %{public}s:%{public}d', backup.server, backup.port);
      return false;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'backup port reachable %{public}s:%{public}d; TLS/proxy not proven',
      backup.server, backup.port);
    return true;
  }

  private publishAccessSlice(): void {
    try {
      const raw = StatusStore.readText(this.context, 'xray-access.log');
      if (raw.length === 0) {
        return;
      }
      // Producer (Xray file logger) holds the canonical inode for the whole
      // run. Never rewrite xray-access.log while the core is appending.
      const slice = this.redactAccess(raw.length > 100000 ? raw.substring(raw.length - 100000) : raw);
      StatusStore.writeText(this.context, 'xray-access-pub.log', slice);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'access slice %{public}s', this.errorMessage(error));
    }
  }

  private rotateAccessAfterStop(): void {
    try {
      const raw = StatusStore.readText(this.context, 'xray-access.log');
      const rotated = this.rotateAccess(raw);
      if (rotated !== raw) {
        StatusStore.writeText(this.context, 'xray-access.log', rotated);
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'post-stop rotate %{public}s', this.errorMessage(error));
    }
  }

  private async recover(): Promise<void> {
    if (this.cleaningUp || this.cancelled || this.recoverInFlight) {
      return;
    }
    this.recoverInFlight = true;
    const gen = this.generation;
    const rev = this.status.sessionRevision;
    let recovered = false;
    try {
      this.status.phase = PHASE_RECONNECTING;
      this.status.canaryOk = false;
      this.status.honestLabel = honestLabelOf(this.status);
      this.status.reconnectCount += 1;
      this.publish();
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'recovering failStreak=%{public}d restarts=%{public}d rev=%{public}d',
        this.failStreak, this.coreRestarts, rev);
      const beginExtra: Record<string, Object> = {};
      this.emit('recover-begin', beginExtra);

      if (this.coreRestarts >= CORE_RESTART_LIMIT) {
        this.fail('多次恢复仍失败', this.status.lastCanary);
        this.tripBreaker('recover-limit');
        this.requestCleanup('recover limit', gen);
        return;
      }
      this.coreRestarts += 1;
      this.appRoutes?.stop();
      const stopForwarder = stopNativeTun2Socks();
      if (!stopForwarder.ok) {
        this.fail('停止 HEV 失败', stopForwarder.message);
        this.requestCleanup('recover hev stop failed', gen);
        return;
      }
      const stopCore = this.xrayOwnerSeq > 0 ? this.stopStartedXray() : stopNativeXray();
      if (!stopCore.ok) {
        this.fail('停止内核失败', stopCore.message);
        this.requestCleanup('recover xray stop failed', gen);
        return;
      }
      if (this.staleRecover(gen, rev)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'recover cancelled after stop');
        this.requestCleanup('recover stale after stop', gen);
        return;
      }
      this.socks = newSocksSession();
      const socksPort = this.socks.port;
      try {
        this.outboundJson = await HuksSecretStore.readOutbound(this.context);
        this.outboundJson = CONNECTION_POLICY.enforcePayload(this.context, this.outboundJson);
      } catch (error) {
        this.fail('读取节点密文失败', this.errorMessage(error));
        this.requestCleanup('recover huks', gen);
        return;
      }
      if (this.staleRecover(gen, rev) || this.socks.port !== socksPort) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'recover cancelled after huks');
        this.requestCleanup('recover stale after huks', gen);
        return;
      }
      let configJson = '';
      try {
        const appRoutes = await AppRouteRuntime.prepare(this.context, this.outboundJson, this.socks.port);
        if (this.staleRecover(gen, rev) || this.socks.port !== socksPort) {
          this.requestCleanup('recover stale after app identities', gen);
          return;
        }
        this.appRoutes = appRoutes;
        configJson = buildRuntimeXrayConfig(this.outboundJson, this.socks, this.context.filesDir, '', this.outboundTrace,
          this.appRoutes.ports);
        if (this.nodeSystemDns) { configJson = await withSystemResolvedNodes(configJson); }
      } catch (error) {
        this.fail('配置重建失败', this.errorMessage(error));
        this.requestCleanup('recover config', gen);
        return;
      }
      if (this.staleRecover(gen, rev) || this.socks.port !== socksPort) {
        this.requestCleanup('recover stale after diagnostic dns', gen);
        return;
      }
      const coreResult = await this.startXrayWithPortRetry(configJson);
      if (this.staleRecover(gen, rev)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'recover cancelled after xray start');
        this.stopStartedXray(coreResult);
        this.requestCleanup('recover stale after xray start', gen);
        return;
      }
      if (!coreResult.ok || this.isAlreadyRunning(coreResult.message)) {
        this.fail('重启内核失败或 already-running 错配', coreResult.message);
        this.requestCleanup('recover xray failed', gen);
        return;
      }
      this.commitXrayStartRecords(coreResult);
      if (this.staleRecover(gen, rev)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'recover cancelled after xray');
        this.stopStartedXray(coreResult);
        this.requestCleanup('recover stale after xray', gen);
        return;
      }
      const hevYaml = buildHevTunConfigYaml(VPN_MTU, this.socks.host, this.socks.port, this.socks.user, this.socks.pass);
      this.appRoutes?.install();
      const hevResult = startNativeHevTun(this.tunFd, hevYaml);
      if (!hevResult.ok || this.isAlreadyRunning(hevResult.message)) {
        this.stopStartedXray(coreResult);
        this.fail('重启动转发失败或 already-running 错配', hevResult.message);
        this.requestCleanup('recover hev failed', gen);
        return;
      }
      if (this.staleRecover(gen, rev)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'recover cancelled after hev');
        stopNativeTun2Socks();
        this.stopStartedXray(coreResult);
        this.requestCleanup('recover stale after hev', gen);
        return;
      }
      this.status.forwarderOk = true;
      this.failStreak = 0;
      this.status.sessionRevision += 1;
      this.captureBaseline();
      this.status.phase = PHASE_FORWARDER_RUNNING;
      this.status.canaryOk = false;
      this.status.honestLabel = honestLabelOf(this.status);
      this.publish();
      await this.runCanaryCycle();
      if (!this.guard(gen, this.status.sessionRevision, this.socks.port, 'recover-canary')) {
        this.requestCleanup('recover stale after canary', gen);
        return;
      }
      if (this.failoverTrialActive() && !trialLegsProven(this.failoverTrialYt, this.failoverTrialUs,
        this.lastGoogleOk, this.lastYoutubeOk, this.lastLineHealthOk, this.lastLineHealthBOk)) {
        const restored = this.revertFailoverIfNeeded();
        if (!restored) {
          this.abandonUnrestoredTrial();
        }
        this.fail('备用节点协议未证实', this.status.lastCanary);
        this.requestCleanup('failover unproven', gen);
        return;
      }
      this.clearFailoverTrial();
      recovered = true;
      const endExtra: Record<string, Object> = {};
      this.emit('recover-end', endExtra);
    } catch (error) {
      this.fail('恢复异常', this.errorMessage(error));
      this.requestCleanup('recover exception', gen);
    } finally {
      if (!recovered) {
        const restored = this.revertFailoverIfNeeded();
        if (!restored) {
          this.abandonUnrestoredTrial();
        }
      }
      this.recoverInFlight = false;
      this.dispatchLatest();
    }
  }

  private staleRecover(gen: string, rev: number): boolean {
    return this.cancelled || this.cleaningUp || this.generation !== gen || this.status.sessionRevision !== rev;
  }

  private fail(message: string, details: string): void {
    this.status.phase = PHASE_ERROR;
    this.status.canaryOk = false;
    this.status.lastError = `${message}：${details}`;
    this.status.honestLabel = honestLabelOf(this.status);
    this.publish();
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s %{public}s', message, details);
  }

  private failClosed(message: string, details: string): void {
    this.status.phase = PHASE_ERROR;
    this.status.canaryOk = false;
    this.status.lastError = `${message}：${details}`;
    this.status.honestLabel = honestLabelOf(this.status);
    this.forcePublish();
    hilog.error(LOG_DOMAIN, LOG_TAG, 'fail-closed %{public}s %{public}s', message, details);
  }

  private applyDesired(): void {
    this.dispatchLatest();
  }

  private requestCleanup(reason: string, generation: string = ''): void {
    if (generation.length > 0 && generation !== this.generation) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'ignore stale cleanup gen=%{public}s current=%{public}s', generation, this.generation);
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cleanup %{public}s', reason);
    this.cleanup().catch((error: Object) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'cleanup failed %{public}s', this.errorMessage(error));
    });
  }

  private async cleanup(): Promise<void> {
    if (this.cleaningUp) {
      return;
    }
    this.cleaningUp = true;
    this.cancelled = true;
    this.pendingStart = this.desiredRunning ? this.pendingStart : false;
    if (!this.desiredRunning) {
      this.pendingStart = false;
      this.pendingGeneration = '';
      this.pendingMode = '';
    }
    this.createEpoch += 1;
    this.stopNetWatch();
    this.stopSupervisor();
    this.stopCanaryTimer();
    this.clearProtectBridge();
    this.appRoutes?.stop();
    this.appRoutes = null;
    let stopForwarderOk = false;
    let stopCoreOk = false;
    let poisoned = false;
    try {
      const stopForwarder = stopNativeTun2Socks();
      stopForwarderOk = stopForwarder.ok;
      poisoned = poisoned || stopForwarder.poisoned;
      if (!stopForwarder.ok) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'stop forwarder %{public}s', stopForwarder.message);
      }
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'stop forwarder threw %{public}s', this.errorMessage(error));
    }
    try {
      const stopCore = stopNativeXray();
      stopCoreOk = stopCore.ok;
      poisoned = poisoned || stopCore.poisoned;
      if (!stopCore.ok) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'stop xray %{public}s', stopCore.message);
      }
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'stop xray threw %{public}s', this.errorMessage(error));
    }
    const connection = this.vpnConnection;
    this.vpnConnection = null;
    this.tunFd = -1;
    let destroyFailed = false;
    if (this.destroyInFlight) {
      destroyFailed = true;
    } else if (connection !== null) {
      try {
        await this.destroyBounded(connection, 4000);
      } catch (error) {
        destroyFailed = true;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'destroy failed %{public}s', this.errorMessage(error));
      }
    }
    const stopFailed = !stopForwarderOk || !stopCoreOk || destroyFailed || poisoned;
    this.refreshCounters();
    this.resetPlaneTruth();
    this.status.xrayRunning = getNativeStats().xrayRunning;
    this.status.forwarderOk = getNativeStats().tunRunning;
    if (poisoned) {
      this.status.nativePoisoned = true;
      this.status.phase = PHASE_POISONED;
      this.status.lastError = '内核停不干净，已拆除隧道并禁止重启';
    } else if (stopFailed) {
      this.status.phase = PHASE_ERROR;
      this.status.lastError = '停止内核或销毁隧道失败，已尽力拆除';
    } else {
      this.status.phase = PHASE_STOPPED;
    }
    this.status.honestLabel = honestLabelOf(this.status);
    this.publish();
    const stopExtra: Record<string, Object> = {};
    this.emit('session-stop', stopExtra);
    this.rotateAccessAfterStop();
    this.cleaningUp = false;
    if (poisoned) {
      this.tripBreaker('native-poisoned');
      this.desiredRunning = false;
      this.status.desiredRunning = false;
      abortPoisonedNative();
      return;
    }
    if (destroyFailed) {
      this.destroyInFlight = true;
      this.desiredRunning = false;
      this.status.desiredRunning = false;
      this.tripBreaker('destroy-timeout');
      return;
    }
    this.dispatchLatest();
  }

  private async destroyBounded(conn: vpnExtension.VpnConnection, timeoutMs: number): Promise<void> {
    let finished = false;
    let timerId = -1;
    const work = conn.destroy().then(() => {
      finished = true;
    });
    const timer = new Promise<void>((_resolve: () => void, reject: (reason: Error) => void) => {
      timerId = setTimeout(() => {
        reject(new Error(`connection.destroy timeout ${timeoutMs}ms`));
      }, timeoutMs);
    });
    try {
      await Promise.race([work, timer]);
    } finally {
      if (timerId >= 0) {
        clearTimeout(timerId);
      }
    }
    if (!finished) {
      throw new Error(`connection.destroy timeout ${timeoutMs}ms`);
    }
  }

  private resetPlaneTruth(): void {
    this.status.vpnCreated = false;
    this.status.tunFdValid = false;
    this.status.tunFd = -1;
    this.status.forwarderOk = false;
    this.status.canaryOk = false;
    this.status.protectOk = false;
    this.status.directOk = false;
    this.status.proxyOk = false;
    this.status.nodeTcpOk = false;
    this.status.socksCanaryOk = false;
    this.status.evidenceAt = 0;
    this.status.lastSampleTunBytes = 0;
    this.status.lastSampleHevBytes = 0;
    this.everProven = false;
    this.socks.port = 0;
    this.socks.user = '';
    this.socks.pass = '';
    this.status.tunReceiving = false;
    this.status.dnsOk = false;
    this.status.evidenceRid = '';
    this.status.accessOffset = -1;
    this.status.probeRevision = 0;
    this.status.probeEpoch = 0;
    this.status.probePending = false;
    this.status.selfProbe = false;
    this.status.lastProvenRid = '';
    this.lastProvenRid = '';
    this.status.probeGoogleUrl = '';
    this.status.probeDirectUrl = '';
    this.status.fetchGoogleHttp = 0;
    this.status.fetchDirectHttp = 0;
    this.status.fetchDnsOk = false;
  }

  private publish(): void {
    if (this.cancelled && !this.cleaningUp) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'drop stale publish gen=%{public}s', this.generation);
      return;
    }
    this.writeStatusNow();
  }

  private forcePublish(): void {
    this.writeStatusNow();
  }

  private writeStatusNow(): void {
    this.status.at = Date.now();
    this.status.commandEpoch = this.commandEpoch;
    this.status.desiredRunning = this.desiredRunning;
    this.status.lastProvenRid = this.lastProvenRid;
    const stats = getNativeStats();
    this.status.xrayRunning = stats.xrayRunning;
    this.status.forwarderOk = stats.tunRunning;
    const native = this.diagnosticNative(stats);
    try {
      StatusStore.writeStatus(this.context, this.status);
      try {
        StatusStore.writeText(this.context, 'native-stats.json', JSON.stringify(native));
      } catch (sidecar) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'native-stats sidecar %{public}s', this.errorMessage(sidecar));
      }
    } catch (error) {
      this.status.phase = PHASE_ERROR;
      this.status.canaryOk = false;
      this.status.lastError = `状态写入失败：${this.errorMessage(error)}`;
      this.status.honestLabel = honestLabelOf(this.status);
      try {
        StatusStore.writeStatus(this.context, this.status);
      } catch (error2) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'status write still failing %{public}s', this.errorMessage(error2));
      }
    }
    // Independent best-effort history: never part of the connection-state contract.
    RuntimeJournal.sample(this.context,
      JSON.parse(serializeStatus(this.status)) as Record<string, Object>, native);
  }

  private diagnosticNative(stats: RuntimeStats): Record<string, Object> {
    const native: Record<string, Object> = {};
    native['xrayRunning'] = stats.xrayRunning;
    native['tunRunning'] = stats.tunRunning;
    native['poisoned'] = stats.poisoned;
    native['generation'] = this.generation;
    native['at'] = this.status.at;
    native['protectQueued'] = stats.protectQueued;
    native['protectAcked'] = stats.protectAcked;
    native['protectTimeout'] = stats.protectTimeout;
    native['protectVisible'] = stats.protectVisible;
    native['protectMeasured'] = stats.protectMeasured;
    native['protectTcp4'] = stats.protectTcp4;
    native['protectTcp6'] = stats.protectTcp6;
    native['protectUdp'] = stats.protectUdp;
    native['protectTotalUs'] = stats.protectTotalUs;
    native['protectMaxUs'] = stats.protectMaxUs;
    native['physicalIface'] = stats.physicalIface;
    // Keep optional diagnostic JSON opaque here: it cannot break status writes.
    native['hevDiagnostics'] = stats.hevDiagnostics;
    native['protectDiagnostics'] = this.protectDiagnostics;
    const absentRouting: Record<string, Object> = { 'enabled': false, 'active': false };
    native['appRouting'] = this.appRoutes?.diagnostics() ?? absentRouting;
    return native;
  }

  private breakerBlocks(): boolean {
    const path = `${this.context.filesDir}/circuit-breaker.json`;
    if (StatusStore.destExistsNonempty(path)) {
      const raw = StatusStore.readText(this.context, 'circuit-breaker.json');
      if (raw.length < 8) {
        return true;
      }
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        if (parsed['open'] !== true && parsed['open'] !== false) {
          return true;
        }
        if (parsed['open'] !== true) {
          return false;
        }
        const until = parsed['until'];
        if (typeof until !== 'number') {
          return true;
        }
        return Date.now() < until;
      } catch (error) {
        return true;
      }
    }
    const raw = StatusStore.readText(this.context, 'circuit-breaker.json');
    if (raw.length > 0 && raw.length < 8) {
      return true;
    }
    return false;
  }

  private parkStop(generation: string): void {
    this.commandEpoch += 1;
    const cmd = new VpnCommand();
    cmd.token = this.commandEpoch;
    cmd.kind = 'stop';
    cmd.generation = generation;
    cmd.mode = this.mode;
    this.latestCommand = cmd;
    this.desiredRunning = false;
    this.pendingStart = false;
    this.pendingGeneration = '';
    this.pendingMode = '';
    this.status.desiredRunning = false;
    this.status.commandEpoch = cmd.token;
  }

  private tripBreaker(reason: string): void {
    let count = 1;
    const raw = StatusStore.readText(this.context, 'circuit-breaker.json');
    if (raw.length >= 8) {
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        const prev = parsed['count'];
        if (typeof prev === 'number' && prev >= 1) {
          count = prev + 1;
        }
      } catch (error) {
        count = 1;
      }
    }
    const rec: Record<string, Object> = {};
    rec['open'] = true;
    rec['reason'] = reason;
    rec['failedGeneration'] = this.generation;
    rec['failedEpoch'] = this.commandEpoch;
    rec['count'] = count;
    rec['at'] = Date.now();
    const backoff = Math.min(30000 * count, 900000);
    rec['until'] = Date.now() + backoff;
    rec['nativePoisoned'] = reason === 'native-poisoned';
    StatusStore.writeText(this.context, 'circuit-breaker.json', JSON.stringify(rec));
  }

  private clearOrdinaryBreaker(): void {
    if (this.status.nativePoisoned) {
      return;
    }
    const raw = StatusStore.readText(this.context, 'circuit-breaker.json');
    if (raw.length < 8) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (parsed['nativePoisoned'] === true || parsed['reason'] === 'native-poisoned') {
        return;
      }
      parsed['open'] = false;
      parsed['count'] = 0;
      parsed['until'] = 0;
      parsed['clearedAt'] = Date.now();
      StatusStore.writeText(this.context, 'circuit-breaker.json', JSON.stringify(parsed));
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'breaker clear %{public}s', this.errorMessage(error));
    }
  }

  private rotateAccess(raw: string): string {
    const maxChars = 256000;
    if (raw.length <= maxChars) {
      return raw;
    }
    let next = raw.substring(raw.length - maxChars);
    const cut = next.indexOf('\n');
    if (cut >= 0 && cut + 1 < next.length) {
      next = next.substring(cut + 1);
    }
    return next;
  }

  private redactAccess(raw: string): string {
    const keys: string[] = ['user=', 'pass=', 'password=', 'token=', 'secret='];
    const lines = raw.split('\n');
    let out = '';
    for (let i = 0; i < lines.length; i++) {
      let line = lines[i];
      for (let k = 0; k < keys.length; k++) {
        const key = keys[k];
        let from = 0;
        while (true) {
          const idx = line.indexOf(key, from);
          if (idx < 0) {
            break;
          }
          let end = idx + key.length;
          while (end < line.length && line[end] !== ' ' && line[end] !== '\t') {
            end += 1;
          }
          line = `${line.substring(0, idx + key.length)}${line.substring(end)}`;
          from = idx + key.length;
        }
      }
      const local = 'tcp:127.0.0.1:';
      const idx = line.indexOf(local);
      if (idx >= 0) {
        const after = idx + local.length;
        let end = after;
        while (end < line.length && line[end] >= '0' && line[end] <= '9') {
          end += 1;
        }
        line = `${line.substring(0, after)}*${line.substring(end)}`;
      }
      if (out.length > 0) {
        out = `${out}\n${line}`;
      } else {
        out = line;
      }
    }
    return out;
  }

  private rememberXrayOwner(result: NativeResult): void {
    if (result.ownerSeq !== undefined && result.ownerSeq > 0) {
      this.xrayOwnerSeq = result.ownerSeq;
    }
  }

  private stopStartedXray(result?: NativeResult): NativeResult {
    const seq = (result !== undefined && result.ownerSeq !== undefined && result.ownerSeq > 0)
      ? result.ownerSeq : this.xrayOwnerSeq;
    if (seq > 0) {
      const stopped = stopNativeXrayOwned(seq);
      if (this.xrayOwnerSeq === seq) {
        this.xrayOwnerSeq = 0;
      }
      return stopped;
    }
    const skipped: NativeResult = {
      ok: true,
      message: 'xray owner mismatch; not stopped',
      poisoned: false,
      ownerSeq: 0
    };
    return skipped;
  }

  private commitXrayStartRecords(result: NativeResult): void {
    this.rememberXrayOwner(result);
    this.status.payloadDigest = digestText(this.outboundJson);
    try {
      StatusStore.writeStatus(this.context, this.status);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'live payload digest missing %{public}s', this.errorMessage(error));
    }
    try {
      AppliedPolicy.noteRunning(this.context, this.outboundJson);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'running payload digest missing %{public}s', this.errorMessage(error));
    }
    try {
      AppliedPolicy.record(this.context, this.outboundJson, this.status.generation);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'applied-policy receipt missing %{public}s', this.errorMessage(error));
    }
    const source = JSON.parse(this.outboundJson) as Record<string, Object>;
    if (source['channelMode'] === 'single') {
      const meta: Record<string, Object> = {};
      meta['name'] = source['singleName'] ?? '';
      meta['region'] = source['singleRegion'] ?? '';
      meta['split'] = false;
      meta['ytName'] = meta['name']; meta['usName'] = meta['name']; meta['hkName'] = meta['name'];
      meta['ytFailedOver'] = source['singleFailedOver'] === true;
      meta['usFailedOver'] = source['singleFailedOver'] === true;
      StatusStore.writeNodeMeta(this.context, JSON.stringify(meta));
      this.status.nodeName = meta['name'] as string;
      this.status.nodeRegion = meta['region'] as string;
    }
  }

  private async startXrayWithPortRetry(firstConfig: string): Promise<NativeResult> {
    let configJson = firstConfig;
    let coreResult = await startNativeXray(configJson, this.context.filesDir);
    if (coreResult.ok && this.isAlreadyRunning(coreResult.message)) {
      const mismatch: NativeResult = { ok: false, message: coreResult.message, poisoned: coreResult.poisoned };
      return mismatch;
    }
    for (let attempt = 0; attempt < 4 && !coreResult.ok; attempt++) {
      if (this.isAlreadyRunning(coreResult.message)) {
        break;
      }
      if (!this.isPortBusy(coreResult.message)) {
        break;
      }
      this.socks = newSocksSession();
      this.appRoutes?.reallocate(this.socks.port);
      configJson = buildRuntimeXrayConfig(this.outboundJson, this.socks, this.context.filesDir, '', this.outboundTrace,
        this.appRoutes?.ports ?? []);
      if (this.nodeSystemDns) {
        const retryConfig = JSON.parse(configJson) as Record<string, Object>;
        const resolvedConfig = JSON.parse(firstConfig) as Record<string, Object>;
        retryConfig['outbounds'] = resolvedConfig['outbounds'];
        retryConfig['dns'] = resolvedConfig['dns'];
        configJson = JSON.stringify(retryConfig);
      }
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'SOCKS port retry %{public}d', this.socks.port);
      coreResult = await startNativeXray(configJson, this.context.filesDir);
      if (coreResult.ok && this.isAlreadyRunning(coreResult.message)) {
        const mismatch: NativeResult = { ok: false, message: coreResult.message, poisoned: coreResult.poisoned };
        return mismatch;
      }
    }
    if (coreResult.ok) {
      this.rememberXrayOwner(coreResult);
    }
    return coreResult;
  }

  private isPortBusy(message: string): boolean {
    return message.indexOf('address already in use') >= 0 || message.indexOf('bind') >= 0 ||
      message.indexOf('Address already in use') >= 0;
  }

  private emit(kind: string, extra: Record<string, Object>): void {
    if (this.cancelled && !this.cleaningUp) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'drop stale emit %{public}s gen=%{public}s', kind, this.generation);
      return;
    }
    const stats = getNativeStats();
    extra['xrayRunning'] = stats.xrayRunning;
    extra['tunRunning'] = stats.tunRunning;
    extra['accessTags'] = this.accessTagSummary();
    extra['sessionRevision'] = this.status.sessionRevision;
    extra['socksPort'] = this.socks.port;
    try {
      EventStore.append(this.context, kind, this.status, extra);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'event snapshot %{public}s', this.errorMessage(error));
    }
    RuntimeJournal.event(this.context, kind,
      JSON.parse(serializeStatus(this.status)) as Record<string, Object>, this.diagnosticNative(stats), extra);
  }

  private readAccessLog(): string {
    let raw = StatusStore.readText(this.context, 'xray-access.log');
    if (raw.length === 0) {
      raw = StatusStore.readText(this.context, 'xray-access-pub.log');
    }
    return raw;
  }

  private accessWindow(): string {
    const raw = this.readAccessLog();
    const offset = this.status.accessOffset;
    if (raw.length === 0 || offset < 0) {
      return '';
    }
    if (offset > raw.length) {
      return '';
    }
    const slice = raw.substring(offset);
    return slice.length > 65536 ? slice.substring(slice.length - 65536) : slice;
  }

  private accessTagSummary(): string {
    const window = this.accessWindow();
    let googleProxy = false;
    let googleDirect = false;
    let uniqueDirect = false;
    let udp53Proxy = false;
    const lines = window.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const parsed = this.parseAccessLine(lines[i]);
      if (parsed['tag'].length === 0) {
        continue;
      }
      const dest = parsed['dest'].toLowerCase();
      if (parsed['proto'] === 'udp' && this.destPort(parsed['dest']) === 53 &&
        (parsed['tag'] === 'proxy' || parsed['tag'] === 'dns-out')) {
        udp53Proxy = true;
      }
      if ((parsed['tag'] === 'proxy' || parsed['tag'] === 'proxy-us' || parsed['tag'] === 'proxy-yt') && this.isGoogleDest(dest)) {
        googleProxy = true;
      }
      if (parsed['tag'] === 'direct' && this.isGoogleDest(dest)) {
        googleDirect = true;
      }
      if (parsed['tag'] === 'direct' && this.isDirectDest(dest)) {
        uniqueDirect = true;
      }
    }
    let out = '';
    if (udp53Proxy) {
      out = `${out}udp53Proxy,`;
    }
    if (uniqueDirect) {
      out = `${out}qqDirect,direct,`;
    }
    if (googleProxy) {
      out = `${out}googleProxy,`;
    }
    if (googleDirect) {
      out = `${out}googleDirect,`;
    }
    return out;
  }

  private noteProbe(tag: string, dest: string, ok: boolean): void {
    if (tag === 'proxy-yt') {
      this.generalLeg = recordProbeResult(this.generalLeg, dest, ok);
      return;
    }
    if (tag === 'proxy') {
      this.proxyLeg = recordProbeResult(this.proxyLeg, dest, ok);
    }
  }

  private payloadRoutingProfile(): string {
    try {
      const parsed = JSON.parse(this.outboundJson) as Record<string, Object>;
      const profile = parsed['routingProfile'];
      return typeof profile === 'string' ? profile : '';
    } catch (error) {
      return '';
    }
  }

  private payloadChannelMode(): string {
    try {
      const parsed = JSON.parse(this.outboundJson) as Record<string, Object>;
      return parsed['channelMode'] === 'dual' ? 'dual' : 'single';
    } catch (error) {
      return 'single';
    }
  }

  private payloadRouteMode(): string {
    try {
      const parsed = JSON.parse(this.outboundJson) as Record<string, Object>;
      const mode = parsed['routeMode'];
      if (mode === 'global') {
        return 'global';
      }
      if (mode === 'direct') {
        return 'direct';
      }
    } catch (error) {
      return 'rule';
    }
    return 'rule';
  }

  private tagsMatchRoute(tags: string): boolean {
    const udpOk = tags.indexOf('udp53Proxy') >= 0;
    if (!udpOk) {
      return false;
    }
    const mode = this.payloadRouteMode();
    if (mode === 'direct') {
      return tags.indexOf('googleDirect') >= 0 || tags.indexOf('qqDirect') >= 0 ||
        tags.indexOf('direct') >= 0;
    }
    if (mode === 'global') {
      return tags.indexOf('googleProxy') >= 0;
    }
    return tags.indexOf('googleProxy') >= 0 &&
      (tags.indexOf('qqDirect') >= 0 || tags.indexOf('direct') >= 0);
  }

  private parseAccessLine(line: string): Record<string, string> {
    const empty: Record<string, string> = {};
    empty['proto'] = '';
    empty['dest'] = '';
    empty['tag'] = '';
    if (line.indexOf('tun-in') < 0) {
      return empty;
    }
    let tag = '';
    if (line.indexOf('[tun-in -> proxy-yt]') >= 0) {
      tag = 'proxy-yt';
    } else if (line.indexOf('[tun-in -> proxy]') >= 0) {
      tag = 'proxy';
    } else if (line.indexOf('[tun-in -> direct]') >= 0) {
      tag = 'direct';
    } else if (line.indexOf('[tun-in -> dns-out]') >= 0) {
      tag = 'dns-out';
    } else {
      return empty;
    }
    let rest = line;
    const acc = line.indexOf('accepted ');
    if (acc >= 0) {
      rest = line.substring(acc + 9);
    }
    const space = rest.indexOf(' ');
    const tok = space >= 0 ? rest.substring(0, space) : rest;
    const colon = tok.indexOf(':');
    if (colon < 1) {
      return empty;
    }
    const proto = tok.substring(0, colon).toLowerCase();
    const dest = tok.substring(colon + 1);
    const rec: Record<string, string> = {};
    rec['proto'] = proto;
    rec['dest'] = dest;
    rec['tag'] = tag;
    return rec;
  }

  private destPort(dest: string): number {
    const idx = dest.lastIndexOf(':');
    if (idx < 0) {
      return -1;
    }
    const n = Number.parseInt(dest.substring(idx + 1), 10);
    return Number.isNaN(n) ? -1 : n;
  }

  private isGoogleDest(dest: string): boolean {
    return dest.indexOf('google') >= 0 || dest.indexOf('gstatic') >= 0 || dest.indexOf('youtube') >= 0 ||
      dest.indexOf('2001:4860') >= 0 || dest.indexOf('142.251') >= 0 || dest.indexOf('172.217') >= 0 ||
      dest.indexOf('216.58') >= 0 || dest.indexOf('2607:f8b0') >= 0;
  }

  private isDirectDest(dest: string): boolean {
    return dest.indexOf('qq.com') >= 0 || dest.indexOf('gtimg') >= 0 || dest.indexOf('qpic.cn') >= 0 ||
      dest.indexOf('baidu.com') >= 0 || dest.indexOf('183.3.') >= 0 || dest.indexOf('123.151.') >= 0 ||
      dest.indexOf('43.159.') >= 0 || dest.indexOf('43.174.') >= 0 || dest.indexOf('103.235.') >= 0 ||
      dest.indexOf('180.76.') >= 0 || dest.indexOf('220.181.') >= 0 || dest.indexOf('bilibili') >= 0 ||
      dest.indexOf('hdslb.com') >= 0 || dest.indexOf('192.168.3.') >= 0 || dest.indexOf('10.7.0.') >= 0;
  }

  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    if (businessError.message !== undefined && businessError.message.length > 0) {
      return businessError.message;
    }
    return JSON.stringify(error);
  }
}
