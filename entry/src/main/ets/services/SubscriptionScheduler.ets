import { AppLog as hilog } from './AppLog';
// 穿山 (GPL-3.0) — 订阅自动更新调度（Phase D 新增）。
// WorkScheduler 注册/取消写法参考 Hey (GPL-3.0)
// entry/src/main/ets/services/SubscriptionBackgroundScheduler.ets（startWork 前
// 先 stopWork 同 id、startWork 整体 try/catch），移植日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 差异（产品定义）：本项目只注册一个循环任务（固定 workId），间隔取所有
// 启用且自动更新订阅的最小 intervalHours，并按 WorkScheduler 下限钳制到 ≥2h。
import { common } from '@kit.AbilityKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { BUNDLE_NAME } from '../vpn/VpnConstants';
import { SettingsStore } from './SettingsStore';
import { MIN_INTERVAL_HOURS, SubscriptionRecord, SubscriptionStore } from './SubscriptionStore';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'SubScheduler';

export const SUBSCRIPTION_WORK_ID: number = 61;
export const SUBSCRIPTION_WORK_ABILITY: string = 'SubscriptionUpdateWorkAbility';
// WorkScheduler 循环任务最小间隔 2 小时（官方约束，见 docs/research/hmos-api-verification.md §5）。
export const MIN_REPEAT_MS: number = MIN_INTERVAL_HOURS * 3600 * 1000;
// 单次回调上限 2 分钟：每次点火最多顺序更新的订阅数。
export const MAX_SUBSCRIPTIONS_PER_RUN: number = 5;

export class ScheduleResult {
  scheduled: boolean = false;
  intervalMs: number = 0;
  message: string = '';
}

/** 计算注册间隔：启用 + autoUpdate 订阅的最小 intervalHours，钳制 ≥2h；无目标返回 0。 */
export function computeRepeatIntervalMs(subs: Array<SubscriptionRecord>): number {
  let best = 0;
  for (let i = 0; i < subs.length; i++) {
    const sub = subs[i];
    if (!sub.enabled || !sub.autoUpdate) {
      continue;
    }
    const hours = SubscriptionStore.clampIntervalHours(sub.intervalHours);
    if (best === 0 || hours < best) {
      best = hours;
    }
  }
  if (best === 0) {
    return 0;
  }
  const ms = best * 3600 * 1000;
  return ms < MIN_REPEAT_MS ? MIN_REPEAT_MS : ms;
}

export class SubscriptionScheduler {
  /**
   * 重排调度：设置页/订阅页任何相关变更后调用。
   * 无目标订阅或总开关关闭 → 停掉任务；否则以最新间隔重新注册。
   * startWork 可能因系统配额/状态抛错，全部吞掉并写进返回值，由 UI 决定提示。
   */
  static async reschedule(context: common.Context): Promise<ScheduleResult> {
    const result = new ScheduleResult();
    const settings = SettingsStore.load(context);
    const subs = SubscriptionStore.load(context);
    const intervalMs = settings.autoUpdateSubscriptions ? computeRepeatIntervalMs(subs) : 0;
    if (intervalMs <= 0) {
      SubscriptionScheduler.stopWork();
      result.message = '没有需要自动更新的订阅，已停止后台任务';
      return result;
    }
    try {
      SubscriptionScheduler.stopWork();
      const work: workScheduler.WorkInfo = {
        workId: SUBSCRIPTION_WORK_ID,
        bundleName: BUNDLE_NAME,
        abilityName: SUBSCRIPTION_WORK_ABILITY,
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        isPersisted: true,
        isRepeat: true,
        repeatCycleTime: intervalMs,
        parameters: {
          source: 'subscription-auto-update',
          intervalHours: intervalMs / 3600000
        }
      };
      workScheduler.startWork(work);
      result.scheduled = true;
      result.intervalMs = intervalMs;
      result.message = `已安排每 ${intervalMs / 3600000} 小时自动更新订阅`;
    } catch (error) {
      result.message = `后台订阅更新注册失败：${SubscriptionScheduler.stringify(error)}`;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'startWork %{public}s', result.message);
    }
    return result;
  }

  /** 无条件停掉订阅后台任务（清空数据/关闭总开关时调用）。 */
  static stopWork(): void {
    try {
      const cancel: workScheduler.WorkInfo = {
        workId: SUBSCRIPTION_WORK_ID,
        bundleName: BUNDLE_NAME,
        abilityName: SUBSCRIPTION_WORK_ABILITY
      };
      workScheduler.stopWork(cancel, true);
    } catch (error) {
      // 没有已注册任务时 stopWork 抛错，属正常路径。
    }
  }

  private static stringify(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return JSON.stringify(error);
  }
}
