import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
export class BuildIdentity {
  private static cached: string = '';
  static source(context: common.Context): string {
    if (BuildIdentity.cached.length > 0) return BuildIdentity.cached;
    try {
      const raw = context.resourceManager.getRawFileContentSync('pangolin-build.json');
      const text = new util.TextDecoder('utf-8').decodeToString(raw);
      const doc = JSON.parse(text) as Record<string, Object>;
      if (doc['schema'] === 1 && typeof doc['sourceIdentity'] === 'string' &&
        /^[0-9a-f]{64}$/.test(doc['sourceIdentity'] as string)) {
        BuildIdentity.cached = doc['sourceIdentity'] as string;
      }
    } catch (_error) { /* Direct IDE builds have no measured package identity. */ }
    return BuildIdentity.cached;
  }
}
