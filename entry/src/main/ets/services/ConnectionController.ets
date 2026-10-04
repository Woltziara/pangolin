import { systemBootId, monotonicMillis } from '../native/TunnelNative';
import { PlatformOperations } from './PlatformOperations';
import { OwnerExitRecovery } from './OwnerExitRecovery';
import { LIFECYCLE_GATE } from './LifecycleGate';
import { util, process } from '@kit.ArkTS';
import { deadline } from './AsyncDeadline';
import { AppRouteCapability } from './AppRouteCapability';
import { RunningSnapshot } from './RunningSnapshot';
import { BACKGROUND_PROBE_HOST } from './BackgroundProbeHost';
import { LAYERS_FILE, rebuildEvidence } from '../net/LayerEvidence';
import { CONTROL_FILE, OWNER_TERMINAL_FILE, STOP_UNCONFIRMED, terminalProven, controlBlocksStart } from '../net/OwnerTerminal';
import { common, appManager } from '@kit.AbilityKit';
import { CONNECTION_POLICY } from './ConnectionPolicy';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DataplaneStatus, PHASE_CANARY_OK, PHASE_ERROR, PHASE_STARTING,
  PHASE_PROBE_SNIFFING, PHASE_STOPPED
} from '../net/DataplaneStatus';
import { createStartWant, createStopWant, createVpnAbilityWant, BUNDLE_NAME, MODE_FULL } from '../vpn/VpnConstants';
import { HuksSecretStore } from './HuksSecretStore';
import { NodeStore } from './NodeStore';
import { SettingsStore, SELECT_MANUAL } from './SettingsStore';
import { HEALTH_STATUS_MAX_AGE_MS, isConnectionEstablished } from '../net/ConnectionHealth';
import { PREPARE_HINT_FILE, prepareManualPlan, prepareSingleProxy } from './SplitRouter';
import { StatusStore } from './StatusStore';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'Conn';
const START_TIMEOUT_MS: number = 30000;
const STOP_BUDGET_MS: number = 10000;

/** UI owns intent and observations, never the VPN process's resource truth. */
export class ConnectionController {
  private chain: Promise<void> = Promise.resolve();
  private stopFlight: Promise<DataplaneStatus> | null = null;
  private operations: PlatformOperations = new PlatformOperations();
  private activeControlId: string = '';
  private knownStoppedGeneration: string = '';
  private lastStopContext: common.UIAbilityContext | null = null;
  private cancelRequested: boolean = false;
  private startEpoch: number = 0;
  private stopEpoch: number = 0;
  private platformUncertain: boolean = false;
  private platformCalls: number = 0;
  private stopInFlight: number = 0;
  private externalMutationUnconfirmed: boolean = false;
  private dispatchedGeneration: string = '';

  private enqueueStatus(work: () => Promise<DataplaneStatus>): Promise<DataplaneStatus> {
    const run = this.chain.then(work, work);
    this.chain = run.then(() => {}).catch(() => {});
    return run;
  }
  beginStartIntent(): number { this.cancelRequested = false; return ++this.startEpoch; }
  isStartIntentLive(epoch: number): boolean { return epoch === this.startEpoch && !this.cancelRequested; }
  requestCancel(): void { this.cancelRequested = true; this.startEpoch += 1; }
  private startIntentExpired(epoch: number): boolean { return !this.isStartIntentLive(epoch); }

  async preflight(context: common.UIAbilityContext): Promise<void> {
    await deadline(AppRouteCapability.current(context), 10000, 'App 能力核验未完成，原连接保持不变');
  }
  async start(context: common.UIAbilityContext, mode: string = MODE_FULL,
    epoch: number = -1): Promise<DataplaneStatus> {
    const token = epoch >= 0 ? epoch : this.beginStartIntent();
    if (!this.isStartIntentLive(token)) return StatusStore.readStatus(context);
    const operation = this.enqueueStatus(async (): Promise<DataplaneStatus> => {
      const release = LIFECYCLE_GATE.beginPreparation();
      try { return await this.startLocked(context, mode, token); } finally { release(); }
    });
    try { return await deadline(operation, 45000, '连接操作未在期限内完成'); }
    catch (_error) {
      if (this.isStartIntentLive(token)) {
        this.requestCancel();
        if (this.dispatchedGeneration.length > 0) {
          this.writeControl(context, 'stop', 'unconfirmed', this.dispatchedGeneration, Date.now());
          this.stop(context).catch(() => {});
        }
      }
      return this.unconfirmed(context);
    }
  }

  // Cancellation is intentionally NOT queued behind a possibly slow prepare or
  // start. The owner also checks persisted intent before accepting late Wants.
  async stop(context: common.UIAbilityContext, cancelIntent: boolean = true): Promise<DataplaneStatus> {
    if (cancelIntent) this.requestCancel();
    BACKGROUND_PROBE_HOST.stop(context, 'Controller.stop');
    if (this.stopFlight !== null) return this.stopFlight;
    const run = this.stopLocked(context);
    this.stopFlight = run;
    try { return await run; } finally { if (this.stopFlight === run) this.stopFlight = null; }
  }

  private async platformCall(context: common.UIAbilityContext, kind: string, generation: string,
    action: () => Promise<void>, budget: number): Promise<void> {
    this.platformCalls += 1;
    try {
      await this.operations.run(context, kind, generation, action, budget, (): void => {
        this.platformCalls = this.operations.inFlight();
        // Do not recursively issue another stop. Inspection consumes the actual late outcome.
        if (this.lastStopContext !== null && this.stopInFlight === 0) {
          this.reconcileStatus(this.lastStopContext, true).catch(() => {});
        }
      });
    } catch (error) { this.platformUncertain = true; throw error as Error; }
    finally { this.platformCalls = this.operations.inFlight(); }
  }

  private async stopLocked(context: common.UIAbilityContext): Promise<DataplaneStatus> {
    this.lastStopContext = context;
    const ticket = ++this.stopEpoch;
    this.activeControlId = util.generateRandomUUID();
    const started = Date.now();
    const cutoff = this.monotonicNow() + STOP_BUDGET_MS;
    const live = StatusStore.readOwnerStatus(context);
    const priorControl = StatusStore.readStrictText(context, CONTROL_FILE);
    try {
      const maintenance = JSON.parse(priorControl || '{}') as Record<string, Object>;
      if (maintenance['kind'] === 'maintenance' && maintenance['state'] === 'pending') throw new Error('数据清理尚未结束，请在设置页完成原清理操作。');
    } catch (error) { if (priorControl.length > 0 && this.errorMessage(error).indexOf('数据清理') >= 0) throw error as Error; }
    try {
      const previous = JSON.parse(priorControl) as Record<string, Object>;
      if (previous['inheritedUnresolved'] === true || previous['platformPending'] === true &&
        (previous['kind'] !== 'stop' || previous['schema'] !== 2) && this.platformCalls === 0 && !this.platformUncertain) {
        this.externalMutationUnconfirmed = true;
      }
    } catch (_error) {}
    const target = this.dispatchedGeneration.length > 0 ? this.dispatchedGeneration : live.generation;
    const previousProof = live.phase === PHASE_STOPPED &&
      terminalProven(StatusStore.readText(context, OWNER_TERMINAL_FILE), live.generation, 0, started, live.ownerInstance) && live.generation === target;
    this.writeControl(context, 'stop', 'pending', target, started, true);
    this.stopInFlight += 1;
    try {
      // No native start was dispatched by this process and the owner already
      // recorded idle: cancel the preparation only, without inventing a new
      // resource terminal. This also permits a stopped 0.4.9 data migration.
      if (this.dispatchedGeneration.length === 0 && this.platformCalls === 0 &&
        !this.platformUncertain && !this.externalMutationUnconfirmed && !controlBlocksStart(priorControl) && !live.vpnCreated && !live.xrayRunning && !live.forwarderOk && !live.cleanupPending &&
        !this.operations.unresolvedStop(context) &&
        (live.phase === PHASE_STOPPED || live.phase === 'IDLE')) {
        this.writeControl(context, 'cancel', 'confirmed', target, started);
        return live;
      }
      // First ask the live owner to release Xray, HEV and its VpnConnection.
      // Stopping the extension process first prevents its asynchronous cleanup
      // from publishing the owner terminal and leaves the UI permanently in
      // STOP_UNCONFIRMED on real HarmonyOS devices.
      if (!previousProof) try {
        await this.platformCall(context, 'owner-stop', target, () => vpnExtension.startVpnExtensionAbility(createStopWant(target)), 1500);
      } catch (_error) { /* The durable stop fence still blocks late/new starts. */ }
      const ownerCutoff = Math.min(cutoff, this.monotonicNow() + 6500);
      while (this.monotonicNow() < ownerCutoff && ticket === this.stopEpoch) {
        const current = StatusStore.readOwnerStatus(context);
        const proof = StatusStore.readText(context, OWNER_TERMINAL_FILE);
        if (current.generation === target && current.phase === PHASE_STOPPED &&
          terminalProven(proof, target, previousProof ? 0 : started, Date.now(), current.ownerInstance)) break;
        await sleep(Math.min(100, Math.max(0, ownerCutoff - this.monotonicNow())));
      }
      try { if (!this.operations.unresolvedStop(context)) await this.platformCall(context, 'system-stop', target, () => vpnExtension.stopVpnExtensionAbility(createVpnAbilityWant()), Math.max(1, Math.min(2500, cutoff - this.monotonicNow()))); }
      catch (_error) { /* Failure/late completion is observation, never a stop proof. */ }
      while (this.monotonicNow() < cutoff && ticket === this.stopEpoch) {
        const current = StatusStore.readOwnerStatus(context);
        const bearer = await this.boundedVpnBearerState(Math.min(800, Math.max(1, cutoff - this.monotonicNow())));
        if (ticket !== this.stopEpoch) return StatusStore.readStatus(context);
        this.writeSystemObservation(context, target, bearer);
        const proof = StatusStore.readText(context, OWNER_TERMINAL_FILE);
        if (!this.externalMutationUnconfirmed && this.platformCalls === 0 && !this.operations.unresolvedStop(context) && bearer === 'absent' && current.generation === target &&
          current.phase === PHASE_STOPPED && terminalProven(proof, target, previousProof ? 0 : started, Date.now(), current.ownerInstance)) {
          this.platformUncertain = false; this.dispatchedGeneration = '';
          this.writeControl(context, 'stop', 'confirmed', target, started, false, previousProof ? 0 : started);
          this.knownStoppedGeneration = target;
          return current;
        }
        await sleep(Math.min(150, Math.max(0, cutoff - this.monotonicNow())));
      }
      if (ticket === this.stopEpoch) {
        this.platformUncertain = true;
        this.writeControl(context, 'stop', 'unconfirmed', target, started);
      }
      return this.unconfirmed(context);
    } finally { this.stopInFlight -= 1; }
  }

  async reconcileStatus(context: common.UIAbilityContext, force: boolean = false): Promise<DataplaneStatus> {
    const projected = StatusStore.readStatus(context);
    if (projected.operationState === 'owner-exit-confirmed') return projected;
    const before = StatusStore.readOwnerStatus(context);
    const controlBefore = StatusStore.readText(context, CONTROL_FILE);
    const fresh = before.at > 0 && Date.now() >= before.at && Date.now() - before.at <= HEALTH_STATUS_MAX_AGE_MS;
    if (fresh && !force && !controlBlocksStart(controlBefore)) return StatusStore.readStatus(context);
    const bearer = await this.boundedVpnBearerState(800);
    if (StatusStore.readText(context, CONTROL_FILE) !== controlBefore) return StatusStore.readStatus(context);
    const latest = StatusStore.readOwnerStatus(context);
    if (latest.generation !== before.generation) return StatusStore.readStatus(context);
    this.writeSystemObservation(context, before.generation, bearer);
    let control: Record<string, Object> = {};
    try { control = JSON.parse(controlBefore || '{}') as Record<string, Object>; } catch (_error) { return this.unconfirmed(context); }
    const boot = this.bootIdentity();
    const storedBoot = typeof control['bootId'] === 'string' ? control['bootId'] as string : latest.bootId;
    const previousBoot = storedBoot.length > 0 ? storedBoot : typeof control['observedBootId'] === 'string' ? control['observedBootId'] as string : '';
    // Record that a legacy unresolved state was observed during this boot. Only a later
    // changed kernel boot ID can prove that its process resources cannot survive.
    if (boot.length > 0 && previousBoot.length === 0 && controlBefore.length > 0 && controlBlocksStart(controlBefore)) {
      control['observedBootId'] = boot;
      StatusStore.compareText(context, CONTROL_FILE, controlBefore, JSON.stringify(control));
      return StatusStore.readStatus(context);
    }
    if (boot.length > 0 && previousBoot.length > 0 && previousBoot !== boot && bearer === 'absent' &&
      this.operations.inFlight() === 0 && this.stopInFlight === 0) {
      this.operations.retireBeforeBoot(context, boot);
      if (!this.operations.unresolvedStop(context)) {
        const released: Record<string, Object> = { 'writer': 'ui-system-observer', 'kind': 'system-reboot-release',
          'generation': latest.generation, 'oldBootId': previousBoot, 'newBootId': boot, 'bearer': 'absent', 'at': Date.now() };
        StatusStore.writeText(context, 'system-observation.json', JSON.stringify(released));
        this.platformUncertain = false; this.externalMutationUnconfirmed = false; this.dispatchedGeneration = '';
        this.activeControlId = util.generateRandomUUID();
        // Retain oldBootId here so the reboot observation can be independently verified on read.
        const settled: Record<string, Object> = { 'schema': 2, 'kind': 'cancel', 'state': 'confirmed',
          'generation': latest.generation, 'bootId': previousBoot, 'requestedAt': Date.now(), 'platformPending': false };
        if (!StatusStore.compareText(context, CONTROL_FILE, controlBefore, JSON.stringify(settled))) return StatusStore.readStatus(context);
        return StatusStore.readStatus(context);
      }
    }
    const originalStopped = latest.phase === PHASE_STOPPED &&
      terminalProven(StatusStore.readText(context, OWNER_TERMINAL_FILE), latest.generation, 0, Date.now(), latest.ownerInstance);
    // A fresh OS absence plus ORIGINAL owner proof may consume a real completed operation.
    // Never call stop()/start() just to paint a status or make an empty replacement attest.
    if (originalStopped && bearer === 'absent' && !this.operations.unresolvedStop(context) &&
      this.platformCalls === 0 && this.stopInFlight === 0 && !this.externalMutationUnconfirmed && control['inheritedUnresolved'] !== true &&
      control['kind'] === 'stop' && control['generation'] === latest.generation &&
      (control['platformPending'] !== true || control['schema'] === 2 &&
        (control['controllerInstance'] === this.operations.instance && this.operations.inFlight() === 0 ||
          this.operations.completedControl(context, typeof control['operationId'] === 'string' ? control['operationId'] as string : '')))) {
      this.platformUncertain = false; this.dispatchedGeneration = ''; this.knownStoppedGeneration = latest.generation;
      this.activeControlId = typeof control['operationId'] === 'string' ? control['operationId'] as string : util.generateRandomUUID();
      this.writeControl(context, 'stop', 'confirmed', latest.generation,
        typeof control['requestedAt'] === 'number' ? control['requestedAt'] as number : Date.now(), false, 0);
      return StatusStore.readStatus(context);
    }
    if (originalStopped || before.phase === 'IDLE') return StatusStore.readStatus(context);
    if (fresh && bearer === 'absent' && latest.at === before.at && latest.vpnCreated &&
      ['FORWARDER_RUNNING', 'CANARY_OK', 'UNPROVEN', 'DEGRADED', 'DEGRADED_UNPROVEN'].indexOf(latest.phase) >= 0 &&
      this.operations.inFlight() === 0 && this.stopInFlight === 0 && this.platformCalls === 0 &&
      control['platformPending'] !== true) {
      // The system bearer is already gone even if the previous owner heartbeat
      // is young. Present recovery now; this is NOT a resource-release proof.
      const missing: Record<string, Object> = { 'kind': 'system-bearer-absence',
        'generation': latest.generation, 'ownerInstance': latest.ownerInstance, 'ownerAt': latest.at,
        'at': Date.now(), 'bearer': 'absent', 'writer': 'ui-system-observer' };
      StatusStore.writeText(context, 'system-observation.json', JSON.stringify(missing));
      return StatusStore.readStatus(context);
    }
    if (!fresh) {
      // Once the OS VPN bearer is gone, a diagnostic Want can only launch an
      // empty extension. It cannot attest the lost owner or unblock restart.
      if (bearer !== 'absent') {
        const request = createVpnAbilityWant();
        request.parameters = { command: 'diagnose-connection-status', statusGeneration: before.generation, statusAt: before.at };
        try { await deadline(vpnExtension.startVpnExtensionAbility(request), 800, '状态查询超时'); } catch (_error) {}
        if (StatusStore.readText(context, CONTROL_FILE) !== controlBefore) return StatusStore.readStatus(context);
        const now = StatusStore.readOwnerStatus(context);
        if (now.generation !== before.generation || now.at > before.at) return StatusStore.readStatus(context);
      }
      const observation: Record<string, Object> = { 'generation': before.generation, 'at': Date.now(),
        'bearer': bearer, 'ownerResponsive': false, 'writer': 'ui-system-observer' };
      StatusStore.writeText(context, 'system-observation.json', JSON.stringify(observation));
    }
    return StatusStore.readStatus(context);
  }

  async rebuild(context: common.UIAbilityContext): Promise<DataplaneStatus> {
    const epoch = this.beginStartIntent();
    return this.enqueueStatus(async (): Promise<DataplaneStatus> => {
      const release = LIFECYCLE_GATE.beginPreparation();
      try {
      const live = StatusStore.readOwnerStatus(context);
      if (live.generation.length === 0 || !live.desiredRunning) throw new Error('没有当前运行线路，请使用连接。');
      const snapshot = await deadline(RunningSnapshot.read(context), 10000, '运行快照核验超时，原连接不变');
      if (snapshot.generation !== live.generation || snapshot.payloadDigest !== live.payloadDigest ||
        snapshot.revision !== live.sessionRevision) throw new Error('快照不属于当前运行线路，未重建 VPN。');
      if (!this.isStartIntentLive(epoch)) return StatusStore.readStatus(context);
      const latest = StatusStore.readOwnerStatus(context);
      if (latest.generation !== live.generation || latest.sessionRevision !== live.sessionRevision || !latest.desiredRunning) {
        throw new Error('故障现场已变化，未重建 VPN。');
      }
      const stopped = await this.stop(context, false);
      if (!this.isStartIntentLive(epoch) || stopped.phase !== PHASE_STOPPED) return stopped;
      // Re-read the same encrypted snapshot. No call to prepareCore/SplitRouter,
      // current settings or any automatic candidate selection occurs here.
      const checked = await deadline(RunningSnapshot.read(context, snapshot.id), 10000, '原快照重新核验超时');
      if (!this.isStartIntentLive(epoch)) return StatusStore.readStatus(context);
      return await this.dispatchStart(context, MODE_FULL, epoch, checked.id);
      } finally { release(); }
    });
  }

  async recoverStoppedOwner(context: common.UIAbilityContext, knownEmptyPid: number = -1): Promise<DataplaneStatus> {
    this.requestCancel();
    return this.enqueueStatus(async (): Promise<DataplaneStatus> => {
      const release = LIFECYCLE_GATE.beginPreparation();
      try {
        if (this.stopInFlight > 0 || this.platformCalls > 0 || this.externalMutationUnconfirmed) {
          throw new Error('上一次连接操作尚未结束，请稍后重试');
        }
        await OwnerExitRecovery.recover(context, this.operations, knownEmptyPid);
        this.platformUncertain = false; this.dispatchedGeneration = '';
        BACKGROUND_PROBE_HOST.stop(context, 'Controller.owner-exit');
        return StatusStore.readStatus(context);
      } finally { release(); }
    });
  }

  /** Resume the exact committed session after the previous VPN process vanished. */
  async resumeAfterOwnerExit(context: common.UIAbilityContext, knownEmptyPid: number = -1): Promise<DataplaneStatus> {
    const live = StatusStore.readOwnerStatus(context);
    if (live.generation.length === 0 || !live.desiredRunning) throw new Error('没有待恢复的运行线路');
    const snapshot = await deadline(RunningSnapshot.read(context), 10000, '原线路快照核验超时');
    if (snapshot.generation !== live.generation || snapshot.revision !== live.sessionRevision ||
      snapshot.payloadDigest !== live.payloadDigest) throw new Error('原线路快照与旧连接不一致，未更换节点');
    const stopped = await this.recoverStoppedOwner(context, knownEmptyPid);
    if (stopped.phase !== PHASE_STOPPED) return stopped;
    const checked = await deadline(RunningSnapshot.read(context, snapshot.id), 10000, '原线路快照重新核验超时');
    if (checked.generation !== live.generation || checked.revision !== live.sessionRevision ||
      checked.payloadDigest !== live.payloadDigest) throw new Error('原线路快照已变化，未更换节点');
    const epoch = this.beginStartIntent();
    return this.enqueueStatus(async (): Promise<DataplaneStatus> => {
      const release = LIFECYCLE_GATE.beginPreparation();
      try { return await this.dispatchStart(context, MODE_FULL, epoch, checked.id); }
      finally { release(); }
    });
  }

  /** The OS VPN may be gone while its original extension process still lives. */
  async resumeWithAbsentBearer(context: common.UIAbilityContext): Promise<DataplaneStatus> {
    if (await this.boundedVpnBearerState(800) !== 'absent') {
      throw new Error('系统 VPN 状态已变化，请重新检查');
    }
    const rows = await deadline(appManager.getRunningProcessInformation(), 1800, '无法核对穿山甲进程');
    if (!rows.some((row: appManager.ProcessInformation) => row.pid === process.pid && row.uid === process.uid &&
      row.bundleNames.indexOf(BUNDLE_NAME) >= 0)) throw new Error('穿山甲进程清单不完整，未恢复连接');
    let vpnPid = -1;
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      if (row.pid === process.pid) continue;
      if (row.uid !== process.uid || row.bundleNames.indexOf(BUNDLE_NAME) < 0 ||
        row.processName !== `${BUNDLE_NAME}:vpn`) {
        throw new Error('仍有身份未确认的后台进程，已保留原连接现场');
      }
      if (vpnPid > 0) throw new Error('检测到多个 VPN 后台进程，已保留现场');
      vpnPid = row.pid;
    }
    if (vpnPid < 0) return this.resumeAfterOwnerExit(context);
    const before = StatusStore.readStrictText(context, CONTROL_FILE);
    const ownerRaw = StatusStore.readStrictText(context, 'dataplane-status.json');
    const owner = StatusStore.readOwnerStatus(context);
    const nonce = util.generateRandomUUID();
    const want = createVpnAbilityWant();
    want.parameters = { command: 'diagnose-process-visibility', recoveryNonce: nonce };
    await deadline(vpnExtension.startVpnExtensionAbility(want), 2500, 'VPN 进程核验超时');
    let ack: Record<string, Object> = {};
    for (let i = 0; i < 20; i++) {
      try { ack = JSON.parse(StatusStore.readStrictText(context, 'owner-visibility.json') || '{}') as Record<string, Object>; }
      catch (_error) { ack = {}; }
      if (ack['nonce'] === nonce) break;
      await sleep(100);
    }
    if (ack['nonce'] !== nonce || ack['pid'] !== vpnPid ||
      StatusStore.readStrictText(context, CONTROL_FILE) !== before ||
      StatusStore.readStrictText(context, 'dataplane-status.json') !== ownerRaw ||
      await this.boundedVpnBearerState(800) !== 'absent') {
      throw new Error('VPN 后台身份或系统状态已变化，请重新检查');
    }
    const latest = await deadline(appManager.getRunningProcessInformation(), 1800, '无法复核 VPN 进程');
    if (!latest.some((row: appManager.ProcessInformation) => row.pid === vpnPid && row.uid === process.uid &&
      row.processName === `${BUNDLE_NAME}:vpn` && row.bundleNames.indexOf(BUNDLE_NAME) >= 0)) {
      throw new Error('VPN 后台进程已变化，请重新检查');
    }
    if (ack['empty'] === true) return this.resumeAfterOwnerExit(context, vpnPid);
    if (ack['empty'] === false && ack['generation'] === owner.generation &&
      ack['ownerInstance'] === owner.ownerInstance) return this.rebuild(context);
    throw new Error('VPN 后台与旧连接不属于同一进程，已保留现场');
  }

  private async startLocked(context: common.UIAbilityContext, mode: string, epoch: number): Promise<DataplaneStatus> {
    try {
      if (this.startIntentExpired(epoch)) return StatusStore.readStatus(context);
      if (this.operations.unresolvedStop(context) || this.platformUncertain || this.platformCalls > 0 || this.stopInFlight > 0 ||
        StatusStore.readStatus(context).phase === STOP_UNCONFIRMED ||
        controlBlocksStart(StatusStore.readText(context, CONTROL_FILE))) return this.unconfirmed(context);
      const live = StatusStore.readStatus(context);
      if ((live.phase === PHASE_ERROR || live.phase === 'POISONED') && !live.desiredRunning) return this.unconfirmed(context);
      if (live.cleanupPending) return this.unconfirmed(context);
      if (live.desiredRunning && (live.vpnCreated || live.xrayRunning || live.forwarderOk)) return StatusStore.readStatus(context);
      await this.preflight(context);
      if (this.startIntentExpired(epoch)) return StatusStore.readStatus(context);
      if (mode === MODE_FULL) {
        const prepared = await this.prepareCore(context, epoch);
        if (prepared.phase === PHASE_ERROR) return prepared;
      }
      if (this.startIntentExpired(epoch)) return StatusStore.readStatus(context);
      return await this.dispatchStart(context, mode, epoch, '');
    } catch (error) {
      if (this.startIntentExpired(epoch)) return StatusStore.readStatus(context);
      BACKGROUND_PROBE_HOST.stop(context, 'Controller.start.failed');
      const status = StatusStore.readStatus(context);
      status.phase = PHASE_ERROR; status.lastError = `打开失败：${this.errorMessage(error)}`;
      status.honestLabel = '打开失败'; // local display only
      return status;
    }
  }

  private async dispatchStart(context: common.UIAbilityContext, mode: string, epoch: number,
    snapshotId: string): Promise<DataplaneStatus> {
    if (!this.isStartIntentLive(epoch)) return StatusStore.readStatus(context);
    if (this.operations.unresolvedStop(context) || this.platformUncertain || this.platformCalls > 0 || this.stopInFlight > 0 ||
      controlBlocksStart(StatusStore.readStrictText(context, CONTROL_FILE))) return this.unconfirmed(context);
    const generation = util.generateRandomUUID();
    this.activeControlId = util.generateRandomUUID();
    const started = Date.now();
    this.dispatchedGeneration = generation;
    this.writeControl(context, 'start', 'pending', generation, started, true);
    const want = createStartWant(mode, generation);
    if (want.parameters === undefined) want.parameters = {};
    want.parameters['controlIntentId'] = generation;
    want.parameters['recoverySnapshotId'] = snapshotId;
    BACKGROUND_PROBE_HOST.start(context, 'Controller.startTunnel');
    try { await this.platformCall(context, 'start', generation, () => vpnExtension.startVpnExtensionAbility(want), 5000); }
    catch (_error) {
      // The API is not cancelled by the timeout. Fence a late delivery in the
      // VPN owner using this durable stop intent; do not authorize a new start.
      if (this.isStartIntentLive(epoch)) {
        this.requestCancel();
        this.writeControl(context, 'stop', 'unconfirmed', generation, started);
      }
      BACKGROUND_PROBE_HOST.stop(context, 'Controller.start.uncertain');
      return this.unconfirmed(context);
    }
    if (!this.isStartIntentLive(epoch)) return StatusStore.readStatus(context);
    this.writeControl(context, 'start', 'pending', generation, started);
    const result = await this.waitPhase(context, START_TIMEOUT_MS, mode, generation);
    if (this.isStartIntentLive(epoch) && result.generation === generation &&
      isConnectionEstablished(result, Date.now())) {
      this.writeControl(context, 'start', 'confirmed', generation, started);
    }
    if (result.phase === PHASE_ERROR || result.phase === PHASE_STOPPED) {
      BACKGROUND_PROBE_HOST.stop(context, 'Controller.start.finished');
      if (this.isStartIntentLive(epoch)) {
        const ended = await this.stop(context, false);
        if (ended.phase !== PHASE_STOPPED) return ended;
      }
    }
    return result;
  }

  private writeControl(context: common.UIAbilityContext, kind: string, state: string, generation: string, since: number, submitting: boolean = false, proofNotBefore: number = -1): void {
    const r: Record<string, Object> = {};
    r['schema'] = 2; r['bootId'] = this.bootIdentity(); r['operationId'] = this.activeControlId; r['controllerInstance'] = this.operations.instance;
    r['kind'] = kind; r['state'] = state; r['generation'] = generation; r['intentId'] = generation;
    r['requestedAt'] = since; r['at'] = Date.now(); r['proofNotBefore'] = proofNotBefore >= 0 ? proofNotBefore : since;
    r['inheritedUnresolved'] = this.externalMutationUnconfirmed;
    r['platformPending'] = submitting || this.platformCalls > 0 || this.externalMutationUnconfirmed;
    const expected = StatusStore.readStrictText(context, CONTROL_FILE);
    const prior = JSON.parse(expected || '{}') as Record<string, Object>;
    const admission = submitting && state === 'pending';
    if (prior['kind'] === 'maintenance' && prior['state'] === 'pending') throw new Error('数据清理尚未结束');
    if (!admission && prior['schema'] === 2 && typeof prior['operationId'] === 'string' &&
      prior['operationId'] !== this.activeControlId) throw new Error('本次操作已被更新的意图替代，旧回执未覆盖新连接。');
    if (admission && kind === 'start' && controlBlocksStart(expected)) throw new Error('前一连接操作尚未结案');
    if (!StatusStore.compareText(context, CONTROL_FILE, expected, JSON.stringify(r))) throw new Error('连接意图并发变化，未覆盖。');
  }
  private writeSystemObservation(context: common.UIAbilityContext, generation: string, bearer: string): void {
    const r: Record<string, Object> = {};
    r['generation'] = generation; r['bearer'] = bearer; r['at'] = Date.now(); r['writer'] = 'ui-system-observer';
    StatusStore.writeText(context, 'system-observation.json', JSON.stringify(r));
  }
  private unconfirmed(context: common.UIAbilityContext): DataplaneStatus {
    const observed = StatusStore.readOwnerStatus(context);
    observed.phase = STOP_UNCONFIRMED; observed.honestLabel = '需要恢复连接';
    observed.operationState = 'unconfirmed';
    observed.lastError = '请回首页点“恢复连接”，按手机当前状态完成处理。';
    return observed;
  }
  private async prepareCore(context: common.UIAbilityContext, epoch: number): Promise<DataplaneStatus> {
    const status = new DataplaneStatus();
    status.phase = PHASE_STARTING;
    status.honestLabel = '正在测最快节点';
    
    try {
      // Phase C：固定节点模式不再全面测速，直接写 v=4 单节点 payload；
      // 固定失效时回退自动并留下可见提示。自动模式走既有 SplitRouter 路径。
      NodeStore.loadNodes(context); // validate the whole catalog before preparing any payload
      const settings = SettingsStore.load(context);
      StatusStore.removeFile(context, PREPARE_HINT_FILE);
      let plan = '';
      if (CONNECTION_POLICY.mode(context) === 'dual' && settings.selectionMode === SELECT_MANUAL && settings.manualNodeId.length > 0 &&
        settings.chatgptNodeId === settings.manualNodeId && settings.generalNodeId === settings.manualNodeId) {
        status.honestLabel = '正在使用固定节点';
        plan = prepareManualPlan(context, settings.manualNodeId);
        if (plan.length === 0) {
          status.phase = PHASE_ERROR;
          status.honestLabel = '节点准备失败';
          status.lastError = '选定节点不存在或暂不支持连接，请重新选择节点。';
          
          return status;
        }
      }
      if (plan.length === 0) {
        plan = await prepareSingleProxy(context);
      }
      if (plan.length > 0) {
        status.lastCanary = plan;
        status.honestLabel = plan;
        
      }
    } catch (error) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '节点准备失败';
      status.lastError = this.errorMessage(error);
      
      return status;
    }
    try {
      await HuksSecretStore.protectOutbound(context, (): boolean => this.isStartIntentLive(epoch));
    } catch (error) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '新配置未应用';
      status.lastError = this.errorMessage(error);
      
      hilog.error(LOG_DOMAIN, LOG_TAG, 'HUKS wrap %{public}s', status.lastError);
      return status;
    }
    const outboundJson = await HuksSecretStore.readOutbound(context);
    if (outboundJson.length < 20) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '还没有节点配置';
      status.lastError = '请先导入节点后再打开穿山甲。安装包不含节点密码。';
      
      return status;
    }

    const meta = StatusStore.readNodeMeta(context);
    status.nodeName = meta.name;
    status.nodeRegion = meta.region;
    status.phase = PHASE_STARTING;
    status.honestLabel = '配置已就绪，等待系统隧道';
    
    hilog.info(LOG_DOMAIN, LOG_TAG, 'outbound ready, xray will start in vpn process');
    return status;
  }

  private async waitPhase(context: common.UIAbilityContext, timeoutMs: number, mode: string,
    generation: string): Promise<DataplaneStatus> {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
      if (this.cancelRequested) { return StatusStore.readStatus(context); }
      const status = StatusStore.readStatus(context);
      if (status.generation.length > 0 && status.generation !== generation) {
        await sleep(400);
        continue;
      }
      if (status.phase === PHASE_ERROR || status.phase === PHASE_STOPPED && status.generation === generation) {
        return status;
      }
      if (mode === MODE_FULL && isConnectionEstablished(status, Date.now()) && status.sessionRevision >= 1) {
        if (status.connectionHealth === 'reachable') { this.rememberLastGood(context); }
        return status;
      }
      if (mode !== MODE_FULL && status.phase === PHASE_PROBE_SNIFFING) {
        return status;
      }
      await sleep(400);
    }
    const last = StatusStore.readStatus(context);
    if (last.generation.length > 0 && last.generation !== generation) {
      const mismatch = new DataplaneStatus();
      mismatch.phase = PHASE_ERROR;
      mismatch.generation = generation;
      mismatch.canaryOk = false;
      mismatch.lastError = '启动超时，读到的是旧会话，不能当成已连接';
      mismatch.honestLabel = '打开失败';
      return mismatch;
    }
    if (last.phase !== PHASE_CANARY_OK) {
      // A completed system tunnel is not a failed start merely because a
      // network/routing check has not finished. Return the truthful health
      // projection so the UI can offer disconnect/check actions.
      if (last.desiredRunning && last.vpnCreated && last.tunFdValid &&
        last.xrayRunning && last.forwarderOk && last.at > 0 &&
        Date.now() - last.at < HEALTH_STATUS_MAX_AGE_MS) {
        return last;
      }
      const unproven = new DataplaneStatus();
      unproven.phase = PHASE_ERROR;
      unproven.generation = generation;
      unproven.sessionRevision = last.sessionRevision;
      unproven.canaryOk = false;
      unproven.lastError = '启动超时，没有本会话新鲜流量证据';
      unproven.honestLabel = '打开失败';
      return unproven;
    }
    return last;
  }

  /**
   * 网络检查成功后，把实际使用的节点（分流取美国侧）
   * 记入 settings.lastGoodNodeId，供固定模式预选。只在 UI 观察到的连接成功
   * 时记录；会话中途故障切换到备用节点不在此更新（简化取舍，见 Phase C 说明）。
   */
  private rememberLastGood(context: common.UIAbilityContext): void {
    try {
      const meta = StatusStore.readNodeMeta(context);
      const used = meta.usName.length > 0 ? meta.usName : meta.name;
      if (used.length === 0) {
        return;
      }
      const nodes = NodeStore.loadNodes(context);
      for (let i = 0; i < nodes.length; i++) {
        if (nodes[i].name === used) {
          SettingsStore.update(context, (settings) => {
            settings.lastGoodNodeId = nodes[i].id;
          });
          return;
        }
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'rememberLastGood %{public}s', this.errorMessage(error));
    }
  }

  private async vpnBearerState(): Promise<string> {
    try {
      const nets = await connection.getAllNets();
      for (let i = 0; i < nets.length; i++) {
        const caps = await connection.getNetCapabilities(nets[i]);
        const types = caps.bearerTypes;
        if (types === undefined) {
          continue;
        }
        for (let j = 0; j < types.length; j++) {
          if (types[j] === connection.NetBearType.BEARER_VPN) {
            return 'present';
          }
        }
      }
      return 'absent';
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'vpn bearer query %{public}s', this.errorMessage(error));
      return 'unknown';
    }
  }

  private async boundedVpnBearerState(budget: number = 800): Promise<string> {
    try { return await deadline(this.vpnBearerState(), Math.max(1, budget), 'vpn-state-deadline'); } catch (_error) { return 'unknown'; }
  }

  private bootIdentity(): string { try { return systemBootId(); } catch (_error) { return ''; } }
  private monotonicNow(): number { try { return monotonicMillis(); } catch (_error) { return Date.now(); } }

  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    if (businessError.message !== undefined && businessError.message.length > 0) {
      return businessError.message;
    }
    return JSON.stringify(error);
  }
}

export const CONNECTION_CONTROLLER: ConnectionController = new ConnectionController();

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
