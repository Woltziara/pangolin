import { UserRuleRoute } from './UserRuleMap';

/** Channel selection is a local configuration choice. */
export function effectiveChannelMode(requested: string): string {
  return requested === 'dual' ? 'dual' : 'single';
}

/** Group destinations only exist in the split-channel runtime; preserve them in storage. */
export function routesForChannel(routes: UserRuleRoute[], mode: string): UserRuleRoute[] {
  return mode === 'dual' ? routes : routes.filter((route: UserRuleRoute) => route.action !== 'group');
}

/** Convert a historical split payload to the current single-channel runtime payload. */
export function singleChannelPayload(payload: string): string {
  const source = JSON.parse(payload) as Record<string, Object>;
  if (source['channelMode'] === 'single' && source['v'] === 4) { return payload; }
  const out: Record<string, Object> = {};
  out['v'] = 4;
  const split = source['v'] === 3;
  out['single'] = source['v'] === 4 ? source['single'] : split ? source['yt'] : source['v'] === 2 ? source['us'] : source;
  out['singleName'] = source['singleName'] ?? (split ? source['ytName'] : source['usName']) ?? '';
  out['singleRegion'] = source['singleRegion'] ?? (split ? source['ytRegion'] : source['usRegion']) ?? '';
  const backup = source['single2'] ?? (split ? source['yt2'] : source['us2']);
  if (backup !== undefined) {
    out['single2'] = backup;
    out['single2Name'] = source['single2Name'] ?? (split ? source['yt2Name'] : source['us2Name']) ?? '';
    out['single2Region'] = source['single2Region'] ?? (split ? source['yt2Region'] : source['us2Region']) ?? '';
  }
  out['singleFailedOver'] = source['singleFailedOver'] ?? (split ? source['ytFailedOver'] : source['usFailedOver']) ?? false;
  out['routeMode'] = source['routeMode'] ?? 'rule';
  out['routingProfile'] = 'chatgpt-general';
  out['channelMode'] = 'single';
  out['singleNodeId'] = source['singleNodeId'] ?? source['generalNodeId'] ?? '';
  const routes = Array.isArray(source['userRules']) ? source['userRules'] as UserRuleRoute[] : [];
  out['userRules'] = routesForChannel(routes, 'single');
  if (source['appRouting'] !== undefined) {
    out['appRouting'] = source['appRouting'];
  }
  return JSON.stringify(out);
}

/** A backup can be promoted only once per active runtime and only when enabled by the user. */
export function runtimeMayPromoteBackup(userEnabled: boolean, alreadyFailedOver: boolean): boolean {
  return userEnabled === true && alreadyFailedOver !== true;
}

/** Turning backup switching off also removes unused backup credentials from the execution copy. */
export function payloadForFailover(payload: string, userEnabled: boolean): string {
  if (userEnabled) { return payload; }
  const source = JSON.parse(payload) as Record<string, Object>;
  const result: Record<string, Object> = {};
  const backupKeys: string[] = ['single2', 'single2Name', 'single2Region', 'single2Id',
    'yt2', 'yt2Name', 'yt2Region', 'yt2Id', 'us2', 'us2Name', 'us2Region', 'us2Id'];
  Object.keys(source).forEach((key: string) => {
    if (backupKeys.indexOf(key) < 0) { result[key] = source[key]; }
  });
  result['singleFailedOver'] = false;
  result['ytFailedOver'] = false;
  result['usFailedOver'] = false;
  return JSON.stringify(result);
}
