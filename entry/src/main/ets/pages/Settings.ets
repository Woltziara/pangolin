import { UiFeedback } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 设置页（Phase C 新增）：连接模式 / 节点选择 / 故障切换 / 自动化。
// 只读写 settings.json（SettingsStore）；路由/选路/故障切换的变更在 VPN 已连接时
// 弹“需要重新连接才能生效”，立即重连走 ConnectionController stop+start。
// autoConnectOnLaunch / autoUpdateSubscriptions 本期只落盘，接线分别在 Phase D
// （EntryAbility 启动连接 / WorkScheduler 订阅刷新）。
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import {
  DataplaneStatus,
  PHASE_CANARY_OK,
  PHASE_CORE_RUNNING,
  PHASE_DEGRADED,
  PHASE_DEGRADED_UNPROVEN,
  PHASE_FORWARDER_RUNNING,
  PHASE_RECONNECTING,
  PHASE_STARTING,
  PHASE_UNPROVEN,
  PHASE_VPN_CREATED
} from '../net/DataplaneStatus';
import { CONNECTION_CONTROLLER } from '../services/ConnectionController';
import { CONNECTION_POLICY } from '../services/ConnectionPolicy';
import { DataManagement } from '../services/DataManagement';
import { NodeStore, StoredNode } from '../services/NodeStore';
import {
  AppSettings,
  EVENT_KEEP_OPTIONS,
  ROUTE_DIRECT,
  ROUTE_GLOBAL,
  ROUTE_RULE,
  SELECT_AUTO,
  SELECT_MANUAL,
  SettingsStore
} from '../services/SettingsStore';
import { StatusStore } from '../services/StatusStore';
import { SubscriptionScheduler } from '../services/SubscriptionScheduler';
import { SubscriptionStore } from '../services/SubscriptionStore';
import { MODE_FULL } from '../vpn/VpnConstants';

@CustomDialog
struct NodePickDialog {
  controller?: CustomDialogController;
  nodes: Array<StoredNode> = [];
  currentId: string = '';
  onPick: (id: string) => void = () => {
  };
  onClear: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Text('选择固定节点')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')

      List({ space: 6 }) {
        ForEach(this.nodes, (node: StoredNode) => {
          ListItem() {
            Row() {
              Column() {
                Text(NodeStore.displayName(node))
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_primary'))
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${node.region}${node.group.length > 0 ? ` · ${node.group}` : ''}`)
                  .fontSize(12)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  .margin({ top: 2 })
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (node.id === this.currentId) {
                Text('✓')
                  .fontSize(16)
                  .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
                  .margin({ left: 8 })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius(16)
            .backgroundColor(node.id === this.currentId ? $r('sys.color.ohos_id_color_component_normal') : $r('sys.color.ohos_id_color_component_normal'))
            .onClick(() => {
              this.onPick(node.id);
              this.controller?.close();
            })
          }
        }, (node: StoredNode) => node.id)
      }
      .width('100%')
      .height(320)
      .scrollBar(BarState.Auto)

      Button('清除固定，回到自动选择')
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_warning'))
        .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
        .borderRadius(18)
        .constraintSize({ minHeight: 48 })
        .width('100%')
        .onClick(() => {
          this.onClear();
          this.controller?.close();
        })
    }
    .width('100%')
    .padding(20)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }
}

@Entry
@Component
export struct Settings {
  @Prop embedded: boolean = false;
  @State viewWidth: number = 0;
  @State settings: AppSettings = new AppSettings();
  @State nodes: Array<StoredNode> = [];
  @State busy: boolean = false;
  @State exportPath: string = '';
  @State schedulerHint: string = '';
  private context: common.UIAbilityContext | null = null;
  private nodePickController: CustomDialogController | null = null;

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
    this.settings = SettingsStore.load(ctx);
    this.nodes = NodeStore.loadNodes(ctx);
  }

  private isConnected(): boolean {
    const ctx = this.context;
    if (ctx === null) {
      return false;
    }
    const plane: DataplaneStatus = StatusStore.readStatus(ctx);
    return plane.phase === PHASE_CANARY_OK || plane.phase === PHASE_DEGRADED ||
      plane.phase === PHASE_DEGRADED_UNPROVEN || plane.phase === PHASE_UNPROVEN ||
      plane.phase === PHASE_RECONNECTING || plane.phase === PHASE_FORWARDER_RUNNING ||
      plane.phase === PHASE_CORE_RUNNING || plane.phase === PHASE_VPN_CREATED ||
      plane.phase === PHASE_STARTING;
  }

  /** 写设置；若改动需要重连且当前已连接，弹出立即重连/稍后。 */
  private applyChange(mutate: (settings: AppSettings) => void): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    const before = SettingsStore.load(ctx);
    const after = SettingsStore.update(ctx, mutate);
    this.reload();
    if (SettingsStore.requiresReconnect(before, after) && this.isConnected()) {
      AlertDialog.show({
        title: '需要重新连接才能生效',
        message: '连接模式、节点选择和故障切换只在启动连接时读取。',
        primaryButton: {
          value: '立即重连',
          action: () => {
            this.reconnectNow();
          }
        },
        secondaryButton: {
          value: '稍后',
          action: () => {
          }
        }
      });
    }
  }

  private async reconnectNow(): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const startEpoch = CONNECTION_CONTROLLER.beginStartIntent();
      await CONNECTION_CONTROLLER.preflight(ctx);
      if (!CONNECTION_CONTROLLER.isStartIntentLive(startEpoch)) return;
      if (StatusStore.readStatus(ctx).desiredRunning || StatusStore.readStatus(ctx).vpnCreated) {
        const stopped = await CONNECTION_CONTROLLER.stop(ctx, false);
        if (stopped.phase !== 'STOPPED') throw new Error('旧连接还在处理。请回首页点“恢复连接”，然后再应用设置。');
      }
      if (!CONNECTION_CONTROLLER.isStartIntentLive(startEpoch)) {
        return;
      }
      await CONNECTION_CONTROLLER.start(ctx, MODE_FULL, startEpoch);
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(this.context, 'reconnect', error, '重新连接未成功，请查看诊断后重试。') });
    } finally {
      this.busy = false;
      if (!this.embedded) { router.back(); }
    }
  }

  private pinnedName(): string {
    if (this.settings.manualNodeId.length === 0) {
      return '未选择';
    }
    for (let i = 0; i < this.nodes.length; i++) {
      if (this.nodes[i].id === this.settings.manualNodeId) {
        return NodeStore.displayName(this.nodes[i]);
      }
    }
    return '已失效（连接时回退自动）';
  }

  private openNodePicker(): void {
    // 进入固定模式且无固定节点时，预选上次成功使用的节点。
    if (this.settings.manualNodeId.length === 0 && this.settings.lastGoodNodeId.length > 0) {
      const lastGood = this.settings.lastGoodNodeId;
      for (let i = 0; i < this.nodes.length; i++) {
        if (this.nodes[i].id === lastGood) {
          this.applyChange((settings) => {
            settings.selectionMode = SELECT_MANUAL;
            settings.manualNodeId = lastGood;
          });
          break;
        }
      }
    } else if (this.settings.selectionMode !== SELECT_MANUAL) {
      this.applyChange((settings) => {
        settings.selectionMode = SELECT_MANUAL;
      });
    }
    this.nodePickController = new CustomDialogController({
      builder: NodePickDialog({
        nodes: this.nodes,
        currentId: this.settings.manualNodeId,
        onPick: (id: string) => {
          this.applyChange((settings) => {
            settings.selectionMode = SELECT_MANUAL;
            settings.manualNodeId = id;
          });
        },
        onClear: () => {
          this.applyChange((settings) => {
            settings.selectionMode = SELECT_AUTO;
            settings.manualNodeId = '';
          });
        }
      }),
      customStyle: true
    });
    this.nodePickController.open();
  }

  private existingGroups(): Array<string> {
    const groups = new Set<string>();
    for (let i = 0; i < this.nodes.length; i++) {
      const group = this.nodes[i].group.trim();
      if (group.length > 0) {
        groups.add(group);
      }
    }
    const list: Array<string> = [];
    groups.forEach((group: string) => {
      list.push(group);
    });
    return list;
  }

  // ---- Phase D：隐私与数据管理 ----

  /** 自动化设置变更后重排订阅后台任务；失败只留提示，不打断设置保存。 */
  private rescheduleSubscriptions(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    SubscriptionScheduler.reschedule(ctx).then((result) => {
      this.schedulerHint = result.scheduled ? '' : '自动更新暂不可用，你仍可手动更新订阅。';
    }).catch((error: Object) => {
      this.schedulerHint = UiFeedback.failure(this.context, 'subscription-schedule', error, '自动更新暂不可用，你仍可手动更新订阅。');
    });
  }

  private confirmClearLogs(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    if (this.isConnected()) {
      promptAction.showToast({ message: '请先断开连接再清理日志' });
      return;
    }
    AlertDialog.show({
      title: '清理日志',
      message: '将删除连接诊断记录，不影响节点、订阅和设置。连接中不能清理。',
      primaryButton: {
        value: '清理',
        action: () => {
          const result = DataManagement.clearLogs(ctx);
          promptAction.showToast({ message: result.failed > 0 ? `已清理 ${result.removed} 个，另有 ${result.failed} 个未能清理` : `已清理 ${result.removed} 个日志文件` });
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private confirmClearNodesAndSubs(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    if (this.isConnected()) {
      promptAction.showToast({ message: '请先断开连接' });
      return;
    }
    const subCount = SubscriptionStore.load(ctx).length;
    AlertDialog.show({
      title: '删除全部订阅与节点',
      message: `将删除全部 ${this.nodes.length} 个节点和 ${subCount} 个订阅，此操作不可恢复。`,
      primaryButton: {
        value: '删除',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          SubscriptionScheduler.stopWork();
          DataManagement.clearNodesAndSubscriptions(ctx).then(() => {
            this.reload();
            promptAction.showToast({ message: '已删除全部订阅与节点' });
          }).catch((error: Object) => {
            promptAction.showToast({ message: UiFeedback.failure(this.context, 'clear-nodes', error, '数据未能全部清理，请稍后重试。') });
          });
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private confirmWipeAll(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    if (this.isConnected()) {
      promptAction.showToast({ message: '请先断开连接' });
      return;
    }
    AlertDialog.show({
      title: '清空全部数据',
      message: '将永久删除：节点、订阅、分流规则、设置、日志、已保存的节点凭据。此操作不可恢复。',
      primaryButton: {
        value: '全部清空',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          SubscriptionScheduler.stopWork();
          DataManagement.wipeAll(ctx).then(() => {
            SubscriptionScheduler.stopWork();
            this.reload();
            promptAction.showToast({ message: '已清空全部数据' });
          }).catch((error: Object) => {
            promptAction.showToast({ message: UiFeedback.failure(this.context, 'clear-data', error, '数据未能全部清理，请稍后重试。') });
          });
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private confirmExportConfig(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    AlertDialog.show({
      title: '导出配置（含凭据）',
      message: '导出的文件包含节点密码和订阅链接，请勿分享给他人',
      primaryButton: {
        value: '仍要导出',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          this.saveExportedConfig(ctx);
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private async saveExportedConfig(ctx: common.UIAbilityContext): Promise<void> {
    let cacheName = '';
    try {
      const srcPath = DataManagement.exportConfig(ctx);
      const slash = srcPath.lastIndexOf('/');
      cacheName = slash >= 0 ? srcPath.substring(slash + 1) : srcPath;
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['穿山甲-配置.json'];
      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris = await docPicker.save(options);
      if (uris === undefined || uris.length === 0) {
        promptAction.showToast({ message: '已取消保存' });
        return;
      }
      const raw = StatusStore.readText(ctx, cacheName);
      const dest = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(dest.fd, raw);
      } finally {
        fileIo.closeSync(dest);
      }
      this.exportPath = '已保存到所选位置';
      promptAction.showToast({ message: '已保存' });
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(this.context, 'export', error, '导出未完成，请检查保存位置后重试。') });
    } finally {
      DataManagement.removeExportCaches(ctx);
    }
  }

  private setEventKeep(count: number): void {
    const ctx = this.context;
    if (ctx === null || this.settings.eventKeepCount === count) {
      return;
    }
    SettingsStore.update(ctx, (settings) => {
      settings.eventKeepCount = count;
    });
    this.reload();
  }

  @Builder
  PrivacyRow(title: string, explain: string, danger: boolean, onTap: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(title).fontSize(16).fontColor(danger ? $r('sys.color.ohos_id_color_warning') : $r('sys.color.ohos_id_color_text_primary'))
            .width('100%')
          if (explain.length > 0) {
            Text(explain).fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 64 }).padding(16)
      .backgroundColor(Color.Transparent).borderRadius(0)
      .onClick(onTap)
  }

  @Builder
  SectionTitle(title: string) {
    Text(title).fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_primary')).width('100%').margin({ bottom: 12 })
  }

  @Builder
  Explain(text: string) {
    Text(text).fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
  }

  private groupOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '所有分组' }];
    const groups = this.existingGroups();
    if (this.settings.failoverGroup && groups.indexOf(this.settings.failoverGroup) < 0) {
      groups.push(this.settings.failoverGroup);
    }
    for (let i = 0; i < groups.length; i++) { options.push({ value: groups[i] }); }
    return options;
  }

  @Builder
  BehaviorSettings() {
    Column({ space: 12 }) {
      this.SectionTitle('连接行为')
      Column() {
        Row({ space: 16 }) {
          Column({ space: 4 }) {
            Text('启动即连接').fontSize(16)
            this.Explain('打开应用时自动建立连接')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.autoConnectOnLaunch })
            .onChange((on: boolean) => { this.applyChange((settings) => { settings.autoConnectOnLaunch = on; }); })
        }.width('100%').padding(16).constraintSize({ minHeight: 72 })
        Divider()
        if (CONNECTION_POLICY.allowsAutoFailover()) {
        Row({ space: 16 }) {
          Column({ space: 4 }) {
            Text('自动切换备用节点').fontSize(16)
            this.Explain('当前节点不可用时尝试备用节点。没有新鲜测速证据时不会宣称第二快，也不会因为单个网站失败换线路。')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.failoverEnabled })
            .onChange((on: boolean) => { this.applyChange((settings) => { settings.failoverEnabled = on; }); })
        }.width('100%').padding(16).constraintSize({ minHeight: 72 })
        if (this.settings.failoverEnabled) {
          Divider()
          Column({ space: 8 }) {
            Text('备用节点范围').fontSize(16).width('100%')
            Select(this.groupOptions()).value(this.settings.failoverGroup || '所有分组').width('100%')
              .onSelect((index: number, value: string) => {
                this.applyChange((settings) => { settings.failoverGroup = index === 0 ? '' : value; });
              })
            this.Explain('限定分组后，没有组内备用节点时不会自动切换。')
          }.width('100%').padding(16)
        }
        }
      }.width('100%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(20).clip(true)
      this.Explain('线路的自动选择或固定节点，在“连接”页分别设置。')
    }.width('100%').alignItems(HorizontalAlign.Start)

    Column({ space: 12 }) {
      this.SectionTitle('订阅更新')
      Row({ space: 16 }) {
        Column({ space: 4 }) {
          Text('自动更新订阅').fontSize(16)
          this.Explain('按各订阅的更新间隔后台刷新')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.settings.autoUpdateSubscriptions })
          .onChange((on: boolean) => {
            this.applyChange((settings) => { settings.autoUpdateSubscriptions = on; });
            this.rescheduleSubscriptions();
          })
      }.width('100%').padding(16).constraintSize({ minHeight: 72 })
        .backgroundColor($r('sys.color.comp_background_primary')).borderRadius(20)
      if (this.schedulerHint.length > 0) { this.Explain(this.schedulerHint) }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 24 })
  }

  @Builder
  DataSettings() {
    Column({ space: 12 }) {
      this.SectionTitle('隐私与数据')
      Column() {
        Row({ space: 12 }) {
          Text('当前会话事件上限').fontSize(16).layoutWeight(1)
          Select(EVENT_KEEP_OPTIONS.map((count: number): SelectOption => { return { value: `${count} 条` }; }))
            .value(`${this.settings.eventKeepCount} 条`)
            .onSelect((index: number) => { this.setEventKeep(EVENT_KEEP_OPTIONS[index]); })
        }.width('100%').padding(16).constraintSize({ minHeight: 64 })
        Divider()
        this.PrivacyRow('清理日志', '删除连接诊断记录，保留节点和设置', false, () => { this.confirmClearLogs(); })
        Divider()
        this.PrivacyRow('导出配置', '节点可重新导入；文件含凭据，请妥善保管', false, () => { this.confirmExportConfig(); })
        Divider()
        this.PrivacyRow('删除全部订阅与节点', '保留设置与规则，需先断开连接', true, () => { this.confirmClearNodesAndSubs(); })
        Divider()
        this.PrivacyRow('清空全部数据', '删除本机节点、订阅、规则和设置', true, () => { this.confirmWipeAll(); })
      }.width('100%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(20).clip(true)
      this.Explain('跨会话运行日志另按最多 48 小时 / 4 MiB 滚动保存，满后提前淘汰；故障现场保留最近 5 份。清理日志会一并删除本机副本，不删除你已另存的文件。')
      if (this.exportPath.length > 0) { this.Explain(this.exportPath) }
    }.width('100%').alignItems(HorizontalAlign.Start)

    Column({ space: 12 }) {
      this.SectionTitle('帮助')
      Column() {
        Row() {
          Text('穿山甲动效').fontSize(16).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.companionEnabled })
            .onChange((on: boolean) => { this.applyChange((settings) => { settings.companionEnabled = on; }); })
        }.width('100%').padding(16)
        Divider()
        this.PrivacyRow('诊断', '保存故障现场、导出日志或检查网络', false, () => { router.pushUrl({ url: 'pages/Diagnostics' }); })
        Divider()
        this.PrivacyRow('穿山甲皮肤', '高级外观预览', false, () => { router.pushUrl({ url: 'pages/SkinPreview' }); })
        Divider()
        this.PrivacyRow('关于穿山甲', '版本、使用说明与开源许可', false, () => { router.pushUrl({ url: 'pages/About' }); })
      }.width('100%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(20).clip(true)
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 24 })
  }

  build() {
    Column() {
      NativePage({ title: '设置', rootPage: this.embedded, hideTitle: this.embedded }) {
        Scroll() {
          Column({ space: 24 }) {
            if (this.embedded) {
              Text('设置').fontSize(26).fontWeight(FontWeight.Bold).width('100%')
            }
            if (this.viewWidth >= 720) {
              Row({ space: 24 }) {
                Column() { this.BehaviorSettings() }.layoutWeight(1)
                Column() { this.DataSettings() }.layoutWeight(1)
              }.width('100%').alignItems(VerticalAlign.Top)
            } else {
              Column({ space: 24 }) { this.BehaviorSettings(); this.DataSettings() }.width('100%')
            }
          }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
        }.width('100%').height('100%').scrollBar(BarState.Auto)
      }
    }.width('100%').height('100%')
      .onAreaChange((_old: Area, current: Area) => { this.viewWidth = Number(current.width); })
  }
}
