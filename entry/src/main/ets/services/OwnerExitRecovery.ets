import { appManager, common } from '@kit.AbilityKit';
import { process, util } from '@kit.ArkTS';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { systemBootId } from '../native/TunnelNative';
import { createVpnAbilityWant, BUNDLE_NAME } from '../vpn/VpnConstants';
import { CONTROL_FILE } from '../net/OwnerTerminal';
import { StatusStore } from './StatusStore';
import { PlatformOperations } from './PlatformOperations';
import { deadline } from './AsyncDeadline';

const ACK_FILE: string = 'owner-visibility.json';
function pause(ms: number): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, ms); }); }

/** A same-boot OS observation, never an invented original-owner terminal.
 * Fence old starts before testing visibility. A real empty VPN extension supplies
 * the positive control for appManager; all whole-ability stops must settle first.
 */
export class OwnerExitRecovery {
  private static async processes(): Promise<appManager.ProcessInformation[]> {
    const rows = await deadline(appManager.getRunningProcessInformation(), 1800, '无法读取本应用进程');
    if (!rows.some((row: appManager.ProcessInformation) => row.pid === process.pid && row.uid === process.uid &&
      row.bundleNames.indexOf(BUNDLE_NAME) >= 0)) throw new Error('系统进程清单不完整，未恢复连接');
    return rows;
  }
  private static async absent(): Promise<void> {
    const nets = await deadline(connection.getAllNets(), 1800, '无法读取系统 VPN 状态');
    for (let i = 0; i < nets.length; i++) {
      const caps = await deadline(connection.getNetCapabilities(nets[i]), 1000, '无法核对系统 VPN 状态');
      if (caps.bearerTypes.indexOf(connection.NetBearType.BEARER_VPN) >= 0) throw new Error('系统 VPN 仍在运行，未替换连接');
    }
  }
  private static async onlyUi(knownEmptyPid: number = -1): Promise<void> {
    const rows = await OwnerExitRecovery.processes();
    const others = rows.filter((row: appManager.ProcessInformation) => row.pid !== process.pid);
    if (others.length > 0 && !(knownEmptyPid > 0 && others.length === 1 &&
      others[0].pid === knownEmptyPid && others[0].uid === process.uid &&
      others[0].processName === `${BUNDLE_NAME}:vpn` && others[0].bundleNames.indexOf(BUNDLE_NAME) >= 0)) {
      throw new Error('穿山甲后台进程仍在运行，请先尝试断开');
    }
    await OwnerExitRecovery.absent();
  }
  static async recover(context: common.UIAbilityContext, operations: PlatformOperations,
    knownEmptyPid: number = -1): Promise<void> {
    if (operations.inFlight() > 0) throw new Error('上一次系统操作还未结束，请稍后重试');
    operations.requireSettled(context);
    const ownerRaw = StatusStore.readStrictText(context, 'dataplane-status.json');
    const owner = StatusStore.readOwnerStatus(context);
    const before = StatusStore.readStrictText(context, CONTROL_FILE);
    const old = JSON.parse(before || '{}') as Record<string, Object>;
    const boot = systemBootId();
    if (old['schema'] !== 2 || old['generation'] !== owner.generation || owner.generation.length === 0 ||
      boot.length === 0 || old['bootId'] !== boot || old['kind'] === 'maintenance' ||
      old['inheritedUnresolved'] !== false || old['platformPending'] !== false ||
      typeof old['operationId'] !== 'string' || (old['operationId'] as string).length === 0 ||
      ['pending', 'confirmed', 'unconfirmed'].indexOf(old['state'] as string) < 0 ||
      ['start', 'stop', 'cancel', 'observe'].indexOf(old['kind'] as string) < 0) {
      throw new Error('仍有无法核实的旧系统操作，已保留现场');
    }
    await OwnerExitRecovery.onlyUi(knownEmptyPid);
    operations.requireSettled(context);
    const id = util.generateRandomUUID();
    const fence: Record<string, Object> = { 'schema': 2, 'bootId': boot, 'operationId': id,
      'controllerInstance': operations.instance, 'kind': 'cancel', 'state': 'pending',
      'generation': owner.generation, 'intentId': owner.generation, 'requestedAt': Date.now(),
      'at': Date.now(), 'platformPending': false, 'inheritedUnresolved': false, 'recoveryId': id };
    const expected = JSON.stringify(fence);
    if (StatusStore.readStrictText(context, 'dataplane-status.json') !== ownerRaw ||
      !StatusStore.compareText(context, CONTROL_FILE, before, expected)) throw new Error('连接已变化，请重新检查');
    const unchanged = (): void => {
      if (StatusStore.readStrictText(context, CONTROL_FILE) !== expected ||
        StatusStore.readStrictText(context, 'dataplane-status.json') !== ownerRaw || systemBootId() !== boot) {
        throw new Error('恢复期间连接已变化，未覆盖新状态');
      }
    };
    const want = createVpnAbilityWant();
    want.parameters = { command: 'diagnose-process-visibility', recoveryNonce: id };
    let cleanupNeeded = true;
    let failed = false;
    const cleanup = async (): Promise<void> => {
      // A later user operation owns its own cleanup; never stop its new VPN.
      unchanged();
      operations.requireSettled(context);
      if (!cleanupNeeded) return;
      cleanupNeeded = false;
      await operations.run(context, 'system-stop', owner.generation,
        () => vpnExtension.stopVpnExtensionAbility(createVpnAbilityWant()), 3000);
    };
    try {
    await operations.run(context, 'diagnostic', owner.generation,
      () => vpnExtension.startVpnExtensionAbility(want), 3000, (): void => {
        if (failed) cleanup().catch(() => {});
      });
    let ack: Record<string, Object> = {};
    for (let i = 0; i < 20; i++) {
      unchanged();
      try { ack = JSON.parse(StatusStore.readStrictText(context, ACK_FILE) || '{}') as Record<string, Object>; }
      catch (_error) { ack = {}; }
      if (ack['nonce'] === id) break;
      await pause(100);
    }
    if (ack['nonce'] !== id || ack['empty'] !== true || typeof ack['pid'] !== 'number' || ack['pid'] === process.pid) {
      throw new Error('未取得空闲 VPN 进程的核验结果，已保留现场');
    }
    const visible = await OwnerExitRecovery.processes();
    if (!visible.some((row: appManager.ProcessInformation) => row.pid === ack['pid'] && row.uid === process.uid &&
      row.bundleNames.indexOf(BUNDLE_NAME) >= 0)) throw new Error('系统接口未能识别 VPN 进程，未解除连接保护');
    unchanged();
    await OwnerExitRecovery.absent();
    await cleanup();
    const settled = operations.requireSettled(context);
    let disappeared = false;
    for (let i = 0; i < 20; i++) {
      unchanged();
      try { await OwnerExitRecovery.onlyUi(); disappeared = true; break; } catch (_error) {}
      await pause(150);
    }
    if (!disappeared) throw new Error('系统仍在结束 VPN 进程，请稍后重新检查');
    for (let i = 0; i < 2; i++) {
      await OwnerExitRecovery.onlyUi();
      unchanged();
      if (operations.requireSettled(context) !== settled) throw new Error('系统操作记录已变化，请重新检查');
      if (i === 0) await pause(200);
    }
    const observation: Record<string, Object> = { 'kind': 'system-owner-disappearance', 'writer': 'ui-system-observer',
      'id': id, 'bootId': boot, 'generation': owner.generation, 'ownerInstance': owner.ownerInstance,
      'ownerAt': owner.at, 'at': Date.now(), 'bearer': 'absent', 'positiveControlPid': ack['pid'],
      'processQuery': 'own-app-all-processes', 'samples': 2, 'platformSettled': true };
    StatusStore.writeText(context, 'system-observation.json', JSON.stringify(observation));
    unchanged();
    fence['state'] = 'confirmed'; fence['at'] = Date.now();
    if (!StatusStore.compareText(context, CONTROL_FILE, expected, JSON.stringify(fence))) {
      throw new Error('连接意图已变化，未解除保护');
    }
    } catch (error) {
      failed = true;
      try { await cleanup(); } catch (_cleanupError) {}
      throw error as Error;
    }
  }
}
