/** Customer-facing language. Runtime facts and raw errors remain in their original stores. */
export class ConnectionCopy {
  title: string = '未连接';
  detail: string = '选择节点后即可连接。';
  needsHelp: boolean = false;
  warning: boolean = false;
}

export function connectionCopy(phase: string, stale: boolean, hasNodes: boolean,
  health: string = '', established: boolean = false): ConnectionCopy {
  const copy = new ConnectionCopy();
  if (stale) {
    copy.title = '连接状态待确认';
    copy.detail = '暂时无法读取最新连接状态，请查看诊断。';
    copy.needsHelp = true;
    copy.warning = true;
    return copy;
  }
  const terminal = phase === 'STOPPED' || phase === 'IDLE' || phase === 'ERROR' ||
    phase === 'POISONED' || phase === 'RECONNECTING';
  if (!terminal && established) {
    copy.title = '已连接';
    copy.detail = 'VPN 连接已建立。';
    return copy;
  }
  if (!terminal && health === 'reachable') {
    copy.title = '已连接';
    copy.detail = '网络检查正常。';
    return copy;
  }
  if (!terminal && health === 'checking') {
    copy.title = '正在检查连接';
    copy.detail = '连接已建立，正在检查网络访问。';
    return copy;
  }
  if (!terminal && health === 'check-failed') {
    copy.title = '连接需检查';
    copy.detail = '连接仍保持，但部分网络检查未通过。';
    copy.needsHelp = true;
    copy.warning = true;
    return copy;
  }
  if (!terminal && health === 'unverified') {
    copy.title = '连接状态待确认';
    copy.detail = '连接保持中，网络检查暂未完成。可尝试访问网站，或查看诊断。';
    copy.needsHelp = true;
    return copy;
  }
  if (!terminal && health === 'offline') {
    copy.title = '连接已中断';
    copy.detail = '隧道已停止工作，请重新连接。';
    copy.needsHelp = true;
    copy.warning = true;
    return copy;
  }
  switch (phase) {
    case 'CANARY_OK':
      copy.title = '已连接';
      copy.detail = '网络连接正常。';
      break;
    case 'STARTING':
    case 'VPN_CREATED':
    case 'PROBE_SNIFFING':
    case 'CORE_RUNNING':
    case 'FORWARDER_RUNNING':
      copy.title = '正在连接';
      copy.detail = '正在建立连接，请稍候。';
      break;
    case 'RECONNECTING':
      copy.title = '正在重新连接';
      copy.detail = '正在恢复连接，期间网络可能暂时不可用。';
      break;
    case 'UNPROVEN':
      copy.title = '正在检查连接';
      copy.detail = '连接已建立，正在检查是否能够访问网络。';
      copy.needsHelp = true;
      break;
    case 'DEGRADED':
      copy.title = '连接不稳定';
      copy.detail = '部分网络检查未通过，请查看诊断。';
      copy.needsHelp = true;
      copy.warning = true;
      break;
    case 'DEGRADED_UNPROVEN':
      copy.title = '连接状态待确认';
      copy.detail = '暂时无法确认网络访问情况，请查看诊断。';
      copy.needsHelp = true;
      break;
    case 'ERROR':
      copy.title = '连接失败';
      copy.detail = '未能建立连接。请检查网络和节点，或查看诊断。';
      copy.needsHelp = true;
      copy.warning = true;
      break;
    case 'POISONED':
      copy.title = '连接需要重置';
      copy.detail = '上次连接未能正常结束，请查看诊断后重试。';
      copy.needsHelp = true;
      copy.warning = true;
      break;
    case 'STOPPED':
      copy.title = '已断开';
      break;
    case 'IDLE':
      break;
    default:
      copy.title = '连接状态待确认';
      copy.detail = '暂时无法确认连接是否可用，请查看诊断。';
      copy.needsHelp = true;
      copy.warning = true;
      break;
  }
  if ((phase === 'IDLE' || phase === 'STOPPED') && !hasNodes) {
    copy.detail = '还没有可连接的节点，请先到“节点”页添加。';
  }
  return copy;
}

/** Only known user-actionable causes are translated; arbitrary SDK text is never passed through. */
export function publicFailure(raw: string, fallback: string): string {
  if (/域名解析失败|Failed to resolve|resolve the host|2300006/i.test(raw)) {
    return '订阅服务器域名解析失败，请检查当前连接的 DNS 或稍后重试。';
  }
  const http = /HTTP\s+(\d{3})/.exec(raw);
  if (http !== null) {
    const code = Number(http[1]);
    if (code === 401 || code === 403) { return `订阅服务器拒绝访问（HTTP ${code}）。已联系到服务器，请核对订阅权限或服务方的客户端限制。`; }
    if (code === 404) { return '订阅地址未找到（HTTP 404），请核对地址是否完整。'; }
    if (code === 429) { return '订阅服务器限制了请求频率（HTTP 429），请稍后再试。'; }
    return `订阅服务器返回错误（HTTP ${code}），请稍后重试。`;
  }
  if (raw === 'LICENSE_UNAVAILABLE' || raw === 'LICENSE_RESPONSE_INVALID') { return '暂时无法确认使用权限，请联网后重试。'; }
  const lower = raw.toLowerCase();
  if (lower.indexOf('timeout') >= 0 || raw.indexOf('超时') >= 0) {
    return '操作超时，请检查网络后重试。';
  }
  if (lower.indexOf('certificate') >= 0 || raw.indexOf('证书') >= 0) {
    return '安全验证未通过，请检查节点或订阅配置。';
  }
  if (raw.indexOf('订阅已删除、关闭或已更改') >= 0) {
    return '订阅已变更，本次更新未写入节点。';
  }
  if (raw.indexOf('明文链接') >= 0 || raw.indexOf('重定向目标无效') >= 0) {
    return '订阅链接不安全，请向服务提供方获取 HTTPS 链接。';
  }
  if (raw.indexOf('网页内容而不是配置') >= 0) {
    return '该地址返回的是网页，请填写订阅链接。';
  }
  if (raw.indexOf('没有可用节点') >= 0 || raw.indexOf('没有可连接的节点') >= 0) {
    return '没有可用节点，请检查导入内容或订阅。';
  }
  return fallback;
}

/** Diagnostic-only rendering, with embedded credentials and URL paths removed. */
export function redactDiagnosticText(text: string): string {
  return text
    .replace(/[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s"'<>]+/g, '[地址已隐藏]')
    .replace(/\b(?:authorization|proxy-authorization)\s*[:=]\s*(?:Bearer|Basic)\s+[^\s,"'}]+/gi, '[认证信息已隐藏]')
    .replace(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/g, '[标识已隐藏]')
    .replace(/((?:password|passwd|pwd|secret|token|authorization|cookie|purchaseData)\s*["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*')/gi, '$1"[已隐藏]"')
    .replace(/((?:password|passwd|pwd|secret|token|authorization|cookie|purchaseData)\s*["']?\s*[:=]\s*["']?)[^\s,"'}]+/gi, '$1[已隐藏]')
    .substring(0, 4000);
}
