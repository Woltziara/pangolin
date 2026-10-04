import { SHARED_HOST_GUIDANCE } from '../services/AppRouteCapability';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { NativePage } from '../components/NativePage';
import { AppRoute, AppRoutingConfig, ObservedApp } from '../core/AppRouteModel';
import { AppCatalog } from '../services/AppCatalog';
import { AppRouteStore } from '../services/AppRouteStore';
import { NodeStore, StoredNode } from '../services/NodeStore';

interface AppRouteSheet {
  title: string;
  action: () => void;
}

/**
 * Policy editor only. Saving marks the next connection as needing this
 * snapshot; it never starts, stops, or restarts a VPN itself.
 */
@Entry
@Component
export struct AppRoutes {
  @State config: AppRoutingConfig = new AppRoutingConfig();
  @State nodes: StoredNode[] = [];
  @State observed: ObservedApp[] = [];
  @State feedback: string = '';
  @State editingId: string = '';
  @State formBundle: string = '';
  @State formLabel: string = '';
  @State formNodeId: string = '';
  @State formError: string = '';
  @State resolving: boolean = false;
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
    if (ctx === null) { return; }
    try {
      this.config = AppRouteStore.load(ctx);
      this.nodes = NodeStore.loadNodes(ctx);
      this.observed = AppCatalog.observed(ctx);
    } catch (error) {
      this.feedback = error instanceof Error ? error.message : '无法读取 App 指定节点设置';
    }
  }

  private pending(): void {
    this.reload();
    this.feedback = '已保存；将在下次重新连接时应用。当前连接没有被重启。';
  }

  private switchEnabled(value: boolean): void {
    const ctx = this.context;
    if (ctx === null) { return; }
    try {
      AppRouteStore.setEnabled(ctx, value);
      this.pending();
    } catch (error) {
      this.feedback = error instanceof Error ? error.message : '保存失败';
    }
  }

  private startAdd(): void {
    this.editingId = '';
    this.formBundle = '';
    this.formLabel = '';
    this.formNodeId = '';
    this.formError = '';
  }

  private edit(route: AppRoute): void {
    this.editingId = route.id;
    this.formBundle = route.bundleName;
    this.formLabel = route.label;
    this.formNodeId = route.nodeId;
    this.formError = '';
  }

  private pickObserved(): void {
    if (this.observed.length === 0) {
      this.formError = '还没有已识别 App。请先开启本页开关并重新连接 VPN，再打开目标 App 联网，返回本页选择；也可以手动填写包名确认。';
      return;
    }
    const sheets: AppRouteSheet[] = [];
    for (let i = 0; i < this.observed.length; i++) {
      const app = this.observed[i];
      const sheet: AppRouteSheet = { title: `${app.label} · ${app.bundleName}`, action: () => {
        this.formBundle = app.bundleName;
        this.formLabel = app.label;
        this.formError = '';
      } };
      sheets.push(sheet);
    }
    ActionSheet.show({ title: '选择已识别的联网 App', message: '仅列出本机 VPN 已识别的 App', sheets });
  }

  private pickNode(): void {
    if (this.nodes.length === 0) {
      this.formError = '没有可选择的节点；请先在节点页添加实际节点。';
      return;
    }
    const sheets: AppRouteSheet[] = [];
    for (let i = 0; i < this.nodes.length; i++) {
      const node = this.nodes[i];
      const sheet: AppRouteSheet = { title: `${NodeStore.displayName(node)} · ${node.region}`, action: () => {
        this.formNodeId = node.id;
        this.formError = '';
      } };
      sheets.push(sheet);
    }
    ActionSheet.show({ title: '选择实际节点', message: '此 App 的新连接将使用所选节点', sheets });
  }

  private nodeName(id: string): string {
    for (let i = 0; i < this.nodes.length; i++) {
      if (this.nodes[i].id === id) { return NodeStore.displayName(this.nodes[i]); }
    }
    return id.length === 0 ? '未选择' : '节点已不存在';
  }

  private appState(route: AppRoute): string {
    for (let i = 0; i < this.observed.length; i++) {
      if (this.observed[i].bundleName === route.bundleName) {
        return this.nodeName(route.nodeId) === '节点已不存在' ? '节点缺失' : (route.enabled ? '下次重连生效' : '本规则已停用');
      }
    }
    return 'App 未在本机观察记录中；连接前会重新确认';
  }

  private async confirmBundle(): Promise<void> {
    if (this.resolving) { return; }
    this.resolving = true;
    this.formError = '';
    try {
      const app = await AppCatalog.resolve(this.formBundle);
      this.formBundle = app.bundleName;
      this.formLabel = app.label;
      promptAction.showToast({ message: `已确认 ${app.label}（UID ${app.uid}）` });
    } catch (error) {
      this.formError = error instanceof Error ? error.message : '无法确认包名';
    } finally {
      this.resolving = false;
    }
  }

  private saveRule(): void {
    const ctx = this.context;
    if (ctx === null) { return; }
    if (this.formLabel.trim().length === 0) {
      this.formError = '请先确认包名，或从已识别 App 选择。';
      return;
    }
    if (this.formNodeId.length === 0 || this.nodeName(this.formNodeId) === '节点已不存在') {
      this.formError = '请选择一个仍存在的实际节点。';
      return;
    }
    const route = new AppRoute();
    route.id = this.editingId.length > 0 ? this.editingId : `app-${Date.now()}`;
    route.bundleName = this.formBundle.trim();
    route.label = this.formLabel.trim();
    route.nodeId = this.formNodeId;
    route.enabled = true;
    route.createdAt = Date.now();
    route.updatedAt = route.createdAt;
    try {
      AppRouteStore.upsert(ctx, route);
      this.startAdd();
      this.pending();
    } catch (error) {
      this.formError = error instanceof Error ? error.message : '保存规则失败';
    }
  }

  private remove(route: AppRoute): void {
    const ctx = this.context;
    if (ctx === null) { return; }
    AlertDialog.show({ title: '删除 App 指定节点？', message: `${route.label} 将回到默认线路。`,
      primaryButton: { value: '删除', fontColor: $r('sys.color.ohos_id_color_warning'), action: () => {
        AppRouteStore.remove(ctx, route.id); this.pending();
      } }, secondaryButton: { value: '取消', action: () => {} } });
  }

  @Builder
  private Form(): void {
    Column({ space: 10 }) {
      Text(this.editingId.length > 0 ? '编辑规则' : '添加 App 指定节点').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ text: this.formBundle, placeholder: '包名，例如 com.example.app' })
        .onChange((value: string) => { this.formBundle = value; this.formLabel = ''; })
      Row({ space: 8 }) {
        Button('从已识别 App 选择').layoutWeight(1).onClick(() => { this.pickObserved(); })
        Button(this.resolving ? '确认中…' : '确认包名').layoutWeight(1).enabled(!this.resolving).onClick(() => { this.confirmBundle(); })
      }
      Text(this.formLabel.length > 0 ? `已确认：${this.formLabel}` : '填写包名后点“确认应用”。')
        .fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
      Button(`目标节点：${this.nodeName(this.formNodeId)}`).width('100%').onClick(() => { this.pickNode(); })
      if (this.formError.length > 0) { Text(this.formError).fontSize(12).fontColor($r('sys.color.ohos_id_color_warning')).width('100%') }
      Row({ space: 8 }) {
        Button('取消').layoutWeight(1).onClick(() => { this.startAdd(); })
        Button('保存（下次重连生效）').layoutWeight(1).onClick(() => { this.saveRule(); })
      }
    }.width('100%').padding(16).borderRadius(16).backgroundColor($r('sys.color.ohos_id_color_component_normal'))
  }

  @Builder
  private Content(): void {
    Scroll() {
      Column({ space: 14 }) {
        Text('为已确认的原生 App 指定节点；未指定的 App 继续使用默认单/双通道。').fontSize(14).width('100%')
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        Row() {
          Text('启用 App 指定节点').fontSize(16).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.config.enabled })
            .onChange((value: boolean) => { this.switchEnabled(value); })
        }.width('100%').padding(12).borderRadius(12).backgroundColor($r('sys.color.ohos_id_color_component_normal'))
        Text('找不到目标 App？先打开它联网，再回这里从“已识别 App”选择。出境易里的应用共用一条线路，不能分别选节点；全部直连模式下 App 分流暂不生效。')
          .fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
        if (this.feedback.length > 0) { Text(this.feedback).fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%') }
        this.Form()
        Text('现有规则').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        if (this.config.rules.length === 0) { Text('还没有规则。添加后保存，再回首页应用并连接。').fontSize(14).width('100%').fontColor($r('sys.color.ohos_id_color_text_secondary')) }
        ForEach(this.config.rules, (route: AppRoute) => {
          Column({ space: 6 }) {
            Row() {
              Column() { Text(route.label).fontSize(16).fontWeight(FontWeight.Medium).width('100%'); Text(route.bundleName).fontSize(12).width('100%').fontColor($r('sys.color.ohos_id_color_text_secondary')) }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: route.enabled }).onChange((value: boolean) => { const next = route; next.enabled = value; const ctx = this.context; if (ctx !== null) { try { AppRouteStore.upsert(ctx, next); this.pending(); } catch (error) { this.feedback = error instanceof Error ? error.message : '保存失败'; } } })
            }.width('100%')
            Text(`节点：${this.nodeName(route.nodeId)} · ${this.appState(route)}`).fontSize(13).width('100%').fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Row({ space: 8 }) { Button('编辑').layoutWeight(1).onClick(() => { this.edit(route); }); Button('删除').layoutWeight(1).onClick(() => { this.remove(route); }) }
          }.width('100%').padding(16).borderRadius(16).backgroundColor($r('sys.color.ohos_id_color_component_normal'))
        }, (route: AppRoute) => route.id)
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%')
  }

  build() {
    Column() {
          Text(SHARED_HOST_GUIDANCE).fontSize(13)
          Text('保存后回首页点“应用并连接”，让新规则生效。').fontSize(13)
      NativePage({ title: 'App 指定节点', rootPage: false }) { this.Content(); }
    }.width('100%').height('100%')
  }
}
