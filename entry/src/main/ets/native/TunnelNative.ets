import heyNative from 'libheyvpn.so';

export interface NativeResult {
  ok: boolean;
  message: string;
  poisoned: boolean;
  ownerSeq?: number;
}

export interface SocksSessionNative {
  ok: boolean;
  message: string;
  port: number;
  user: string;
  pass: string;
}

export interface RuntimeStats {
  uploadBytes: number;
  downloadBytes: number;
  xrayRunning: boolean;
  xrayStarting: boolean;
  tunRunning: boolean;
  lastMessage: string;
  poisoned: boolean;
  tunFound: boolean;
  tunRxBytes: number;
  tunTxBytes: number;
  physicalIface: string;
  protectQueued: number;
  protectAcked: number;
  protectTimeout: number;
  protectVisible: number;
  protectMeasured: number;
  protectTotalUs: number;
  protectMaxUs: number;
  protectTcp4: number;
  protectTcp6: number;
  protectUdp: number;
  protectTcp4At: number;
  protectTcp6At: number;
  hevDiagnostics: string;
}

interface NativeBridge {
  createSocksSession(): SocksSessionNative;
  startXray(configJson: string, workDir: string): NativeResult | Promise<NativeResult>;
  stopXray(): NativeResult;
  stopXrayOwned(ownerSeq: number): NativeResult;
  getStats(): RuntimeStats;
  startTun2Socks(tunFd: number, socksHost: string, socksPort: number, mtu: number): NativeResult;
  startHevTun(tunFd: number, configYaml: string): NativeResult;
  stopTun2Socks(): NativeResult;
  atomicReplaceFile(tmpPath: string, destPath: string): NativeResult;
  abortPoisonedNative(): void;
  queryStats(server: string): NativeResult;
  setProtectCallback(cb: (fd: number, token: number) => void): number;
  clearProtectCallback(): number;
  takeProtectFd(): number;
  claimProtectFd(fd: number, token: number): number;
  ackProtectFd(fd: number, rc: number, token: number): number;
}

const bridge = heyNative as NativeBridge;

export interface AppFlowRequest {
  requestId: number;
  protocol: number;
  family: number;
  sourceAddress: string;
  sourcePort: number;
  destinationAddress: string;
  destinationPort: number;
}
export function setAppRouteCallback(cb: (flow: AppFlowRequest) => void): number {
  return heyNative.setAppRouteCallback(cb);
}
export function clearAppRouteCallback(): number { return heyNative.clearAppRouteCallback(); }
export function ackAppRoute(requestId: number, status: number, port: number): number {
  return heyNative.ackAppRoute(requestId, status, port);
}

export function createNativeSocksSession(): SocksSessionNative {
  return bridge.createSocksSession();
}

export async function startNativeXray(configJson: string, workDir: string): Promise<NativeResult> {
  return await bridge.startXray(configJson, workDir);
}

export function stopNativeXray(): NativeResult {
  return bridge.stopXray();
}

export function stopNativeXrayOwned(ownerSeq: number): NativeResult {
  if (ownerSeq <= 0) {
    const skipped: NativeResult = { ok: true, message: 'xray owner mismatch; not stopped', poisoned: false, ownerSeq };
    return skipped;
  }
  return bridge.stopXrayOwned(ownerSeq);
}

export function getNativeStats(): RuntimeStats {
  return bridge.getStats();
}

export function startNativeTun2Socks(tunFd: number, socksHost: string, socksPort: number, mtu: number): NativeResult {
  return bridge.startTun2Socks(tunFd, socksHost, socksPort, mtu);
}

export function startNativeHevTun(tunFd: number, configYaml: string): NativeResult {
  return bridge.startHevTun(tunFd, configYaml);
}

export function stopNativeTun2Socks(): NativeResult {
  return bridge.stopTun2Socks();
}

export function queryNativeStats(server: string): NativeResult {
  return bridge.queryStats(server);
}

export function atomicReplaceFile(tmpPath: string, destPath: string): NativeResult {
  return bridge.atomicReplaceFile(tmpPath, destPath);
}

export function abortPoisonedNative(): void {
  bridge.abortPoisonedNative();
}

export function setProtectCallback(cb: (fd: number, token: number) => void): number {
  return bridge.setProtectCallback(cb);
}

export function clearProtectCallback(): number {
  return bridge.clearProtectCallback();
}

export function takeProtectFd(): number {
  return bridge.takeProtectFd();
}

export function claimProtectFd(fd: number, token: number): number {
  return bridge.claimProtectFd(fd, token);
}

export function ackProtectFd(fd: number, rc: number, token: number): number {
  return bridge.ackProtectFd(fd, rc, token);
}
