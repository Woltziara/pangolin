// 穿山 (GPL-3.0) — UI 展示小工具：相对时间、字节数、URL 中段脱敏、日期。
// 纯 TS：不 import 任何 @kit/@ohos 模块。

/** 相对时间："刚刚" / "N 分钟前" / "N 小时前" / "N 天前" / 超过 30 天给日期。 */
export function formatRelativeTime(at: number): string {
  if (at <= 0) {
    return '从未更新';
  }
  const diff = Date.now() - at;
  if (diff < 0) {
    return formatDate(at);
  }
  const minutes = Math.floor(diff / 60000);
  if (minutes < 1) {
    return '刚刚';
  }
  if (minutes < 60) {
    return `${minutes} 分钟前`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours} 小时前`;
  }
  const days = Math.floor(hours / 24);
  if (days < 30) {
    return `${days} 天前`;
  }
  return formatDate(at);
}

/** YYYY-MM-DD。 */
export function formatDate(at: number): string {
  if (at <= 0) {
    return '';
  }
  const d = new Date(at);
  const month = `${d.getMonth() + 1}`.padStart(2, '0');
  const day = `${d.getDate()}`.padStart(2, '0');
  return `${d.getFullYear()}-${month}-${day}`;
}

/** 字节数人性化：B / KB / MB / GB / TB。 */
export function formatBytes(value: number): string {
  if (value <= 0) {
    return '0 B';
  }
  const units: Array<string> = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size = size / 1024;
    unit++;
  }
  const text = size >= 100 ? `${Math.floor(size)}` : size.toFixed(1);
  return `${text} ${units[unit]}`;
}

/** 订阅 URL 中段脱敏：保留 scheme + host 与末尾 6 个字符，中间用 … 代替。 */
export function maskUrlMiddle(url: string): string {
  const trimmed = url.trim();
  if (trimmed.length <= 20) {
    return trimmed;
  }
  const schemeEnd = trimmed.indexOf('://');
  const hostStart = schemeEnd >= 0 ? schemeEnd + 3 : 0;
  let hostEnd = trimmed.indexOf('/', hostStart);
  if (hostEnd < 0) {
    hostEnd = trimmed.length;
  }
  if (hostEnd < trimmed.length) {
    const head = trimmed.substring(0, hostEnd);
    const tail = trimmed.substring(trimmed.length - 6);
    return `${head}/…${tail}`;
  }
  // 没有路径时只脱敏 host 中段。
  const head = trimmed.substring(0, Math.min(hostStart + 8, trimmed.length - 8));
  const tail = trimmed.substring(trimmed.length - 6);
  return `${head}…${tail}`;
}
