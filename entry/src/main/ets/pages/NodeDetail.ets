import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 节点详情页：基本 / 传输 / 安全分组展示。
// 敏感字段（UUID / 密码 / 密钥）默认打码、逐字段可切换显示；
// 服务器地址经 NodeStore.maskEndpointAddress 脱敏，可切换显示。
// 复制 rawLink 走 pasteboard.setData（写剪贴板无需权限），并提示内容含凭据。
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { NodeStore, SOURCE_IMPORT, SOURCE_MANUAL, StoredNode } from '../services/NodeStore';
import { NodeDetailField, NodeDetailSection, buildNodeDetailSections } from '../services/NodeDetailFields';
import { SubscriptionStore } from '../services/SubscriptionStore';
import { formatDate } from '../services/UiFormat';

const MASKED_VALUE: string = '••••••••';

@Entry
@Component
export struct NodeDetail {
  @Prop nodeId: string = '';
  @Prop embedded: boolean = false;
  @State node: StoredNode | null = null;
  @State notFound: boolean = false;
  @State revealed: Array<string> = [];
  @State showEndpoint: boolean = false;
  @State sourceName: string = '';
  private context: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    let id = this.nodeId;
    const params = router.getParams();
    if (id.length === 0 && params !== undefined && params !== null && typeof params === 'object') {
      const record = params as Record<string, Object>;
      const value = record['id'];
      if (typeof value === 'string') {
        id = value;
      }
    }
    const nodes = NodeStore.loadNodes(ctx);
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) {
        this.node = nodes[i];
        this.sourceName = this.describeSource(nodes[i]);
        return;
      }
    }
    this.notFound = true;
  }

  private describeSource(node: StoredNode): string {
    if (node.sourceId === SOURCE_MANUAL) {
      return '手动添加';
    }
    if (node.sourceId === SOURCE_IMPORT) {
      return '链接导入';
    }
    const ctx = this.context;
    if (ctx !== null) {
      const sub = SubscriptionStore.findById(ctx, node.sourceId);
      if (sub !== null) {
        return `订阅：${sub.name}`;
      }
    }
    return '订阅（已删除）';
  }

  private fieldKey(sectionIndex: number, fieldIndex: number): string {
    return `${sectionIndex}-${fieldIndex}`;
  }

  private isRevealed(sectionIndex: number, fieldIndex: number): boolean {
    return this.revealed.indexOf(this.fieldKey(sectionIndex, fieldIndex)) >= 0;
  }

  private toggleReveal(sectionIndex: number, fieldIndex: number): void {
    const key = this.fieldKey(sectionIndex, fieldIndex);
    const next = this.revealed.filter((item: string) => item !== key);
    if (this.revealed.indexOf(key) < 0) {
      next.push(key);
    }
    this.revealed = next;
  }

  private endpointText(node: StoredNode): string {
    if (this.showEndpoint) {
      return `${node.server}:${node.port}`;
    }
    return `${NodeStore.maskEndpointAddress(node.server)}:${node.port}`;
  }

  private async copyRawLink(): Promise<void> {
    const node = this.node;
    if (node === null || node.rawLink.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createPlainTextData(node.rawLink);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '已复制分享链接（含凭据，注意保管）' });
    } catch (error) {
      promptAction.showToast({ message: '复制失败' });
    }
  }


  @Builder
  FieldRow(sectionIndex: number, fieldIndex: number, field: NodeDetailField) {
    Row() {
      Text(field.label)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width(96)
      Text(field.sensitive && !this.isRevealed(sectionIndex, fieldIndex) ? MASKED_VALUE : field.value)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (field.sensitive) {
        Text(this.isRevealed(sectionIndex, fieldIndex) ? '隐藏' : '显示')
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .padding({ left: 8, right: 4, top: 4, bottom: 4 })
          .onClick(() => {
            this.toggleReveal(sectionIndex, fieldIndex);
          })
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  SectionView(sectionIndex: number, section: NodeDetailSection) {
    Column({ space: 4 }) {
      Text(section.title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ bottom: 4 })
      ForEach(section.fields, (field: NodeDetailField, fieldIndex: number) => {
        this.FieldRow(sectionIndex, fieldIndex, field)
      }, (field: NodeDetailField, fieldIndex: number) => `${sectionIndex}-${fieldIndex}-${field.label}`)
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  @Builder
  DetailBody() {
    Column() {


      Scroll() {
        Column({ space: 12 }) {
          if (this.notFound) {
            Text('节点不存在或已被删除。')
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_warning'))
              .width('100%')
              .margin({ top: 20 })
          } else if (this.node !== null) {
            Text('以下展示导入的原始参数。本版实际连接默认校验证书，不会自动采用“跳过校验”。')
              .fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
            Column({ space: 6 }) {
              Text(NodeStore.displayName(this.node))
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
                .width('100%')
              Text(`${this.node.region} · ${this.node.protocol.toUpperCase()}`)
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .width('100%')

              Row() {
                Text('服务器')
                  .fontSize(13)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  .width(96)
                Text(this.endpointText(this.node))
                  .fontSize(13)
                  .fontColor($r('sys.color.ohos_id_color_text_primary'))
                  .layoutWeight(1)
                Text(this.showEndpoint ? '隐藏' : '显示')
                  .fontSize(12)
                  .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
                  .padding({ left: 8, right: 4, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.showEndpoint = !this.showEndpoint;
                  })
              }
              .width('100%')
              .margin({ top: 8 })

              Text(`来源：${this.sourceName}`)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .width('100%')
                .margin({ top: 4 })
              Text(`添加时间：${formatDate(this.node.addedAt)}`)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .width('100%')
                .margin({ top: 2 })
              Text(`最近测速：${this.node.latencyText.length > 0 ? this.node.latencyText : '未测速'}`)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .width('100%')
                .margin({ top: 2 })
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor($r('sys.color.comp_background_primary'))

            ForEach(buildNodeDetailSections(this.node.outboundJson, this.node.protocol),
              (section: NodeDetailSection, sectionIndex: number) => {
                this.SectionView(sectionIndex, section)
              }, (section: NodeDetailSection, sectionIndex: number) => `section-${sectionIndex}-${section.title}`)

            if (this.node.rawLink.length > 0) {
              Column({ space: 8 }) {
                Button('复制分享链接')
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                  .backgroundColor($r('sys.color.ohos_id_color_text_primary'))
                  .borderRadius(18)
                  .constraintSize({ minHeight: 48 })
                  .width('100%')
                  .onClick(() => {
                    this.copyRawLink();
                  })
                Text('复制内容含凭据，请只发给可信的人。')
                  .fontSize(12)
                  .fontColor($r('sys.color.ohos_id_color_warning'))
                  .width('100%')
              }
              .width('100%')
              .padding(14)
              .borderRadius(16)
              .backgroundColor($r('sys.color.comp_background_primary'))
            }
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }

  build() {
    Column() {
      if (this.embedded) { this.DetailBody() }
      else { NativePage({ title: '节点详情' }) { this.DetailBody() } }
    }.width('100%').height('100%')
  }
}
