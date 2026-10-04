/** Foreground-only traffic view. Every point belongs to one VPN owner session. */
export class TrafficSample {
  generation: string = '';
  ownerInstance: string = '';
  revision: number = 0;
  at: number = 0;
  uploadBytes: number = 0;
  downloadBytes: number = 0;
}

export class TrafficPoint {
  at: number = 0;
  uploadRate: number = 0;
  downloadRate: number = 0;
}

export function parseTrafficSample(raw: string, generation: string, ownerInstance: string,
  revision: number, now: number): TrafficSample | null {
  try {
    const row = JSON.parse(raw) as Record<string, Object>;
    if (row['schema'] !== 1 || row['generation'] !== generation || row['ownerInstance'] !== ownerInstance ||
      row['revision'] !== revision || typeof row['at'] !== 'number' || typeof row['uploadBytes'] !== 'number' ||
      typeof row['downloadBytes'] !== 'number') return null;
    const at = row['at'] as number, up = row['uploadBytes'] as number, down = row['downloadBytes'] as number;
    if (!Number.isSafeInteger(at) || at > now + 1000 || now - at > 6000 ||
      !Number.isFinite(up) || !Number.isFinite(down) || up < 0 || down < 0) return null;
    const sample = new TrafficSample();
    sample.generation = generation; sample.ownerInstance = ownerInstance; sample.revision = revision;
    sample.at = at; sample.uploadBytes = up; sample.downloadBytes = down;
    return sample;
  } catch (_error) { return null; }
}

export function trafficPoint(before: TrafficSample, after: TrafficSample): TrafficPoint | null {
  if (before.generation !== after.generation || before.ownerInstance !== after.ownerInstance ||
    before.revision !== after.revision || after.at <= before.at || after.at - before.at > 10000 ||
    after.uploadBytes < before.uploadBytes || after.downloadBytes < before.downloadBytes) return null;
  const seconds = (after.at - before.at) / 1000;
  const point = new TrafficPoint();
  point.at = after.at;
  point.uploadRate = (after.uploadBytes - before.uploadBytes) / seconds;
  point.downloadRate = (after.downloadBytes - before.downloadBytes) / seconds;
  return point;
}

export function trafficWindow(points: TrafficPoint[], now: number): TrafficPoint[] {
  return points.filter((point: TrafficPoint) => point.at <= now && point.at >= now - 60000).slice(-30);
}

export function trafficPath(points: TrafficPoint[], upload: boolean, width: number, height: number,
  now: number): string {
  if (width <= 0 || height <= 0) return '';
  const high = Math.max(1024, ...points.map((point: TrafficPoint) => Math.max(point.uploadRate, point.downloadRate)));
  const bottom = height - 3;
  if (points.length === 0) return `M 0 ${bottom} L ${width} ${bottom}`;
  let path = '';
  for (let i = 0; i < points.length; i++) {
    const point = points[i];
    const x = Math.max(0, Math.min(width, width * (point.at - (now - 60000)) / 60000));
    const rate = upload ? point.uploadRate : point.downloadRate;
    const y = Math.max(3, bottom - (bottom - 3) * Math.min(1, rate / high));
    path += `${i === 0 ? 'M' : ' L'} ${Math.round(x)} ${Math.round(y)}`;
  }
  return path;
}
