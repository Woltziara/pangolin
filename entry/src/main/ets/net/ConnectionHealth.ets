import { currentReceipt, receiptSucceeded, receiptAllChecksPassed, isUiProbeSource } from './ProbeResult';
import { DataplaneStatus } from './DataplaneStatus';

export const HEALTH_STATUS_MAX_AGE_MS: number = 25000;
export const HEALTH_SUCCESS_MAX_AGE_MS: number = 75000;
export const HEALTH_INITIAL_WAIT_MS: number = 30000;

// Connection lifecycle, not Internet reachability. A failed website check
// cannot negate a running local VPN session.
export function isConnectionEstablished(status: DataplaneStatus, now: number): boolean {
  return status.desiredRunning && !status.cleanupPending && status.vpnCreated && status.tunFdValid && status.xrayRunning &&
    status.forwarderOk && !status.nativePoisoned && status.at > 0 && now >= status.at &&
    now - status.at <= HEALTH_STATUS_MAX_AGE_MS && status.phase !== 'STOPPED' &&
    status.phase !== 'IDLE' && status.phase !== 'ERROR' && status.phase !== 'POISONED' &&
    status.phase !== 'RECONNECTING' && status.phase !== 'STOP_UNCONFIRMED';
}

// User-visible reachability is separate from the strict routing/access-log
// audit. This projection never changes phase, canaryOk, or routing evidence.
// Callers share this exact function; it is also used while reading status so
// a completed application probe need not wait for the VPN's next 15s tick.
export function updateConnectionHealth(status: DataplaneStatus, receiptRaw: string,
  expectedBundle: string, now: number): void {
  status.connectionHealth = '';
  if (status.healthGeneration !== status.generation || status.healthRevision !== status.sessionRevision ||
    (status.ownerInstance.length > 0 && (status.healthOwnerInstance !== status.ownerInstance ||
      status.healthNetworkEpoch !== status.networkEpoch || status.healthPolicyDigest !== status.payloadDigest))) {
    status.lastReachableAt = 0;
    status.healthCheckedAt = 0;
    status.healthLastOutcome = '';
  }
  if (!status.desiredRunning || status.phase === 'STOPPED' || status.phase === 'IDLE' ||
    status.phase === 'ERROR' || status.phase === 'POISONED' || status.phase === 'RECONNECTING' || status.phase === 'STOP_UNCONFIRMED') {
    return;
  }
  if (status.networkState === 'unavailable') { status.connectionHealth = 'network-unavailable'; return; }
  const live = status.vpnCreated && status.tunFdValid && status.xrayRunning &&
    status.forwarderOk && !status.nativePoisoned;
  if (!live) {
    const starting = status.phase === 'STARTING' || status.phase === 'VPN_CREATED' ||
      status.phase === 'CORE_RUNNING' || status.phase === 'PROBE_SNIFFING';
    status.connectionHealth = starting ? 'connecting' : 'offline';
    return;
  }
  if (status.at <= 0 || now < status.at || now - status.at > HEALTH_STATUS_MAX_AGE_MS) {
    status.connectionHealth = 'unverified';
    return;
  }

  try {
    const receipt = JSON.parse(receiptRaw) as Record<string, Object>;
    const at = receipt['at'];
    const google = receipt['googleHttp'];
    const direct = receipt['directHttp'];
    const dns = receipt['dnsOk'];
    const legacyMatches = status.ownerInstance.length === 0 && status.generation.length > 0 && status.sessionRevision >= 1 &&
      status.evidenceRid.length > 2 && status.probeIssuedAt > 0 &&
      receipt['generation'] === status.generation && receipt['revision'] === status.sessionRevision &&
      receipt['rid'] === status.evidenceRid && receipt['bundle'] === expectedBundle &&
      isUiProbeSource(receipt['source']);
    const matches = receipt['schema'] === 2 ? currentReceipt(receipt, status, now) && receipt['bundle'] === expectedBundle : legacyMatches;
    if (matches && typeof at === 'number' && (receipt['schema'] === 2 || at >= status.probeIssuedAt) &&
      at >= status.healthCheckedAt && at <= now && now - at <= HEALTH_SUCCESS_MAX_AGE_MS &&
      typeof google === 'number' && typeof direct === 'number' && typeof dns === 'boolean') {
      const ok = receipt['schema'] === 2 ? receiptSucceeded(receipt, status.routeMode, status.channelMode === 'dual') :
        google === 204 && direct >= 200 && direct < 400 && dns;
      status.healthCheckedAt = at;
      status.healthLastOutcome = ok ? (receipt['schema'] === 2 && !receiptAllChecksPassed(receipt, status.routeMode) ? 'partial' : 'success') : 'failure';
      status.healthOwnerInstance = status.ownerInstance; status.healthNetworkEpoch = status.networkEpoch;
      status.healthPolicyDigest = status.payloadDigest;
      status.healthGeneration = status.generation;
      status.healthRevision = status.sessionRevision;
      if (ok) { status.lastReachableAt = at; }
    }
  } catch (error) {
    // A missing/malformed receipt is unknown, never proof of a failed link.
  }

  const checkedAge = now - status.healthCheckedAt;
  if (status.healthLastOutcome === 'partial' && status.healthCheckedAt > 0 &&
    checkedAge >= 0 && checkedAge <= HEALTH_SUCCESS_MAX_AGE_MS) {
    status.connectionHealth = 'partial'; return;
  }
  if (status.healthLastOutcome === 'failure' && status.healthCheckedAt > 0 &&
    checkedAge >= 0 && checkedAge <= HEALTH_SUCCESS_MAX_AGE_MS) {
    status.connectionHealth = 'check-failed';
    return;
  }
  const successAge = now - status.lastReachableAt;
  if (status.lastReachableAt > 0 && successAge >= 0 && successAge <= HEALTH_SUCCESS_MAX_AGE_MS) {
    status.connectionHealth = 'reachable';
    return;
  }
  const pendingAge = now - status.probeIssuedAt;
  status.connectionHealth = status.probeIssuedAt > 0 &&
    pendingAge >= 0 && pendingAge < HEALTH_INITIAL_WAIT_MS ? 'checking' : 'unverified';
}
