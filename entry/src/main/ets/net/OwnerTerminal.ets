import { DataplaneStatus } from './DataplaneStatus';

export const OWNER_TERMINAL_FILE: string = 'owner-terminal.json';
export const CONTROL_FILE: string = 'connection-control.json';
export const STOP_UNCONFIRMED: string = 'STOP_UNCONFIRMED';

// Written exclusively by the VPN owner after actual native and system cleanup.
export function terminalProven(raw: string, generation: string, notBefore: number, now: number = Date.now(), ownerInstance: string = ''): boolean {
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    return (ownerInstance.length === 0 || r['ownerInstance'] === ownerInstance) && r['scope'] !== 'replacement-empty' && generation.length > 0 && r['generation'] === generation && r['writer'] === 'vpn-owner' &&
      r['resourcesReleased'] === true && typeof r['at'] === 'number' && r['at'] >= notBefore && r['at'] <= now &&
      r['xrayRunning'] === false && r['tunRunning'] === false && r['xrayStarting'] === false &&
      r['xrayOwnerSeq'] === 0 && r['xrayStopPending'] === false && r['protectPending'] === 0 &&
      r['vpnCreatePending'] === 0 && r['vpnDestroyed'] === true && r['poisoned'] === false;
  } catch (_error) { return false; }
}

// Display projection only. Never written back to dataplane-status.json and
// deliberately preserves all last observed native/resource fields.
export function projectControl(status: DataplaneStatus, raw: string, proof: string, systemRaw: string = ''): DataplaneStatus {
  try {
    const observed = JSON.parse(systemRaw) as Record<string, Object>;
    const control = JSON.parse(raw || '{}') as Record<string, Object>;
    if (observed['kind'] === 'system-bearer-absence' && observed['writer'] === 'ui-system-observer' &&
      observed['generation'] === status.generation && observed['ownerInstance'] === status.ownerInstance &&
      observed['ownerAt'] === status.at && observed['bearer'] === 'absent') {
      status.phase = STOP_UNCONFIRMED; status.honestLabel = '需要恢复连接';
      status.connectionHealth = ''; status.canaryOk = false;
    }
    if (observed['kind'] === 'system-owner-disappearance' && observed['writer'] === 'ui-system-observer' &&
      control['kind'] === 'cancel' && control['state'] === 'confirmed' && control['platformPending'] === false &&
      typeof control['recoveryId'] === 'string' && (control['recoveryId'] as string).length > 0 &&
      observed['id'] === control['recoveryId'] && observed['bootId'] === control['bootId'] &&
      observed['generation'] === status.generation && control['generation'] === status.generation &&
      observed['ownerInstance'] === status.ownerInstance && observed['ownerAt'] === status.at &&
      observed['bearer'] === 'absent' && observed['samples'] === 2 && observed['platformSettled'] === true &&
      typeof observed['positiveControlPid'] === 'number' && observed['positiveControlPid'] > 0) {
      status.phase = 'STOPPED'; status.desiredRunning = false; status.vpnCreated = false; status.tunFdValid = false;
      status.xrayRunning = false; status.forwarderOk = false; status.cleanupPending = false; status.nativePoisoned = false;
      status.connectionHealth = ''; status.canaryOk = false; status.operationState = 'owner-exit-confirmed';
      status.lastError = ''; status.honestLabel = '可以重新连接';
      return status;
    }
    const previousBoot = typeof control['bootId'] === 'string' ? control['bootId'] as string : status.bootId;
    if (observed['writer'] === 'ui-system-observer' && observed['kind'] === 'system-reboot-release' &&
      observed['generation'] === status.generation && typeof observed['oldBootId'] === 'string' &&
      previousBoot.length > 0 && observed['oldBootId'] === previousBoot &&
      typeof observed['newBootId'] === 'string' && (observed['newBootId'] as string).length > 0 &&
      observed['newBootId'] !== previousBoot && observed['bearer'] === 'absent') {
      status.phase = 'STOPPED'; status.desiredRunning = false; status.vpnCreated = false; status.tunFdValid = false;
      status.xrayRunning = false; status.forwarderOk = false; status.cleanupPending = false; status.nativePoisoned = false;
      status.connectionHealth = ''; status.canaryOk = false; status.operationState = 'reboot-confirmed';
      status.honestLabel = '已核实系统重启后断开';
      return status;
    }
    if (observed['generation'] === status.generation && observed['writer'] === 'ui-system-observer' &&
      observed['ownerResponsive'] === false && typeof observed['at'] === 'number' && observed['at'] >= status.at) {
      status.phase = STOP_UNCONFIRMED;
      status.honestLabel = '需要恢复连接';
      status.connectionHealth = ''; status.canaryOk = false;
    }
  } catch (_error) {}
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    if (r['kind'] === 'maintenance' && r['state'] === 'pending') {
      status.phase = STOP_UNCONFIRMED; status.operationKind = 'maintenance'; status.operationState = 'unconfirmed';
      status.honestLabel = '数据清理尚未完成'; status.lastError = '请在设置页再次执行原清理操作，不会自动扩大清理范围。'; return status;
    }
    const noOwnerResources = !status.desiredRunning && !status.vpnCreated && !status.xrayRunning && !status.forwarderOk;
    if (r['kind'] === 'start' && (r['state'] === 'pending' || r['state'] === 'unconfirmed') && noOwnerResources &&
      r['generation'] !== status.generation) {
      status.phase = r['state'] === 'pending' ? 'STARTING' : STOP_UNCONFIRMED;
      status.operationState = r['state'] as string; status.operationKind = 'start';
      status.connectionHealth = r['state'] === 'pending' ? 'connecting' : ''; return status;
    }
    if ((r['kind'] !== 'stop' && r['kind'] !== 'observe') || typeof r['requestedAt'] !== 'number') return status;
    if (r['generation'] !== status.generation && (!noOwnerResources || r['state'] === 'confirmed')) return status;
    status.operationState = typeof r['state'] === 'string' ? r['state'] as string : '';
    status.operationKind = r['kind'] as string; status.operationAt = r['requestedAt'] as number;
    if (r['kind'] === 'observe' && typeof r['at'] === 'number' && status.at > r['at']) return status;
    const floor = typeof r['proofNotBefore'] === 'number' ? r['proofNotBefore'] as number : r['requestedAt'] as number;
    if (r['state'] === 'confirmed' && status.phase === 'STOPPED' && terminalProven(proof, status.generation, floor, Date.now(), status.ownerInstance)) return status;
    status.phase = STOP_UNCONFIRMED;
    status.honestLabel = r['state'] === 'pending' ? '正在断开' : '断开需要系统处理';
    status.lastError = '旧连接还在处理。请回首页点“恢复连接”。';
    status.connectionHealth = '';
    status.canaryOk = false;
  } catch (_error) {}
  return status;
}

// This fence is consumed by the actual VPN lifecycle before accepting a late
// UI start Want, and by its async guards. Legacy diagnostic commands do not
// create a UI ticket, so their existing no-start handlers remain independent.
export function controlAllowsStart(raw: string, generation: string, intentId: string): boolean {
  if (intentId.length === 0) return raw.length === 0; // legacy entry only when no durable UI intent exists
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    return r['kind'] === 'start' && r['intentId'] === intentId && r['generation'] === generation &&
      (r['state'] === 'pending' || r['state'] === 'confirmed' || r['state'] === undefined);
  } catch (_error) { return false; }
}

// Survives UI process recreation. An unresolved system mutation may still be
// delivered later, so a fresh UI process cannot treat its empty in-memory
// counters as evidence that it is safe to start a replacement owner.
export function controlBlocksStart(raw: string): boolean {
  if (raw.length === 0) return false;
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    return ['start','stop','cancel','observe','maintenance'].indexOf(r['kind'] as string) < 0 ||
      ['pending','unconfirmed','confirmed'].indexOf(r['state'] as string) < 0 ||
      r['state'] === 'pending' || r['state'] === 'unconfirmed';
  } catch (_error) { return true; }
}
