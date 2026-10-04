import { ErrorJournal } from '../services/ErrorJournal';
import { AppLog as hilog } from '../services/AppLog';
// 穿山 (GPL-3.0) — 订阅自动更新后台任务（Phase D 新增）。
// WorkSchedulerExtensionAbility 骨架参考 Hey (GPL-3.0)
// entry/src/main/ets/work/SubscriptionUpdateWorkAbility.ets（onWorkStart 内
// 异步执行 + 全程 try/catch），移植日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 生命周期要点：本 Ability 运行在独立进程上下文，所有存储访问一律使用
// this.context（其 filesDir 与 UI 进程相同），禁止依赖任何 UI 组件状态。
// 单次回调上限 2 分钟：按到期时间 oldest-first，最多更新 MAX_SUBSCRIPTIONS_PER_RUN 条。
import { common } from '@kit.AbilityKit';
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { SettingsStore } from '../services/SettingsStore';
import { SubscriptionManager } from '../services/SubscriptionManager';
import { MAX_SUBSCRIPTIONS_PER_RUN } from '../services/SubscriptionScheduler';
import { SubscriptionRecord, SubscriptionStore } from '../services/SubscriptionStore';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'SubUpdateWork';
// 2 分钟回调预算内自留余量：超过该耗时即停止本轮，剩余订阅等下次点火。
const RUN_BUDGET_MS: number = 90000;

export default class SubscriptionUpdateWorkAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    ErrorJournal.start(this.context, 'subscription-work');
    this.runDueUpdates(work).catch((error: Object) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'runDueUpdates %{public}s', JSON.stringify(error));
    });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'work stopped workId=%{public}d', work.workId);
  }

  private async runDueUpdates(work: workScheduler.WorkInfo): Promise<void> {
    const context = this.context as common.Context;
    const started = Date.now();
    const settings = SettingsStore.load(context);
    if (!settings.autoUpdateSubscriptions) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'auto update disabled, skip workId=%{public}d', work.workId);
      return;
    }
    const subs = SubscriptionStore.load(context);
    const now = Date.now();
    const due: Array<SubscriptionRecord> = [];
    for (let i = 0; i < subs.length; i++) {
      const sub = subs[i];
      if (!sub.enabled || !sub.autoUpdate) {
        continue;
      }
      const intervalMs = SubscriptionStore.clampIntervalHours(sub.intervalHours) * 3600 * 1000;
      if (sub.lastUpdateAt <= 0 || sub.lastUpdateAt + intervalMs <= now) {
        due.push(sub);
      }
    }
    // 最久未更新的优先。
    due.sort((a: SubscriptionRecord, b: SubscriptionRecord): number => a.lastUpdateAt - b.lastUpdateAt);

    let done = 0;
    let failed = 0;
    for (let i = 0; i < due.length && done < MAX_SUBSCRIPTIONS_PER_RUN; i++) {
      if (Date.now() - started > RUN_BUDGET_MS) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'budget exhausted, remaining subscriptions wait next fire');
        break;
      }
      const result = await SubscriptionManager.updateSubscription(context, due[i].id);
      done += 1;
      if (!result.ok) {
        failed += 1;
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'workId=%{public}d due=%{public}d done=%{public}d failed=%{public}d',
      work.workId, due.length, done, failed);
  }
}
