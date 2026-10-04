// 探测结果绑定实际 outbound，而不是用网站名推断线路。
// 单个目标失败只记观察，不能当成整条线路坏，更不能换另一条健康线路。

export const OUTBOUND_DIRECT: string = 'direct';
export const OUTBOUND_GENERAL: string = 'proxy-yt';
export const OUTBOUND_PROXY: string = 'proxy';
export const LINE_HEALTH_HOST: string = 'cp.cloudflare.com';
export const LINE_HEALTH_HOST_B: string = 'www.gstatic.com';

export function probeOutboundTag(probe: string, routingProfile: string, channelMode: string): string {
  if (probe === 'baidu' || probe === 'direct') {
    return OUTBOUND_DIRECT;
  }
  const roleRouting = routingProfile === 'chatgpt-general' && channelMode === 'dual';
  if (probe === 'google' || probe === 'youtube') {
    return roleRouting ? OUTBOUND_GENERAL : OUTBOUND_PROXY;
  }
  if (probe === 'line-health' || probe === 'line-health-b' || probe === 'chatgpt-line') {
    return OUTBOUND_PROXY;
  }
  return OUTBOUND_PROXY;
}

export class LegObservation {
  outboundTag: string = '';
  failStreak: number = 0;
  failedDests: string[] = [];
}

export function emptyLeg(tag: string): LegObservation {
  const leg = new LegObservation();
  leg.outboundTag = tag;
  return leg;
}

export function recordProbeResult(leg: LegObservation, dest: string, ok: boolean): LegObservation {
  const next = new LegObservation();
  next.outboundTag = leg.outboundTag;
  if (ok) {
    next.failStreak = 0;
    next.failedDests = [];
    return next;
  }
  next.failStreak = leg.failStreak + 1;
  next.failedDests = leg.failedDests.slice();
  if (dest.length > 0 && next.failedDests.indexOf(dest) < 0) {
    next.failedDests.push(dest);
  }
  return next;
}

export function legShouldPromote(leg: LegObservation, failLimit: number): boolean {
  if (failLimit < 1) {
    return false;
  }
  return leg.failStreak >= failLimit && leg.failedDests.length >= 2;
}

// 试切只验收本次实际切换的腿。general/proxy-yt 看 google+youtube，proxy/us 看两条线路健康目标。
// 未切换腿的成功不能证明已切换腿；一条网站失败也不是整腿证据。
export function trialLegsProven(trialYt: boolean, trialUs: boolean, googleOk: boolean, youtubeOk: boolean,
  lineHealthOk: boolean, lineHealthBOk: boolean): boolean {
  if (!trialYt && !trialUs) {
    return false;
  }
  if (trialYt && (!googleOk || !youtubeOk)) {
    return false;
  }
  if (trialUs && (!lineHealthOk || !lineHealthBOk)) {
    return false;
  }
  return true;
}

export function routingProfileOf(payload: string): string {
  try {
    const rec = JSON.parse(payload) as Record<string, Object>;
    const profile = rec['routingProfile'];
    return typeof profile === 'string' ? profile : '';
  } catch (error) {
    return '';
  }
}

export function channelModeOf(payload: string): string {
  try {
    const rec = JSON.parse(payload) as Record<string, Object>;
    const mode = rec['channelMode'];
    return mode === 'dual' ? 'dual' : 'single';
  } catch (error) {
    return 'single';
  }
}
