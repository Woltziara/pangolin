import { AppliedPolicy } from '../services/AppliedPolicy';
import { UiFeedback } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 分流规则页（Phase C2 新增）：当前模式入口 / 内置模板说明 /
// 我的规则（直连 / 走代理 / 走节点组）。只读写 user-rules.json（UserRuleStore）；
// 规则在 VPN 已连接时变更会弹“需要重新连接才能生效”，立即重连走
// ConnectionController stop+start（与设置页同一模式）。
// 已知限制：节点组规则当前映射到两条分流线路之一（见页脚说明与 UserRuleMap）。
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
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
import {
  USER_RULE_ACTION_DIRECT,
  USER_RULE_ACTION_GROUP,
  USER_RULE_ACTION_PROXY
} from '../core/UserRuleMap';
import { CONNECTION_CONTROLLER } from '../services/ConnectionController';
import { NodeStore, StoredNode } from '../services/NodeStore';
import {
  AppSettings,
  ROUTE_RULE,
  ROUTE_DIRECT,
  ROUTE_GLOBAL,
  SELECT_MANUAL,
  SettingsStore
} from '../services/SettingsStore';
import { StatusStore } from '../services/StatusStore';
import { AddRuleResult, UserRule, UserRuleStore } from '../services/UserRuleStore';
import { MODE_FULL } from '../vpn/VpnConstants';

@Entry
@Component
export struct Rules {
  @Prop embedded: boolean = false;
  onInteraction: () => void = () => {};
  @Prop @Watch('reload') revision: number = 0;
  @State applied: boolean = false;
  @State feedback: string = '';
  @State advanced: boolean = false;
  @State panelWidth: number = 0;
  private contentScroller: Scroller = new Scroller();
  @State settings: AppSettings = new AppSettings();
  @State rules: Array<UserRule> = [];
  @State nodes: Array<StoredNode> = [];
  @State newDomain: string = '';
  @State newAction: string = USER_RULE_ACTION_DIRECT;
  @State newGroup: string = '';
  @State formError: string = '';
  @State busy: boolean = false;
  private context: common.UIAbilityContext | null = null;

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
    this.rules = UserRuleStore.load(ctx);
    this.nodes = NodeStore.loadNodes(ctx);
    this.applied = AppliedPolicy.matches(ctx);
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

  /** 规则只在启动连接时读取；已连接时改动后提示重连（与设置页同一模式）。 */
  private afterRuleChange(): void {
    this.onInteraction();
    this.reload();
    this.feedback = this.isConnected() ? '规则已保存。回首页点“应用并连接”。' : '规则已保存，下次连接时生效。';
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
      if (this.isConnected()) {
        const stopped = await CONNECTION_CONTROLLER.stop(ctx, false);
        if (stopped.phase !== 'STOPPED') throw new Error('旧连接还在处理。请回首页点“恢复连接”，然后再应用规则。');
      }
      if (!CONNECTION_CONTROLLER.isStartIntentLive(startEpoch)) {
        return;
      }
      await CONNECTION_CONTROLLER.start(ctx, MODE_FULL, startEpoch);
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(this.context, 'reconnect', error, '重新连接未成功，请查看诊断后重试。') });
    } finally {
      this.busy = false;
      this.reload();
      this.feedback = this.applied ? '规则已生效。' : '规则尚未生效，请回首页恢复连接后重试。';
    }
  }

  private addRule(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    const result: AddRuleResult = UserRuleStore.add(ctx, this.newDomain, this.newAction, this.newGroup);
    if (!result.ok) {
      this.formError = result.error;
      return;
    }
    this.formError = '';
    this.newDomain = '';
    this.afterRuleChange();
  }

  private confirmRemove(rule: UserRule): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    AlertDialog.show({
      title: '删除这条规则？',
      message: `${rule.domain} · ${this.actionLabel(rule)}`,
      primaryButton: {
        value: '删除',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          UserRuleStore.remove(ctx, rule.id);
          this.afterRuleChange();
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private toggleRule(rule: UserRule, isOn: boolean): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    UserRuleStore.setEnabled(ctx, rule.id, isOn);
    this.afterRuleChange();
  }

  private actionLabel(rule: UserRule): string {
    if (rule.action === USER_RULE_ACTION_DIRECT) {
      return '直连';
    }
    if (rule.action === USER_RULE_ACTION_GROUP) {
      return `本版暂停 · 已保留节点组规则：${rule.groupTag}`;
    }
    return '当前代理线路';
  }

  private modeLine(): string {
    let mode = '按规则连接';
    if (this.settings.routeMode === ROUTE_GLOBAL) {
      mode = '全局代理';
    } else if (this.settings.routeMode === ROUTE_DIRECT) {
      mode = '全部直连';
    }
    const selection = this.settings.selectionMode === SELECT_MANUAL ? '固定节点' : '自动选择';
    return `当前模式：${mode} · ${selection}`;
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

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_primary'))
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  @Builder
  Explain(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      .width('100%')
      .margin({ top: 4 })
  }

  @Builder
  ActionChip(action: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.newAction === action ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('sys.color.ohos_id_color_text_secondary'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(13)
      .backgroundColor(this.newAction === action ? $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_button_normal'))
      .onClick(() => {
        this.newAction = action;
        this.formError = '';
      })
  }

  @Builder
  RuleRow(rule: UserRule) {
    Row() {
      Column() {
        Text(rule.domain)
          .fontSize(14)
          .fontColor(rule.enabled ? $r('sys.color.ohos_id_color_text_primary') : $r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.actionLabel(rule)} · ${this.settings.routeMode === ROUTE_DIRECT ? '当前模式暂停' : this.applied ? (rule.enabled ? '已载入' : '已停用') : (rule.enabled ? '待应用' : '停用待应用')}`)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
        .selectedColor($r('sys.color.ohos_id_color_text_primary_activated'))
        .onChange((isOn: boolean) => {
          this.toggleRule(rule, isOn);
        })

      Text('删除')
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_warning'))
        .margin({ left: 12 })
        .onClick(() => {
          this.confirmRemove(rule);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  @Builder
  RouteLine(label: string, destination: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(15).layoutWeight(1)
      Text(destination).fontSize(14).fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }.width('100%').constraintSize({ minHeight: 52 })
  }

  @Builder
  Overview() {
    Column({ space: 12 }) {
        Text('连接规则').fontSize(22).fontWeight(FontWeight.Bold).width('100%')
        Column() {
          this.RouteLine('需要代理的网站', '所选单通道节点')
          Divider()
          this.RouteLine('国内与局域网', '直连')
        }.width('100%')
        if (this.settings.routeMode !== ROUTE_RULE) {
          this.Explain(this.settings.routeMode === ROUTE_GLOBAL ? '当前全局代理：国内网站也走通用线路。' : '当前全部直连：以上分流和自定义规则暂停使用。')
        }
        Column({ space: 6 }) {
          Text('App 指定节点').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
          this.Explain('按原生 App 身份选择实际节点；这与下面按域名匹配的规则独立。保存后下次重新连接生效。')
          Button('管理 App 指定节点').width('100%').onClick(() => { router.pushUrl({ url: 'pages/AppRoutes' }); })
        }.width('100%').padding(14).borderRadius(16).backgroundColor($r('sys.color.ohos_id_color_component_normal'))
        Row({ space: 8 }) {
          Text('我的规则').fontSize(18).fontWeight(FontWeight.Medium)
          Text(`${this.rules.length}`).fontSize(14).fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }.width('100%').margin({ top: 16 })
        if (this.rules.length === 0) { this.Explain('当前没有自定义规则') }
        ForEach(this.rules, (rule: UserRule) => { this.RuleRow(rule) }, (rule: UserRule) => `${rule.id}|${rule.enabled}`)
        if (this.feedback.length > 0) { this.Explain(this.feedback) }
        if (!this.applied && this.feedback.length > 0) {
          Button('应用到连接').enabled(!this.busy).onClick(() => { this.reconnectNow(); })
          this.Explain('应用时会重新连接。')
        }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  Editor() {
    Column({ space: 12 }) {
        Text('添加规则').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        TextInput({ placeholder: '输入域名', text: this.newDomain }).fontSize(16)
          .onChange((value: string) => { this.newDomain = value; this.formError = ''; this.onInteraction(); })
        Row({ space: 8 }) {
          Button('直连').buttonStyle(this.newAction === USER_RULE_ACTION_DIRECT ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
            .layoutWeight(1).onClick(() => { this.newAction = USER_RULE_ACTION_DIRECT; })
          Button('当前代理').buttonStyle(this.newAction === USER_RULE_ACTION_PROXY ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
            .layoutWeight(1).onClick(() => { this.newAction = USER_RULE_ACTION_PROXY; })
        }.width('100%')
        if (this.formError.length > 0) {
          Text(this.formError).fontSize(14).fontColor($r('sys.color.ohos_id_color_warning')).width('100%')
        }
        Button('保存规则').width('100%').enabled(this.newDomain.trim().length > 0 && !this.busy)
          .onClick(() => { this.addRule(); })
        this.Explain('域名及子域名都匹配。保存后需应用到连接。')
        Button(this.advanced ? '收起规则说明' : '正则表达式说明').buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick(() => { this.advanced = !this.advanced; })
        if (this.advanced) {
          this.Explain('支持以 regexp: 开头的正则表达式。规则可选择直连、当前代理或指定节点组；指定节点组规则在双通道连接时生效。')
        }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  Content() {
    Scroll(this.contentScroller) {
      GridRow({ columns: 12, gutter: { x: 24, y: 24 } }) {
        GridCol({ span: this.panelWidth >= 640 ? 6 : 12 }) { this.Overview() }
        GridCol({ span: this.panelWidth >= 640 ? 6 : 12 }) { this.Editor() }
      }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 24 })
    }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      .onAreaChange((_old: Area, current: Area) => { this.panelWidth = Number(current.width); })
  }

  build() {
    Column() {
      if (this.embedded) { this.Content() }
      else { NativePage({ title: '规则', rootPage: false }) { this.Content() } }
    }.width('100%').height('100%')
  }
}
