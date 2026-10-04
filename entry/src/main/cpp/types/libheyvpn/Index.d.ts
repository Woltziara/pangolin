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
export const startXray: (configJson: string, workDir: string) => Promise<NativeResult>;
export const stopXray: () => NativeResult;
export const stopXrayOwned: (ownerSeq: number) => NativeResult;
export const getStats: () => RuntimeStats;
export const startHevTun: (tunFd: number, configYaml: string) => NativeResult;
export const stopHevTun: () => NativeResult;
export const atomicReplaceFile: (tmpPath: string, destPath: string) => NativeResult;
export const abortPoisonedNative: () => void;
export const setProtectCallback: (cb: (fd: number, token: number) => void) => number;
export const clearProtectCallback: () => number;
export const claimProtectFd: (fd: number, token: number) => number;
export const ackProtectFd: (fd: number, rc: number, token: number) => number;
