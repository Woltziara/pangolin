import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// HarmonyOS 7 起应用沙箱拒绝 file_api 读取 /proc/net/dev（EACCES，file_api ret -13）。
// 第一次吃到权限错误后在进程生命周期内闩锁跳过，避免监督循环每 15 秒刷两条错误日志；
// 计数由调用方回落到原生 getNativeStats（napi 侧读取不受 file_api 沙箱限制）。
let procNetDenied: boolean = false;

function isPermissionDenied(error: Object): boolean {
  const code = (error as BusinessError).code;
  // 13900001 = EPERM, 13900012 = EACCES（Permission denied）
  return code === 13900001 || code === 13900012;
}

export class TunCounters {
  found: boolean = false;
  rxBytes: number = 0;
  rxPackets: number = 0;
  txBytes: number = 0;
  txPackets: number = 0;
  txDropped: number = 0;
}

export function readVpnTunCounters(): TunCounters {
  const counters = new TunCounters();
  if (procNetDenied) {
    return counters;
  }
  try {
    const raw = fs.readTextSync('/proc/net/dev');
    const lines = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const idx = line.indexOf('vpn-tun');
      if (idx < 0) {
        continue;
      }
      const body = line.substring(line.indexOf(':') + 1).trim();
      const parts = splitWs(body);
      if (parts.length >= 12) {
        counters.found = true;
        counters.rxBytes = Number(parts[0]);
        counters.rxPackets = Number(parts[1]);
        counters.txBytes = Number(parts[8]);
        counters.txPackets = Number(parts[9]);
        counters.txDropped = Number(parts[11]);
      }
      break;
    }
  } catch (error) {
    counters.found = false;
    if (!procNetDenied && isPermissionDenied(error)) {
      procNetDenied = true;
      hilog.info(0x7D00, 'TongDao/ProcNet', '/proc/net/dev 被系统拒绝（HarmonyOS 7 沙箱），本进程改用原生计数，不再重试');
    }
  }
  return counters;
}

function splitWs(value: string): string[] {
  const parts: string[] = [];
  let current = '';
  for (let i = 0; i < value.length; i++) {
    const ch = value.charAt(i);
    if (ch === ' ' || ch === '\t') {
      if (current.length > 0) {
        parts.push(current);
        current = '';
      }
    } else {
      current += ch;
    }
  }
  if (current.length > 0) {
    parts.push(current);
  }
  return parts;
}
