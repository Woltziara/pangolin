import { DataplaneStatus } from './DataplaneStatus';
export function isUiProbeSource(source: Object): boolean {
  return source === 'entry-foreground' || source === 'entry-background';
}
export function probeIdentity(status: DataplaneStatus): string {
  return `${status.generation}:${status.ownerInstance}:${status.sessionRevision}:${status.networkEpoch}:${status.payloadDigest}`;
}
export function currentReceipt(r: Record<string, Object>, status: DataplaneStatus, now: number): boolean {
  return status.generation.length > 0 && status.ownerInstance.length > 0 &&
    typeof r['rid'] === 'string' && (r['rid'] as string).length > 0 &&
    typeof r['googleHttp'] === 'number' && typeof r['cloudflareHttp'] === 'number' &&
    typeof r['directHttp'] === 'number' && typeof r['dnsOk'] === 'boolean' && r['schema'] === 2 && r['generation'] === status.generation && r['revision'] === status.sessionRevision &&
    r['ownerInstance'] === status.ownerInstance && r['networkEpoch'] === status.networkEpoch &&
    r['policyDigest'] === status.payloadDigest && r['scope'] === 'pangolin-ui-path' &&
    isUiProbeSource(r['source']) && typeof r['at'] === 'number' && r['at'] <= now &&
    now - (r['at'] as number) <= 75000 && status.networkState !== 'unavailable';
}
export function receiptSucceeded(r: Record<string, Object>, route: string, dual: boolean): boolean {
  const direct = typeof r['directHttp'] === 'number' && (r['directHttp'] as number) >= 200 && (r['directHttp'] as number) < 400;
  const a = r['googleHttp'] === 204, b = r['cloudflareHttp'] === 204;
  // Raw UDP DNS failure is reported separately. HTTPS success already exercised that request's resolver.
  // In direct mode foreign access isn't required; no foreign request is scheduled by default.
  return direct && (route === 'direct' || (dual ? a && b : a || b));
}
/** A reachable HTTP path must not hide another scheduled test's failure. */
export function receiptAllChecksPassed(r: Record<string, Object>, route: string): boolean {
  return receiptSucceeded(r, route, false) && r['dnsOk'] === true &&
    (route === 'direct' || r['googleHttp'] === 204 && r['cloudflareHttp'] === 204);
}
function visibleProbe(status: DataplaneStatus, now: number): boolean {
  return status.desiredRunning && status.vpnCreated && status.tunFdValid && status.xrayRunning &&
    status.forwarderOk && !status.cleanupPending && !status.nativePoisoned &&
    status.at > 0 && now >= status.at && now - status.at <= 25000 &&
    ['STOPPED', 'IDLE', 'ERROR', 'POISONED', 'RECONNECTING', 'STOP_UNCONFIRMED'].indexOf(status.phase) < 0;
}
export function probeIssue(raw: string, status: DataplaneStatus, now: number): string {
  if (!visibleProbe(status, now)) return '';
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    if (!currentReceipt(r, status, now)) return '';
    const cn = r['directHttp'];
    if (typeof cn !== 'number' || cn < 200 || cn >= 400) return 'domestic';
    if (status.routeMode === 'direct') return '';
    if (r['googleHttp'] !== 204 && r['cloudflareHttp'] !== 204) return 'foreign';
    return '';
  } catch (_error) { return ''; }
}
/** The homepage answers the three routes a person actually needs to use.
 * Detailed stages remain available in the diagnostic report. */
export function probeHomeSummary(raw: string, status: DataplaneStatus, now: number): string {
  if (!visibleProbe(status, now)) return '';
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    if (!currentReceipt(r, status, now)) return '';
    const cn = typeof r['directHttp'] === 'number' && (r['directHttp'] as number) >= 200 &&
      (r['directHttp'] as number) < 400 ? '国内可用' : '国内未通';
    if (status.routeMode === 'direct') return cn;
    const google = r['googleHttp'] === 204, cloudflare = r['cloudflareHttp'] === 204;
    const foreign = google && cloudflare ? '海外可用' : google || cloudflare ? '海外部分可用' : '海外未通';
    return `${cn} · ${foreign} · ChatGPT 需在实际应用中验证${r['dnsOk'] === true ? '' : ' · DNS 需检查'}`;
  } catch (_error) { return ''; }
}
export function probeSummary(raw: string, status: DataplaneStatus, now: number): string {
  if (!visibleProbe(status, now)) return '';
  try {
    const r = JSON.parse(raw) as Record<string, Object>;
    if (!currentReceipt(r, status, now)) return '';
    const ok = (code: Object): string => typeof code === 'number' && code >= 200 && code < 400 ? '通过' :
      typeof code === 'number' && code > 0 ? `未通过（网站返回 ${code}）` : '未通过（请求超时或连接失败）';
    const canary = (code: Object): string => code === 204 ? '通过' :
      typeof code === 'number' && code > 0 ? `未通过（HTTP ${code}）` : '未通过（未取得 HTTP 响应）';
    const foreign = status.routeMode === 'direct' ? '全部直连模式未检查海外 HTTPS' :
      `海外 HTTPS：Google ${canary(r['googleHttp'])}，Cloudflare ${canary(r['cloudflareHttp'])}`;
    const chatgpt = status.routeMode === 'direct' ? '' : '；ChatGPT 使用：需在实际应用中验证';
    let text = `${foreign}；国内访问：${ok(r['directHttp'])}${chatgpt}；域名解析：${r['dnsOk'] === true ? '通过' : '未通过'}。`;
    const details = r['failureStages'];
    if (typeof details === 'string' && /^[a-zA-Z0-9:; _.-]{0,180}$/.test(details) && details.length > 0) {
      const readable = details.replace(/transport-unknown/g, '传输异常（阶段未确认）').replace(/connect/g, '连接失败')
        .replace(/timeout/g, '超时').replace(/dns/g, '域名解析').replace(/tls/g, '安全握手')
        .replace(/http/g, 'HTTP响应').replace(/domestic/g, '国内测试').replace(/google/g, 'Google').replace(/cloudflare/g, 'Cloudflare')
        .replace(/chatgpt/g, 'ChatGPT入口');
      text += ` 检测阶段：${readable}。`;
    }
    if (receiptAllChecksPassed(r, status.routeMode)) return text + ' 网络通道检测正常。';
    return text + ' 点“修复并检测”，重新连接后自动检查。';
  } catch (_error) { return ''; }
}
