import { currentReceipt, receiptSucceeded, isUiProbeSource } from './ProbeResult';
import { DataplaneStatus } from './DataplaneStatus';

export const LAYERS_FILE: string = 'connection-layers.json';
export const BUSINESS_FILE: string = 'business-observation.json';
const FRESH_MS: number = 75000;

/** Each fact keeps its own path, time and session. No successful layer erases
 * another layer's failure. Business reports never authorize VPN mutations. */
export class LayerEvidence {
  private identity: string = '';
  private lastReceiptAt: number = 0;
  private failedReceipts: number = 0;
  private failureSince: number = 0;
  private priorIngress: number = 0;
  private priorEgress: number = 0;
  private priorDropped: number = 0;
  private ingressDuringFailure: boolean = false;
  private socksAt: number = 0;
  private socksOk: boolean = false;
  private bearer: string = 'unknown';
  private bearerAt: number = 0;

  reset(generation: string, revision: number): void {
    this.identity = `${generation}:${revision}:0`;
    this.lastReceiptAt = 0; this.failedReceipts = 0; this.failureSince = 0;
    this.ingressDuringFailure = false; this.socksAt = 0; this.socksOk = false;
    this.priorIngress = 0; this.priorEgress = 0; this.priorDropped = 0;
  }
  noteSocks(ok: boolean, now: number): void { this.socksAt = now; this.socksOk = ok; }
  noteBearer(kind: string, now: number): void {
    this.bearer = kind === 'available' ? 'available' : kind === 'lost' || kind === 'unavailable' ? 'unavailable' : 'unknown';
    this.bearerAt = now;
  }
  sample(status: DataplaneStatus, native: Record<string, Object>, receiptRaw: string, expectedBundle: string,
    now: number, businessRaw: string = ''): Record<string, Object> {
    if (`${status.generation}:${status.sessionRevision}:${status.networkEpoch}` !== this.identity) {
      this.reset(status.generation, status.sessionRevision); this.identity = `${status.generation}:${status.sessionRevision}:${status.networkEpoch}`;
      this.priorIngress = status.tunTxBytes; this.priorEgress = status.downloadBytes; this.priorDropped = status.tunDropped;
    }
    let through = 'unknown';
    try {
      const r = JSON.parse(receiptRaw) as Record<string, Object>;
      const at: number = typeof r['at'] === 'number' ? r['at'] as number : 0;
      if ((r['schema'] === 2 && currentReceipt(r, status, now) || status.ownerInstance.length === 0 && status.generation.length > 0 && status.probeIssuedAt > 0 && r['generation'] === status.generation &&
        r['revision'] === status.sessionRevision && r['rid'] === status.evidenceRid &&
        r['bundle'] === expectedBundle && isUiProbeSource(r['source']) &&
        typeof at === 'number' && at >= status.probeIssuedAt && at <= now && now - at <= FRESH_MS &&
        typeof r['googleHttp'] === 'number' && typeof r['directHttp'] === 'number' && typeof r['dnsOk'] === 'boolean')) {
        through = r['schema'] === 2 ? (receiptSucceeded(r, status.routeMode, status.channelMode === 'dual') ? 'success' : 'failure') : r['googleHttp'] === 204 && (r['directHttp'] as number) >= 200 &&
          (r['directHttp'] as number) < 400 && r['dnsOk'] === true ? 'success' : 'failure';
        if (at > this.lastReceiptAt) {
          if (through === 'failure') {
            if (this.failedReceipts === 0 || at - this.lastReceiptAt > FRESH_MS) {
              this.failureSince = at; this.failedReceipts = 0; this.ingressDuringFailure = false;
            }
            this.failedReceipts += 1;
          } else { this.failedReceipts = 0; this.failureSince = 0; this.ingressDuringFailure = false; }
          this.lastReceiptAt = at;
        }
      }
    } catch (_error) {}
    const egressAdvanced = status.downloadBytes > this.priorEgress;
    if (egressAdvanced) { this.ingressDuringFailure = false; this.failureSince = now; }
    if (!egressAdvanced && through === 'failure' &&
      (status.tunTxBytes > this.priorIngress || status.tunDropped > this.priorDropped)) this.ingressDuringFailure = true;
    const stalled = through === 'failure' && this.failedReceipts >= 2 && this.failureSince > 0 &&
      now - this.failureSince >= 15000 && this.ingressDuringFailure && !egressAdvanced;
    this.priorIngress = status.tunTxBytes; this.priorEgress = status.downloadBytes; this.priorDropped = status.tunDropped;
    const socks = this.socksAt > 0 && now >= this.socksAt && now - this.socksAt <= FRESH_MS ?
      (this.socksOk ? 'success' : 'failure') : 'unknown';
    const dead = native['xrayRunning'] === false || native['tunRunning'] === false;
    const nativeState = native['poisoned'] === true ? 'quarantined' : dead ? 'not-running' :
      native['xrayRunning'] === true && native['tunRunning'] === true ? 'running' : 'unknown';
    const eligible = status.desiredRunning && status.generation.length > 0 && status.sessionRevision >= 1 &&
      ['FORWARDER_RUNNING', 'CANARY_OK', 'UNPROVEN', 'DEGRADED_UNPROVEN', 'DEGRADED', 'ERROR'].indexOf(status.phase) >= 0;
    const r: Record<string, Object> = {};
    r['networkEpoch'] = status.networkEpoch; r['ownerInstance'] = status.ownerInstance;
    r['generation'] = status.generation; r['revision'] = status.sessionRevision; r['at'] = now;
    r['systemBearer'] = this.bearer; r['systemBearerObservedAt'] = this.bearerAt;
    r['vpnOwnerCreated'] = status.vpnCreated; r['native'] = nativeState;
    r['tunProgress'] = stalled ? 'stalled-with-input' : egressAdvanced ? 'observed' : 'not-proven';
    r['tunInputBytes'] = status.tunTxBytes; r['hevReturnBytes'] = status.downloadBytes; r['tunDrops'] = status.tunDropped;
    r['bypassSocks'] = socks; r['bypassObservedAt'] = this.socksAt;
    r['throughTun'] = through; r['throughObservedAt'] = this.lastReceiptAt;
    r['throughFailureReceipts'] = this.failedReceipts;
    r['targetBusiness'] = businessObservation(businessRaw, status.generation, status.sessionRevision, now);
    r['reason'] = dead ? 'native-not-running' : stalled && socks === 'success' ? 'tun-stalled' : 'insufficient-data-plane-evidence';
    r['rebuildAllowed'] = eligible && native['poisoned'] === false && native['xrayStarting'] === false &&
      native['xrayStopPending'] === false && (dead || stalled && socks === 'success');
    return r;
  }
}
export function rebuildEvidence(raw: string, status: DataplaneStatus, now: number): boolean {
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    return status.desiredRunning && (status.ownerInstance.length === 0 || r['ownerInstance'] === status.ownerInstance && r['networkEpoch'] === status.networkEpoch) && r['generation'] === status.generation && r['revision'] === status.sessionRevision &&
      typeof r['at'] === 'number' && now >= r['at'] && now - (r['at'] as number) <= 25000 &&
      r['rebuildAllowed'] === true && (r['reason'] === 'native-not-running' || r['reason'] === 'tun-stalled');
  } catch (_error) { return false; }
}
export function businessObservation(raw: string, generation: string, revision: number, now: number): string {
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    if (r['generation'] === generation && r['revision'] === revision && r['source'] === 'explicit-user-action' &&
      r['scope'] === 'chatgpt-application' && typeof r['at'] === 'number' && r['at'] <= now && now - (r['at'] as number) <= 86400000 &&
      (r['outcome'] === 'user-reported-failure' || r['outcome'] === 'user-reported-success')) return r['outcome'] as string;
  } catch (_error) {}
  return 'not-observed';
}
/** Disk input is filtered again on export; unknown keys and arbitrary text are
 * never trusted merely because a private file was expected to contain counts. */
export function safeLayerRecord(raw: string): Record<string, Object> {
  const out: Record<string, Object> = {};
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    const strings = ['systemBearer', 'native', 'tunProgress', 'bypassSocks', 'throughTun', 'targetBusiness', 'reason'];
    const values = ['unknown', 'available', 'unavailable', 'quarantined', 'not-running', 'running', 'stalled-with-input',
      'observed', 'not-proven', 'success', 'failure', 'not-observed', 'user-reported-failure', 'user-reported-success',
      'native-not-running', 'tun-stalled', 'insufficient-data-plane-evidence'];
    strings.forEach((k: string) => { if (typeof r[k] === 'string' && values.indexOf(r[k] as string) >= 0) out[k] = r[k]; });
    ['revision', 'at', 'systemBearerObservedAt', 'bypassObservedAt', 'throughObservedAt', 'throughFailureReceipts',
      'tunInputBytes', 'hevReturnBytes', 'tunDrops'].forEach((k: string) => {
      if (typeof r[k] === 'number' && Number.isFinite(r[k] as number) && (r[k] as number) >= 0) out[k] = r[k];
    });
    ['vpnOwnerCreated', 'rebuildAllowed'].forEach((k: string) => { if (typeof r[k] === 'boolean') out[k] = r[k]; });
    if (typeof r['generation'] === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(r['generation'] as string)) out['generation'] = r['generation'];
  } catch (_error) {}
  return out;
}
