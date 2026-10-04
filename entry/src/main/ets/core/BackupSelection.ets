// 备用候选必须有时效内的延迟证据，不能把列表里另一项宣传成“实时第二快”。
// 几毫秒差异不切换；没有足够证据就不写入备用 payload。

export const LATENCY_EVIDENCE_MAX_AGE_MS: number = 600000;
export const MIN_FAILOVER_DELTA_MS: number = 80;

export class BackupCandidate {
  name: string = '';
  region: string = '';
  server: string = '';
  port: number = 0;
  protocol: string = '';
  outboundJson: string = '';
  latencyMs: number = -1;
  latencyAt: number = 0;
}

export function hasFreshLatency(latencyMs: number, latencyAt: number, now: number): boolean {
  if (latencyMs < 0) {
    return false;
  }
  if (latencyAt <= 0) {
    return false;
  }
  return now - latencyAt <= LATENCY_EVIDENCE_MAX_AGE_MS && now + 5000 >= latencyAt;
}

export function pickBackupWithEvidence(pool: BackupCandidate[], currentName: string, now: number): BackupCandidate {
  const empty = new BackupCandidate();
  let best = empty;
  for (let i = 0; i < pool.length; i++) {
    const node = pool[i];
    if (node.name.length === 0 || node.name === currentName || node.outboundJson.length < 20) {
      continue;
    }
    if (!hasFreshLatency(node.latencyMs, node.latencyAt, now)) {
      continue;
    }
    if (best.name.length === 0 || node.latencyMs < best.latencyMs) {
      best = node;
    }
  }
  return best;
}
