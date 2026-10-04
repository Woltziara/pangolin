import heyNative, { NativeResult, SocksSessionNative, RuntimeStats, AppFlowRequest } from 'libheyvpn.so';
export { NativeResult, SocksSessionNative, RuntimeStats, AppFlowRequest };

export function setAppRouteCallback(cb: (flow: AppFlowRequest) => void): number {
  return heyNative.setAppRouteCallback(cb);
}
export function clearAppRouteCallback(): number { return heyNative.clearAppRouteCallback(); }
export function ackAppRoute(requestId: number, status: number, port: number): number {
  return heyNative.ackAppRoute(requestId, status, port);
}

export function createNativeSocksSession(): SocksSessionNative {
  return heyNative.createSocksSession();
}

export async function startNativeXray(configJson: string, workDir: string): Promise<NativeResult> {
  return await heyNative.startXray(configJson, workDir);
}

export function stopNativeXray(): NativeResult {
  return heyNative.stopXray();
}

export function stopNativeXrayOwned(ownerSeq: number): NativeResult {
  if (ownerSeq <= 0) {
    const skipped: NativeResult = { ok: true, message: 'xray owner mismatch; not stopped', poisoned: false, ownerSeq };
    return skipped;
  }
  return heyNative.stopXrayOwned(ownerSeq);
}

export function getNativeStats(): RuntimeStats {
  return heyNative.getStats();
}

export function startNativeHevTun(tunFd: number, configYaml: string): NativeResult {
  return heyNative.startHevTun(tunFd, configYaml);
}

export function stopNativeHevTun(): NativeResult {
  return heyNative.stopHevTun();
}

export function atomicReplaceFile(tmpPath: string, destPath: string): NativeResult {
  return heyNative.atomicReplaceFile(tmpPath, destPath);
}

export function abortPoisonedNative(): void {
  heyNative.abortPoisonedNative();
}

export function setProtectCallback(cb: (fd: number, token: number) => void): number {
  return heyNative.setProtectCallback(cb);
}

export function clearProtectCallback(): number {
  return heyNative.clearProtectCallback();
}

export function claimProtectFd(fd: number, token: number): number {
  return heyNative.claimProtectFd(fd, token);
}

export function ackProtectFd(fd: number, rc: number, token: number): number {
  return heyNative.ackProtectFd(fd, rc, token);
}

/** Uses the same per-file flock as atomic replacement; conflict is never overwritten. */
export function compareReplaceText(path: string, expected: string, value: string): NativeResult {
  return heyNative.compareReplaceText(path, expected, value);
}
export function monotonicMillis(): number { return heyNative.monotonicMillis(); }
export function systemBootId(): string { return heyNative.systemBootId(); }

export function acquireUserDataLease(path: string): number { return heyNative.acquireUserDataLease(path); }
export function releaseUserDataLease(token: number): boolean { return heyNative.releaseUserDataLease(token); }

export function configureErrorLog(directory: string): void { heyNative.configureErrorLog(directory); }
export function recordErrorLog(level: string, component: string, message: string, stack: string): void { heyNative.recordErrorLog(level, component, message, stack); }
