import heyNative, { NativeResult, SocksSessionNative, RuntimeStats, AppFlowRequest } from 'libheyvpn.so';

// Keep the ABI shape in the native module declaration; this layer owns app naming
// and the owner-specific stop guard only.
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
