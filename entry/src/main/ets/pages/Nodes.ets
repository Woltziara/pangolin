import { SettingsStore, SELECT_AUTO } from '../services/SettingsStore';
import { CONNECTION_POLICY } from '../services/ConnectionPolicy';
import { StatusStore } from '../services/StatusStore';
import { HdsListItemCard, SuffixArrow } from '@kit.UIDesignKit';
import { NodeDetail } from './NodeDetail';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 节点管理页：搜索 / 排序 / 分组筛选 / 收藏 / 重命名 / 分组 / 删除 / 详情。
// 行操作走长按菜单（bindMenu），所有变更经 NodeStore 落盘 nodes.json（NodeCatalog 可读）。
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { NodeStore, StoredNode } from '../services/NodeStore';
import { NODE_LATENCY_TEST, NODE_LATENCY_FILE, NodeLatencyBatch } from '../services/NodeLatencyTest';

type SortKey = 'region' | 'latency' | 'favorite';

@CustomDialog
struct TextEditDialog {
  controller?: CustomDialogController;
  title: string = '';
  initial: string = '';
  placeholder: string = '';
  onDone: (value: string) => void = () => {
  };
  @State value: string = '';

  aboutToAppear(): void {
    this.value = this.initial;
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')

      TextInput({ text: this.value, placeholder: this.placeholder })
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

@CustomDialog
struct GroupPickDialog {
  controller?: CustomDialogController;
  groups: Array<string> = [];
  current: string = '';
  onPick: (group: string) => void = () => {
  };
  @State newGroup: string = '';

  build() {
    Column({ space: 14 }) {
      Text('设置分组')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')

      if (this.groups.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.groups, (group: string) => {
            Text(group)
              .fontSize(13)
              .fontColor(group === this.current ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('sys.color.ohos_id_color_text_secondary'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8, bottom: 8 })
              .borderRadius(14)
              .backgroundColor(group === this.current ? $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_button_normal'))
              .onClick(() => {
                this.onPick(group);
                this.controller?.close();
              })
          }, (group: string) => group)
        }
        .width('100%')
      }

      TextInput({ placeholder: '新分组名称', text: this.newGroup })
        .constraintSize({ minHeight: 48 })
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
        .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
        .borderRadius(8)
        .onChange((value: string) => {
          this.newGroup = value;
        })

      Row({ space: 12 }) {
        Button('清除分组')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .borderRadius(18)
          .constraintSize({ minHeight: 48 })
          .layoutWeight(1)
          .onClick(() => {
            this.onPick('');
            this.controller?.close();
          })
        Button('新建并加入')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .backgroundColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .borderRadius(18)
          .constraintSize({ minHeight: 48 })
          .layoutWeight(1)
          .enabled(this.newGroup.trim().length > 0)
          .onClick(() => {
            this.onPick(this.newGroup.trim());
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
export struct Nodes {
  @Prop embedded: boolean = false;
  @Prop @Watch('reload') revision: number = 0;
  onRoleChange: () => void = () => {};
  onInteraction: () => void = () => {};
  @State selectedId: string = '';
  @State chatgptName: string = '';
  @State dualChannel: boolean = false;
  @State singleName: string = '';
  @State generalName: string = '';
  private nodeScroller: Scroller = new Scroller();
  private detailStack: NavPathStack = new NavPathStack();
  @State nodes: Array<StoredNode> = [];
  @State search: string = '';
  @State sortKey: SortKey = 'region';
  @State groupFilter: string = '';
  @State testingLatency: boolean = false;
  @State latencyMessage: string = '';
  private context: common.UIAbilityContext | null = null;
  private renameController: CustomDialogController | null = null;
  private groupController: CustomDialogController | null = null;

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
    this.nodes = NodeStore.loadNodes(ctx);
    const settings = SettingsStore.load(ctx);
    const meta = StatusStore.readNodeMeta(ctx);
    this.chatgptName = this.nodes.find((n: StoredNode) => n.id === settings.chatgptNodeId)?.name ?? meta.usName;
    this.dualChannel = CONNECTION_POLICY.mode(ctx) === 'dual';
    this.singleName = this.nodes.find((n: StoredNode) => n.id === settings.singleNodeId)?.name ?? meta.name;
    this.generalName = this.nodes.find((n: StoredNode) => n.id === settings.generalNodeId)?.name ?? meta.ytName;
  }

  private async testNodeLatency(): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.testingLatency || this.nodes.length === 0) { return; }
    this.testingLatency = true;
    this.latencyMessage = '正在测节点延时…';
    this.onInteraction();
    try {
      const runId = await NODE_LATENCY_TEST.begin(ctx);
      const applied = new Set<string>();
      const started = Date.now();
      while (Date.now() - started < 90000) {
        const raw = StatusStore.readText(ctx, NODE_LATENCY_FILE);
        if (raw.length > 0) {
          const result = JSON.parse(raw) as NodeLatencyBatch;
          if (result.runId === runId) {
            for (let i = 0; i < result.samples.length; i++) {
              const sample = result.samples[i];
              if (!applied.has(sample.id)) {
                NodeStore.updateLatency(ctx, sample.id, sample.milliseconds, sample.text);
                applied.add(sample.id);
              }
            }
            this.reload();
            this.latencyMessage = `节点 TCP 延时 · ${result.samples.length}/${result.total}`;
            if (result.complete) {
              if (result.outcome !== 'measured') { this.latencyMessage = '测试已中止，可重新测延时。'; }
              return;
            }
          }
        }
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 500); });
      }
      this.latencyMessage = '测试未完成，请稍后重试。';
    } catch (error) {
      this.latencyMessage = '暂时无法测延时，请稍后重试。';
    } finally {
      this.testingLatency = false;
    }
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

  private visibleNodes(): Array<StoredNode> {
    const query = this.search.trim().toLowerCase();
    let list: Array<StoredNode> = [];
    for (let i = 0; i < this.nodes.length; i++) {
      const node = this.nodes[i];
      if (this.groupFilter.length > 0 && node.group !== this.groupFilter) {
        continue;
      }
      if (query.length > 0) {
        const haystack = `${node.name} ${node.customName} ${node.server}`.toLowerCase();
        if (haystack.indexOf(query) < 0) {
          continue;
        }
      }
      list.push(node);
    }
    if (this.sortKey === 'latency') {
      list = NodeStore.sortByLatency(list);
    } else if (this.sortKey === 'favorite') {
      list = NodeStore.sortFavoriteFirst(list);
    } else {
      list = list.slice();
      list.sort((a: StoredNode, b: StoredNode): number => {
        const aUsed = a.name === this.chatgptName || a.name === this.generalName;
        const bUsed = b.name === this.chatgptName || b.name === this.generalName;
        if (aUsed !== bUsed) { return aUsed ? -1 : 1; }
        if (a.region !== b.region) {
          return a.region < b.region ? -1 : 1;
        }
        const an = NodeStore.displayName(a);
        const bn = NodeStore.displayName(b);
        if (an === bn) {
          return 0;
        }
        return an < bn ? -1 : 1;
      });
    }
    return list;
  }

  private toggleFavorite(node: StoredNode): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    NodeStore.toggleFavorite(ctx, node.id);
    this.reload();
  }

  private openRename(node: StoredNode): void {
    this.renameController = new CustomDialogController({
      builder: TextEditDialog({
        title: '重命名节点',
        initial: NodeStore.displayName(node),
        placeholder: '留空则恢复原始名称',
        onDone: (value: string) => {
          const ctx = this.context;
          if (ctx === null) {
            return;
          }
          NodeStore.rename(ctx, node.id, value);
          this.reload();
        }
      }),
      customStyle: true
    });
    this.renameController.open();
  }

  private openGroup(node: StoredNode): void {
    this.groupController = new CustomDialogController({
      builder: GroupPickDialog({
        groups: this.existingGroups(),
        current: node.group,
        onPick: (group: string) => {
          const ctx = this.context;
          if (ctx === null) {
            return;
          }
          NodeStore.setGroup(ctx, node.id, group);
          this.reload();
        }
      }),
      customStyle: true
    });
    this.groupController.open();
  }

  private confirmDelete(node: StoredNode): void {
    AlertDialog.show({
      title: '删除节点',
      message: `确定删除「${NodeStore.displayName(node)}」吗？`,
      primaryButton: {
        value: '删除',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          const ctx = this.context;
          if (ctx === null) {
            return;
          }
          NodeStore.removeNodes(ctx, [node.id]);
          this.reload();
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private openDetail(node: StoredNode): void {
    router.pushUrl({ url: 'pages/NodeDetail', params: { id: node.id } });
  }

  private sortLabel(): string {
    if (this.sortKey === 'latency') {
      return '按延迟';
    }
    if (this.sortKey === 'favorite') {
      return '按收藏';
    }
    return '按地区';
  }

  private cycleSort(): void {
    if (this.sortKey === 'region') {
      this.sortKey = 'latency';
    } else if (this.sortKey === 'latency') {
      this.sortKey = 'favorite';
    } else {
      this.sortKey = 'region';
    }
  }

  private latencyColor(text: string): ResourceColor {
    if (text === '超时' || text === '失败' || text === '无 IPv4') {
      return $r('sys.color.ohos_id_color_warning');
    }
    return $r('sys.color.ohos_id_color_text_primary_activated');
  }


  @Builder
  GroupChips() {
    Scroll() {
      Row() {
        Text('全部')
          .fontSize(12)
          .fontColor(this.groupFilter.length === 0 ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('sys.color.ohos_id_color_text_secondary'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .margin({ right: 8 })
          .borderRadius(13)
          .backgroundColor(this.groupFilter.length === 0 ? $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_button_normal'))
          .onClick(() => {
            this.groupFilter = '';
          })
        ForEach(this.existingGroups(), (group: string) => {
          Text(group)
            .fontSize(12)
            .fontColor(this.groupFilter === group ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('sys.color.ohos_id_color_text_secondary'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ right: 8 })
            .borderRadius(13)
            .backgroundColor(this.groupFilter === group ? $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_button_normal'))
            .onClick(() => {
              this.groupFilter = this.groupFilter === group ? '' : group;
            })
        }, (group: string) => group)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: 10 })
  }

  private shortName(node: StoredNode): string {
    return NodeStore.displayName(node).replace('-PRO-', ' · ').replace(/-流量倍率:[0-9.]+$/, '');
  }

  private multiplier(node: StoredNode): string {
    const match = /流量倍率:([0-9.]+)/.exec(node.name);
    return match !== null ? `流量 ×${match[1]}` : '';
  }

  private roles(node: StoredNode): string {
    if (!this.dualChannel) { return node.name === this.singleName ? '单通道选择' : ''; }
    const labels: string[] = [];
    if (node.name === this.chatgptName) { labels.push('ChatGPT'); }
    if (node.name === this.generalName) { labels.push('通用'); }
    return labels.join(' · ');
  }

  private selected(): StoredNode | null {
    return this.nodes.find((node: StoredNode) => node.id === this.selectedId) ?? null;
  }

  private assignRole(chatgpt: boolean): void {
    if (this.context === null || this.selectedId.length === 0) { return; }
    SettingsStore.update(this.context, (settings) => {
      if (!this.dualChannel) { settings.singleNodeId = this.selectedId; return; }
      settings.selectionMode = SELECT_AUTO;
      settings.manualNodeId = '';
      if (chatgpt) { settings.chatgptNodeId = this.selectedId; }
      else { settings.generalNodeId = this.selectedId; }
    });
    this.reload();
    this.onRoleChange();
  }

  @Builder
  NodeRow(node: StoredNode) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.shortName(node)).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          if (this.roles(node).length > 0) {
            Text(this.roles(node)).fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
          }
          if (node.favorite) { Text('已收藏').fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary')) }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Column({ space: 4 }) {
          if (node.latencyText.length > 0) {
            Text(node.latencyText).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.latencyColor(node.latencyText))
          }
          if (this.multiplier(node).length > 0) {
            Text(this.multiplier(node)).fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary'))
          }
        }.alignItems(HorizontalAlign.End)
      }.width('100%').padding({ left: 12, right: 12, top: 16, bottom: 16 })
    }.width('100%').borderRadius(12)
      .backgroundColor(this.selectedId === node.id ? $r('sys.color.ohos_id_color_component_normal') : Color.Transparent)
      .onClick(() => { this.selectedId = node.id; this.onInteraction(); })
  }

  @Builder
  Content() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('节点').fontSize(22).fontWeight(FontWeight.Bold)
        Text(`${this.nodes.length}`).fontSize(16).fontColor($r('sys.color.ohos_id_color_text_secondary'))
        Blank()
        Button(this.testingLatency ? '测试中' : '测延时').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(13)
          .enabled(!this.testingLatency && this.nodes.length > 0)
          .onClick(() => { this.testNodeLatency(); })
        Button(this.sortLabel()).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(13)
          .onClick(() => { this.cycleSort(); })
        Button('添加').buttonStyle(ButtonStyleMode.TEXTUAL).bindMenu([
          { value: '导入节点', action: () => { router.pushUrl({ url: 'pages/Import' }); } },
          { value: '订阅管理', action: () => { router.pushUrl({ url: 'pages/Subscriptions' }); } }
        ])
      }.width('100%')
      if (this.latencyMessage.length > 0) {
        Text(this.latencyMessage).fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
      }
      Search({ placeholder: '搜索节点', value: this.search })
        .onChange((value: string) => { this.search = value; this.onInteraction(); })
      if (this.existingGroups().length > 0) { this.GroupChips() }
      if (this.nodes.length === 0) {
        Text('还没有节点，先添加节点或订阅。').fontSize(15).width('100%')
      } else if (this.visibleNodes().length === 0) {
        Text('没有符合筛选条件的节点。').fontSize(15).width('100%')
      }
      List({ space: 0, scroller: this.nodeScroller }) {
        ForEach(this.visibleNodes(), (node: StoredNode) => {
          ListItem() { this.NodeRow(node) }
        }, (node: StoredNode) => `${node.id}:${node.latencyText}`)
      }.lanes({ minLength: 280, maxLength: 520 }, 16)
        .divider({ strokeWidth: 0.5, color: $r('sys.color.ohos_id_color_list_separator'), startMargin: 12, endMargin: 12 })
        .width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      if (this.selected() !== null) {
        Divider()
        Text(this.shortName(this.selected()!)).fontSize(14).width('100%').maxLines(2)
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.dualChannel) {
            Button('用于 ChatGPT').fontSize(14).margin({ right: 8, bottom: 8 })
              .onClick(() => { this.assignRole(true); })
          }
          Button(this.dualChannel ? '用于通用' : '用于单通道').fontSize(14).margin({ right: 8, bottom: 8 })
            .onClick(() => { this.assignRole(false); })
          Button('更多').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14)
            .bindMenu([
              { value: '高级详情', action: () => { if (this.selected() !== null) { this.openDetail(this.selected()!); } } },
              { value: this.selected()!.favorite ? '取消收藏' : '收藏', action: () => { if (this.selected() !== null) { this.toggleFavorite(this.selected()!); } } },
              { value: '重命名', action: () => { if (this.selected() !== null) { this.openRename(this.selected()!); } } },
              { value: '分组', action: () => { if (this.selected() !== null) { this.openGroup(this.selected()!); } } },
              { value: '删除', action: () => { if (this.selected() !== null) { this.confirmDelete(this.selected()!); } } }
            ])
        }.width('100%')
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
  }

  build() {
    Column() {
      if (this.embedded) { this.Content() }
      else {
        NativePage({ title: '节点', rootPage: false, hideTitle: false }) { this.Content() }
      }
    }.width('100%').height('100%')
  }
}
