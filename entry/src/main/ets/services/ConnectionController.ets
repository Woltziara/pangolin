import { common } from '@kit.AbilityKit';
import { CONNECTION_POLICY } from './ConnectionPolicy';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  DataplaneStatus,
  PHASE_CANARY_OK,
  PHASE_ERROR,
  PHASE_STARTING,
  PHASE_PROBE_SNIFFING,
  PHASE_STOPPED
} from '../net/DataplaneStatus';
import { createStartWant, createVpnAbilityWant, MODE_FULL } from '../vpn/VpnConstants';
import { HuksSecretStore } from './HuksSecretStore';
import { NodeStore } from './NodeStore';
import { SettingsStore, SELECT_MANUAL } from './SettingsStore';
import { HEALTH_STATUS_MAX_AGE_MS, isConnectionEstablished } from '../net/ConnectionHealth';
import { PREPARE_HINT_FILE, prepareManualPlan, prepareSingleProxy, writePrepareHint } from './SplitRouter';
import { StatusStore } from './StatusStore';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'Conn';
const START_TIMEOUT_MS: number = 30000;

export class ConnectionController {
  private chain: Promise<void> = Promise.resolve();
  private cancelRequested: boolean = false;
  private startEpoch: number = 0;

  private enqueueStatus(work: () => Promise<DataplaneStatus>): Promise<DataplaneStatus> {
    const run = this.chain.then(work, work);
    this.chain = run.then(() => {
      return;
    }).catch(() => {
      return;
    });
    return run;
  }

  beginStartIntent(): number {
    this.cancelRequested = false;
    this.startEpoch += 1;
    return this.startEpoch;
  }

  isStartIntentLive(epoch: number): boolean {
    return epoch === this.startEpoch && !this.cancelRequested;
  }

  requestCancel(): void {
    this.cancelRequested = true;
    this.startEpoch += 1;
  }

  async start(context: common.UIAbilityContext, mode: string = MODE_FULL,
    epoch: number = -1): Promise<DataplaneStatus> {
    const token = epoch >= 0 ? epoch : this.beginStartIntent();
    if (!this.isStartIntentLive(token)) {
      return this.enqueueStatus(() => {
        return this.stopLocked(context);
      });
    }
    return this.enqueueStatus(() => {
      return this.startLocked(context, mode, token);
    });
  }

  async stop(context: common.UIAbilityContext, cancelIntent: boolean = true): Promise<DataplaneStatus> {
    if (cancelIntent) {
      this.requestCancel();
    }
    try {
      await vpnExtension.stopVpnExtensionAbility(createVpnAbilityWant());
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cancel stopVpn %{public}s', this.errorMessage(error));
    }
    return this.enqueueStatus(() => {
      return this.stopLocked(context);
    });
  }

  // A stale file is not a connection state. Reconcile it with the system
  // and the VPN owner; never test Internet reachability on this path.
  async reconcileStatus(context: common.UIAbilityContext, force: boolean = false): Promise<DataplaneStatus> {
    return this.enqueueStatus(async (): Promise<DataplaneStatus> => {
      const before = StatusStore.readStatus(context);
      const fresh = Date.now() - before.at <= HEALTH_STATUS_MAX_AGE_MS;
      if (before.at <= 0 || (fresh && !force) || (fresh && !before.vpnCreated)) { return before; }
      const generation = before.generation;
      const at = before.at;
      if (await this.boundedVpnBearerState() === 'absent') {
        await sleep(150);
        if (await this.boundedVpnBearerState() === 'absent') {
          const current = StatusStore.readStatus(context);
          if (current.generation !== generation || current.at !== at) { return current; }
          current.phase = PHASE_STOPPED;
          current.desiredRunning = false;
          current.vpnCreated = false;
          current.tunFdValid = false;
          current.tunFd = -1;
          current.xrayRunning = false;
          current.forwarderOk = false;
          current.canaryOk = false;
          current.probePending = false;
          current.connectionHealth = '';
          current.at = Date.now();
          current.honestLabel = '已断开';
          StatusStore.writeStatus(context, current);
          return current;
        }
      }
      const request = createVpnAbilityWant();
      request.parameters = { command: 'diagnose-connection-status', statusGeneration: generation, statusAt: at };
      // The diagnostic handler cannot create a tunnel or reconnect a node.
      vpnExtension.startVpnExtensionAbility(request).catch(() => {});
      const started = Date.now();
      while (Date.now() - started < 3000) {
        const current = StatusStore.readStatus(context);
        if (current.generation !== generation || current.at > at) { return current; }
        await sleep(150);
      }
      throw new Error('connection-owner-not-responding');
    });
  }

  private startIntentExpired(epoch: number): boolean {
    return !this.isStartIntentLive(epoch);
  }

  private async startLocked(context: common.UIAbilityContext, mode: string, epoch: number): Promise<DataplaneStatus> {
    const generation = Date.now().toString();
    try {
    if (this.startIntentExpired(epoch)) {
      return await this.stopLocked(context);
    }
    if (mode === MODE_FULL) {
      const prepared = await this.prepareCore(context);
      if (prepared.phase === PHASE_ERROR) {
        return prepared;
      }
    }
      if (this.startIntentExpired(epoch)) {
        return await this.stopLocked(context);
      }

      await vpnExtension.startVpnExtensionAbility(createStartWant(mode, generation));
      if (this.startIntentExpired(epoch)) {
        try {
          await vpnExtension.stopVpnExtensionAbility(createVpnAbilityWant());
        } catch (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'late start stopVpn %{public}s', this.errorMessage(error));
        }
        return await this.stopLocked(context);
      }
      return await this.waitPhase(context, START_TIMEOUT_MS, mode, generation);
    } catch (error) {
      const status = StatusStore.readStatus(context);
      status.phase = PHASE_ERROR;
      status.lastError = `打开失败：${this.errorMessage(error)}`;
      status.honestLabel = '打开失败';
      status.at = Date.now();
      StatusStore.writeStatus(context, status);
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', status.lastError);
      return status;
    }
  }

  private async stopLocked(context: common.UIAbilityContext): Promise<DataplaneStatus> {
    const live = StatusStore.readStatus(context);
    let stopError = '';
    try {
      await vpnExtension.stopVpnExtensionAbility(createVpnAbilityWant());
    } catch (error) {
      stopError = this.errorMessage(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'stopVpnExtensionAbility %{public}s', stopError);
    }
    const bearer = await this.waitVpnBearerGone(8000);
    if (stopError.length > 0 || bearer !== 'absent') {
      const failed = StatusStore.readStatus(context);
      failed.desiredRunning = false;
      failed.canaryOk = false;
      failed.at = Date.now();
      if (stopError.length > 0) {
        failed.phase = PHASE_ERROR;
        failed.lastError = `停止失败：${stopError}`;
        failed.honestLabel = '停止失败';
      } else if (bearer === 'unknown') {
        failed.phase = PHASE_ERROR;
        failed.lastError = '停止后读不到系统 VPN 状态，不能当成已停止';
        failed.honestLabel = '状态未知';
      } else {
        failed.phase = PHASE_ERROR;
        failed.lastError = '停止超时，系统 VPN 还在';
        failed.honestLabel = '停止失败';
      }
      StatusStore.writeStatus(context, failed);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'UI refused STOPPED bearer=%{public}s', bearer);
      return failed;
    }
    const status = new DataplaneStatus();
    status.phase = PHASE_STOPPED;
    status.honestLabel = '已停止';
    status.desiredRunning = false;
    status.canaryOk = false;
    status.vpnCreated = false;
    status.tunFd = -1;
    status.tunFdValid = false;
    status.forwarderOk = false;
    status.xrayRunning = false;
    status.generation = live.generation;
    status.sessionId = live.generation;
    status.nodeName = live.nodeName;
    status.nodeRegion = live.nodeRegion;
    status.commandEpoch = live.commandEpoch + 1;
    status.at = Date.now();
    StatusStore.writeStatus(context, status);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'UI wrote STOPPED after stopVpnExtensionAbility');
    return status;
  }

  private async prepareCore(context: common.UIAbilityContext): Promise<DataplaneStatus> {
    const status = new DataplaneStatus();
    status.phase = PHASE_STARTING;
    status.honestLabel = '正在测最快节点';
    StatusStore.writeStatus(context, status);
    try {
      // Phase C：固定节点模式不再全面测速，直接写 v=4 单节点 payload；
      // 固定失效时回退自动并留下可见提示。自动模式走既有 SplitRouter 路径。
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
          StatusStore.writeStatus(context, status);
          return status;
        }
      }
      if (plan.length === 0) {
        plan = await prepareSingleProxy(context);
      }
      if (plan.length > 0) {
        status.lastCanary = plan;
        status.honestLabel = plan;
        StatusStore.writeStatus(context, status);
      }
    } catch (error) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '节点准备失败';
      status.lastError = this.errorMessage(error);
      StatusStore.writeStatus(context, status);
      return status;
    }
    try {
      await HuksSecretStore.protectOutbound(context);
    } catch (error) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '新配置未应用';
      status.lastError = this.errorMessage(error);
      StatusStore.writeStatus(context, status);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'HUKS wrap %{public}s', status.lastError);
      return status;
    }
    const outboundJson = await HuksSecretStore.readOutbound(context);
    if (outboundJson.length < 20) {
      status.phase = PHASE_ERROR;
      status.honestLabel = '还没有节点配置';
      status.lastError = '请先导入节点后再打开穿山甲。安装包不含节点密码。';
      StatusStore.writeStatus(context, status);
      return status;
    }

    const meta = StatusStore.readNodeMeta(context);
    status.nodeName = meta.name;
    status.nodeRegion = meta.region;
    status.phase = PHASE_STARTING;
    status.honestLabel = '配置已就绪，等待系统隧道';
    StatusStore.writeStatus(context, status);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'outbound ready, xray will start in vpn process');
    return status;
  }

  private async waitPhase(context: common.UIAbilityContext, timeoutMs: number, mode: string,
    generation: string): Promise<DataplaneStatus> {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
      if (this.cancelRequested) {
        return await this.stopLocked(context);
      }
      const status = StatusStore.readStatus(context);
      if (status.generation.length > 0 && status.generation !== generation) {
        await sleep(400);
        continue;
      }
      if (status.phase === PHASE_ERROR) {
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

  private async waitVpnBearerGone(timeoutMs: number): Promise<string> {
    const started = Date.now();
    let last = 'unknown';
    while (Date.now() - started < timeoutMs) {
      last = await this.vpnBearerState();
      if (last === 'absent') {
        return 'absent';
      }
      await sleep(400);
    }
    return last;
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

  private async boundedVpnBearerState(): Promise<string> {
    return Promise.race([this.vpnBearerState(), sleep(1000).then((): string => 'unknown')]);
  }

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
