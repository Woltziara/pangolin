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

export interface NativePingResult {
  ok: boolean;
  delayMs: number;
  message: string;
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

export const createSocksSession: () => SocksSessionNative;
export interface AppFlowRequest {
  requestId: number;
  protocol: number;
  family: number;
  sourceAddress: string;
  sourcePort: number;
  destinationAddress: string;
  destinationPort: number;
}
export const setAppRouteCallback: (cb: (flow: AppFlowRequest) => void) => number;
export const clearAppRouteCallback: () => number;
export const ackAppRoute: (requestId: number, status: number, port: number) => number;
export const validateConfig: (configJson: string) => NativeResult;
export const setTunFd: (tunFd: number) => NativeResult;
export const startXray: (configJson: string, workDir: string) => Promise<NativeResult>;
export const stopXray: () => NativeResult;
export const stopXrayOwned: (ownerSeq: number) => NativeResult;
export const getStats: () => RuntimeStats;
// tun2socks 适配器（libheytun2socks.so）：TUN fd 流量 -> 本地 SOCKS 入站。
export const startTun2Socks: (tunFd: number, socksHost: string, socksPort: number, mtu: number) => NativeResult;
export const startHevTun: (tunFd: number, configYaml: string) => NativeResult;
export const stopTun2Socks: () => NativeResult;
export const atomicReplaceFile: (tmpPath: string, destPath: string) => NativeResult;
export const abortPoisonedNative: () => void;
export const setProtectCallback: (cb: (fd: number, token: number) => void) => number;
export const clearProtectCallback: () => number;
export const takeProtectFd: () => number;
export const claimProtectFd: (fd: number, token: number) => number;
export const ackProtectFd: (fd: number, rc: number, token: number) => number;
export const pingOutbound: (configJson: string, datDir: string, url: string, timeoutSeconds: number, proxy: string) => NativePingResult;
export const queryStats: (server: string) => NativeResult;
export const testXrayConfig: (configJson: string, workDir: string) => NativeResult;
export const xrayVersion: () => NativeResult;
export const countGeoData: (datDir: string, name: string, geoType: string) => NativeResult;
export const readGeoFiles: (configJson: string) => NativeResult;
export const getFreePorts: (count: number) => NativeResult;
export const convertShareLinksToXrayJson: (text: string) => NativeResult;
export const convertXrayJsonToShareLinks: (configJson: string) => NativeResult;
