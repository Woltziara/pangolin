import { publicFailure } from '../core/UserFacingCopy';
import { UiFeedback } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 订阅管理页：列表 / 添加 / 重命名 / 删除 / 立即更新 / 全部更新 /
// 自动更新开关与间隔（2/6/12/24 小时）。所有变更经 SubscriptionStore / SubscriptionManager。
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { SubscriptionManager, UpdateResult } from '../services/SubscriptionManager';
import { SubscriptionScheduler } from '../services/SubscriptionScheduler';
import { SubscriptionRecord, SubscriptionStore } from '../services/SubscriptionStore';
import { formatBytes, formatDate, formatRelativeTime, maskUrlMiddle } from '../services/UiFormat';

const INTERVAL_OPTIONS: Array<number> = [2, 6, 12, 24];

@CustomDialog
struct RenameDialog {
  controller?: CustomDialogController;
  initial: string = '';
  onDone: (name: string) => void = () => {
  };
  @State value: string = '';

  aboutToAppear(): void {
    this.value = this.initial;
  }

  build() {
    Column({ space: 14 }) {
      Text('重命名订阅')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')

      TextInput({ text: this.value, placeholder: '订阅名称' })
        .constraintSize({ minHeight: 48 })
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
        .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
        .borderRadius(8)
        .onChange((value: string) => {
          this.value = value;
        })

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .borderRadius(18)
          .constraintSize({ minHeight: 48 })
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close();
          })
        Button('确定')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .backgroundColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .borderRadius(18)
          .constraintSize({ minHeight: 48 })
          .layoutWeight(1)
          .enabled(this.value.trim().length > 0)
          .onClick(() => {
            this.onDone(this.value.trim());
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }
}

@Entry
@Component
struct Subscriptions {
  @State subs: Array<SubscriptionRecord> = [];
  @State updatingIds: Array<string> = [];
  @State busyAll: boolean = false;
  @State newUrl: string = '';
  @State newName: string = '';
  @State lastError: string = '';
  private context: common.UIAbilityContext | null = null;
  private renameController: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  private reload(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    this.subs = SubscriptionStore.load(ctx);
  }

  private isUpdating(id: string): boolean {
    return this.updatingIds.indexOf(id) >= 0;
  }

  private setUpdating(id: string, updating: boolean): void {
    const next = this.updatingIds.filter((item: string) => item !== id);
    if (updating) {
      next.push(id);
    }
    this.updatingIds = next;
  }

  private rescheduleBackground(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    // Phase D：订阅增删/开关/间隔变化后重排 WorkScheduler 后台任务。
    SubscriptionScheduler.reschedule(ctx).catch((error: Object) => {
      console.error(`reschedule failed ${JSON.stringify(error)}`);
    });
  }

  private async addSubscription(): Promise<void> {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    const url = this.newUrl.trim();
    const validation = SubscriptionManager.validateSubscriptionUrl(url, false);
    if (validation.length > 0) {
      this.lastError = validation;
      return;
    }
    this.lastError = '';
    const record = SubscriptionStore.add(ctx, this.newName, url);
    this.newUrl = '';
    this.newName = '';
    this.reload();
    this.rescheduleBackground();
    await this.updateOne(record.id);
  }

  private async updateOne(id: string): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.isUpdating(id)) {
      return;
    }
    this.setUpdating(id, true);
    try {
      const result: UpdateResult = await SubscriptionManager.updateSubscription(ctx, id);
      promptAction.showToast({ message: result.ok ? '订阅已更新' : publicFailure(result.message, '订阅更新失败，请检查网络和订阅链接。') });
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(this.context, 'subscription-update', error, '订阅更新失败，请检查网络和订阅链接。') });
    } finally {
      this.setUpdating(id, false);
      this.reload();
    }
  }

  private async updateAll(): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.busyAll) {
      return;
    }
    this.busyAll = true;
    let okCount = 0;
    let failCount = 0;
    for (let i = 0; i < this.subs.length; i++) {
      const sub = this.subs[i];
      if (!sub.enabled) {
        continue;
      }
      this.setUpdating(sub.id, true);
      try {
        const result = await SubscriptionManager.updateSubscription(ctx, sub.id);
        if (result.ok) {
          okCount++;
        } else {
          failCount++;
        }
      } catch (error) {
        failCount++;
      } finally {
        this.setUpdating(sub.id, false);
      }
    }
    this.busyAll = false;
    this.reload();
    promptAction.showToast({
      message: failCount === 0 ? `全部更新完成（${okCount} 个订阅）` : `更新完成：${okCount} 个成功，${failCount} 个失败`
    });
  }

  private openRename(sub: SubscriptionRecord): void {
    this.renameController = new CustomDialogController({
      builder: RenameDialog({
        initial: sub.name,
        onDone: (name: string) => {
          const ctx = this.context;
          if (ctx === null) {
            return;
          }
          sub.name = name;
          SubscriptionStore.update(ctx, sub);
          this.reload();
        }
      }),
      customStyle: true
    });
    this.renameController.open();
  }

  private confirmDelete(sub: SubscriptionRecord): void {
    AlertDialog.show({
      title: '删除订阅',
      message: `确定删除「${sub.name}」吗？已经导入的节点会保留在节点列表中。`,
      primaryButton: {
        value: '删除',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          const ctx = this.context;
          if (ctx === null) {
            return;
          }
          SubscriptionStore.remove(ctx, sub.id);
          this.reload();
          this.rescheduleBackground();
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private toggleAutoUpdate(sub: SubscriptionRecord, on: boolean): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    sub.autoUpdate = on;
    SubscriptionStore.update(ctx, sub);
    this.reload();
    this.rescheduleBackground();
  }

  private setIntervalHours(sub: SubscriptionRecord, hours: number): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    sub.intervalHours = hours;
    SubscriptionStore.update(ctx, sub);
    this.reload();
    this.rescheduleBackground();
  }

  private userinfoLine(sub: SubscriptionRecord): string {
    const info = sub.userinfo;
    if (info === null) {
      return '';
    }
    const used = info.upload + info.download;
    const total = info.total > 0 ? formatBytes(info.total) : '未知';
    const expire = info.expire > 0 ? formatDate(info.expire * 1000) : '长期';
    return `已用 ${formatBytes(used)} / 共 ${total} · 到期 ${expire}`;
  }


  @Builder
  IntervalChip(sub: SubscriptionRecord, hours: number) {
    Text(`每 ${hours} 小时`)
      .fontSize(12)
      .fontColor(sub.intervalHours === hours ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('sys.color.ohos_id_color_text_secondary'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 8 })
      .borderRadius(13)
      .backgroundColor(sub.intervalHours === hours ? $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_button_normal'))
      .onClick(() => {
        this.setIntervalHours(sub, hours);
      })
  }

  @Builder
  SubRow(sub: SubscriptionRecord) {
    Column({ space: 8 }) {
      Row() {
        Text(sub.name)
          .fontSize(16)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.isUpdating(sub.id)) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color($r('sys.color.ohos_id_color_text_primary_activated'))
        } else {
          Text('立即更新')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.updateOne(sub.id);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(maskUrlMiddle(sub.url))
        .fontSize(12)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`${sub.nodeCount} 个节点 · 最后更新 ${formatRelativeTime(sub.lastUpdateAt)}`)
        .fontSize(12)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')

      if (this.userinfoLine(sub).length > 0) {
        Text(this.userinfoLine(sub))
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
      }

      if (sub.lastError.length > 0) {
        Text(publicFailure(sub.lastError, '上次更新失败，请检查网络和订阅链接。'))
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .width('100%')
      }

      Row() {
        Text('自动更新')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        Toggle({ type: ToggleType.Switch, isOn: sub.autoUpdate })
          .margin({ left: 8 })
          .onChange((on: boolean) => {
            this.toggleAutoUpdate(sub, on);
          })
        Blank()
        Text('重命名')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.openRename(sub);
          })
        Text('删除')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.confirmDelete(sub);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (sub.autoUpdate) {
        Row() {
          ForEach(INTERVAL_OPTIONS, (hours: number) => {
            this.IntervalChip(sub, hours)
          }, (hours: number) => `${sub.id}-${hours}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  build() {
    Column() {
    NativePage({ title: '订阅', rootPage: false }) {
    Column() {


      Button('全部更新').enabled(!this.busyAll && this.subs.length > 0)
        .onClick(() => { this.updateAll(); }).margin({ bottom: 8 })
      // 添加订阅
      Column({ space: 10 }) {
        TextInput({ placeholder: '订阅地址（https://…）', text: this.newUrl })
          .constraintSize({ minHeight: 48 })
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
          .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
          .borderRadius(8)
          .onChange((value: string) => {
            this.newUrl = value;
          })
        Row({ space: 10 }) {
          TextInput({ placeholder: '名称（可选）', text: this.newName })
            .constraintSize({ minHeight: 48 })
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
            .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
            .borderRadius(8)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.newName = value;
            })
          Button('添加')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
            .backgroundColor($r('sys.color.ohos_id_color_text_primary'))
            .borderRadius(18)
            .constraintSize({ minHeight: 48 })
            .enabled(this.newUrl.trim().length > 0)
            .onClick(() => {
              this.addSubscription();
            })
        }
        .width('100%')

        if (this.lastError.length > 0) {
          Text(this.lastError)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_warning'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .margin({ bottom: 12 })

      if (this.subs.length === 0) {
        Text('还没有订阅。添加后会自动抓取节点。')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ top: 20 })
      }

      List({ space: 10 }) {
        ForEach(this.subs, (sub: SubscriptionRecord) => {
          ListItem() {
            this.SubRow(sub)
          }
        }, (sub: SubscriptionRecord) => `${sub.id}|${sub.name}|${sub.lastUpdateAt}|${sub.lastError}|${sub.autoUpdate}|${sub.intervalHours}|${sub.nodeCount}|${this.isUpdating(sub.id)}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
    }
    }.width('100%').height('100%')
  }
}
