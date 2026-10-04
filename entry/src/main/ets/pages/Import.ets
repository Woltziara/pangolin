import { publicFailure } from '../core/UserFacingCopy';
import { UiFeedback } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 导入页：扫码 / 相册二维码 / 粘贴链接 / 配置文件 / 手动添加，
// 五种来源统一走“预览确认流”（SubscriptionManager.importFromText 预览 + commitImport 落盘）。
// 扫码与相册识码交互参考 Hey (GPL-3.0) entry/src/main/ets/pages/Scanner.ets
// （取消错误码 1000500002 / 20001 静默返回），参考日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 权限说明（docs/research/hmos-api-verification.md 核实）：ScanKit 默认界面扫码无需
// CAMERA 权限；PasteButton 安全控件点击即临时授权读剪贴板；DocumentViewPicker 无需权限。
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { detectBarcode, scanBarcode, scanCore } from '@kit.ScanKit';
import { guessRegion } from '../core/RegionGuess';
import { dedupeKeyOfNode } from '../core/NodeDedupe';
import { outboundRunError, requireCertificateVerification } from '../core/OutboundReady';
import { ParsedNode, ShareLinkFailure } from '../core/ShareLinkParser';
import { NodeStore, SOURCE_IMPORT, SOURCE_MANUAL } from '../services/NodeStore';
import { CommitSummary, ImportPreview, SubscriptionManager, UpdateResult } from '../services/SubscriptionManager';
import { SubscriptionStore } from '../services/SubscriptionStore';

const MAX_CONFIG_FILE_BYTES: number = 2 * 1024 * 1024;
const MANUAL_PROTOCOLS: Array<string> = ['vless', 'vmess', 'trojan', 'ss', 'hysteria2'];
const SS_METHODS: Array<string> = ['aes-128-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305', '2022-blake3-aes-128-gcm'];

class PreviewItem {
  node: ParsedNode = new ParsedNode();
  duplicate: boolean = false;
  runError: string = '';
}

@Entry
@Component
struct Import {
  @State pasteText: string = '';
  @State lastError: string = '';
  @State busy: boolean = false;
  // 统一预览确认流状态
  @State previewVisible: boolean = false;
  @State previewKind: string = '';
  @State previewItems: Array<PreviewItem> = [];
  @State previewFailures: Array<ShareLinkFailure> = [];
  @State previewUrl: string = '';
  @State previewSourceId: string = SOURCE_IMPORT;
  // 手动添加表单
  @State manualName: string = '';
  @State manualProtocol: string = 'vless';
  @State manualHost: string = '';
  @State manualPort: string = '';
  @State manualSecret: string = '';
  @State manualMethod: string = SS_METHODS[0];
  @State manualTls: boolean = true;
  @State manualError: string = '';
  private context: common.UIAbilityContext | null = null;
  private pasteController: TextAreaController = new TextAreaController();
  private previewScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
  }

  // ---------- 来源一：扫码 ----------

  private async startCameraScan(): Promise<void> {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      };
      const result = await scanBarcode.startScanForResult(ctx, options);
      const value = result.originalValue;
      if (value !== undefined && value.trim().length > 0) {
        this.pasteText = value.trim();
        this.runTextPreview(this.pasteText);
      }
    } catch (error) {
      if (!this.isUserCancelled(error)) {
        this.lastError = UiFeedback.failure(this.context, 'scan', error, '未能打开扫码，请稍后重试。');
      }
    }
  }

  // ---------- 来源二：相册识别二维码 ----------

  private async selectAlbumQr(): Promise<void> {
    try {
      const photoOptions = new photoAccessHelper.PhotoSelectOptions();
      photoOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoOptions.maxSelectNumber = 1;
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const selected = await photoPicker.select(photoOptions);
      if (selected.photoUris.length === 0) {
        return;
      }
      const decodeOptions: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false
      };
      const results = await detectBarcode.decode({ uri: selected.photoUris[0] }, decodeOptions);
      let value = '';
      for (let i = 0; i < results.length; i++) {
        const candidate = results[i].originalValue;
        if (candidate !== undefined && candidate.trim().length > 0) {
          value = candidate.trim();
          break;
        }
      }
      if (value.length === 0) {
        this.lastError = '这张图片里没有识别到二维码。';
        return;
      }
      this.pasteText = value;
      this.runTextPreview(value);
    } catch (error) {
      if (!this.isUserCancelled(error)) {
        this.lastError = UiFeedback.failure(this.context, 'album', error, '未能识别这张图片，请换一张清晰的二维码图片。');
      }
    }
  }

  // ---------- 来源三：粘贴链接（PasteButton 安全控件） ----------

  private async readClipboardIntoForm(): Promise<void> {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (!systemPasteboard.hasDataSync()) {
        promptAction.showToast({ message: '剪贴板是空的' });
        return;
      }
      const data = await systemPasteboard.getData();
      const text = data.getPrimaryText();
      if (text !== undefined && text.trim().length > 0) {
        this.pasteText = text.trim();
        this.lastError = '';
      } else {
        promptAction.showToast({ message: '剪贴板里没有文本内容' });
      }
    } catch (error) {
      promptAction.showToast({ message: '读取剪贴板失败' });
    }
  }

  // ---------- 来源四：配置文件 ----------

  private async pickConfigFile(): Promise<void> {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['配置文件(.yaml,.yml,.json,.conf,.txt)|.yaml,.yml,.json,.conf,.txt'];
      options.maxSelectNumber = 1;
      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris = await docPicker.select(options);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const text = this.readFileText(uris[0]);
      if (text.length === 0) {
        this.lastError = '文件是空的，没有可导入的内容。';
        return;
      }
      this.pasteText = text;
      this.runTextPreview(text);
    } catch (error) {
      if (!this.isUserCancelled(error)) {
        this.lastError = UiFeedback.failure(this.context, 'file-import', error, '未能读取文件，请重新选择可访问的配置文件。');
      }
    }
  }

  private readFileText(uri: string): string {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      if (stat.size > MAX_CONFIG_FILE_BYTES) {
        this.lastError = '文件过大（超过 2MB），请改用订阅地址导入。';
        return '';
      }
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer)).trim();
    } finally {
      fileIo.closeSync(file);
    }
  }

  // ---------- 来源五：手动添加 ----------

  private manualUsesTls(): boolean {
    return this.manualProtocol === 'vless' || this.manualProtocol === 'vmess' || this.manualProtocol === 'trojan';
  }

  private validateManual(): string {
    const host = this.manualHost.trim();
    if (host.length === 0) {
      return '请填写服务器地址。';
    }
    const port = Number(this.manualPort.trim());
    if (this.manualPort.trim().length === 0 || Number.isNaN(port) || port < 1 || port > 65535 || Math.floor(port) !== port) {
      return '端口必须是 1 到 65535 之间的整数。';
    }
    if (this.manualSecret.trim().length === 0) {
      return this.manualProtocol === 'vless' || this.manualProtocol === 'vmess' ? '请填写用户 UUID。' : '请填写密码。';
    }
    return '';
  }

  private buildManualOutbound(): Record<string, Object> {
    const host = this.manualHost.trim();
    const port = Number(this.manualPort.trim());
    const secret = this.manualSecret.trim();
    const outbound: Record<string, Object> = {};
    outbound['tag'] = 'proxy';

    if (this.manualProtocol === 'vless' || this.manualProtocol === 'vmess') {
      outbound['protocol'] = this.manualProtocol;
      const user: Record<string, Object> = {};
      user['id'] = secret;
      if (this.manualProtocol === 'vless') {
        user['encryption'] = 'none';
      } else {
        user['alterId'] = 0;
        user['security'] = 'auto';
      }
      const server: Record<string, Object> = {};
      server['address'] = host;
      server['port'] = port;
      server['users'] = [user];
      const settings: Record<string, Object> = {};
      settings['vnext'] = [server];
      outbound['settings'] = settings;
      if (this.manualTls) {
        outbound['streamSettings'] = this.manualTlsStream(host);
      }
      return outbound;
    }

    if (this.manualProtocol === 'ss') {
      outbound['protocol'] = 'shadowsocks';
      const server: Record<string, Object> = {};
      server['address'] = host;
      server['port'] = port;
      server['method'] = this.manualMethod;
      server['password'] = secret;
      const settings: Record<string, Object> = {};
      settings['servers'] = [server];
      outbound['settings'] = settings;
      return outbound;
    }

    if (this.manualProtocol === 'hysteria2') {
      outbound['protocol'] = 'hysteria2';
      const server: Record<string, Object> = {};
      server['address'] = host;
      server['port'] = port;
      server['password'] = secret;
      server['security'] = 'tls';
      const settings: Record<string, Object> = {};
      settings['servers'] = [server];
      outbound['settings'] = settings;
      return outbound;
    }

    // trojan：默认 TLS。
    outbound['protocol'] = 'trojan';
    const trojanServer: Record<string, Object> = {};
    trojanServer['address'] = host;
    trojanServer['port'] = port;
    trojanServer['password'] = secret;
    const trojanSettings: Record<string, Object> = {};
    trojanSettings['servers'] = [trojanServer];
    outbound['settings'] = trojanSettings;
    if (this.manualTls) {
      outbound['streamSettings'] = this.manualTlsStream(host);
    }
    return outbound;
  }

  private manualTlsStream(host: string): Record<string, Object> {
    const tls: Record<string, Object> = {};
    tls['serverName'] = host;
    const stream: Record<string, Object> = {};
    stream['network'] = 'tcp';
    stream['security'] = 'tls';
    stream['tlsSettings'] = tls;
    return stream;
  }

  private runManualPreview(): void {
    const error = this.validateManual();
    if (error.length > 0) {
      this.manualError = error;
      return;
    }
    this.manualError = '';
    const host = this.manualHost.trim();
    const port = Number(this.manualPort.trim());
    const node = new ParsedNode();
    node.protocol = this.manualProtocol === 'ss' ? 'shadowsocks' : this.manualProtocol;
    node.name = this.manualName.trim().length > 0
      ? this.manualName.trim()
      : `${node.protocol.toUpperCase()} ${host}:${port}`;
    node.server = host;
    node.port = port;
    node.outboundJson = JSON.stringify(this.buildManualOutbound(), null, 2);
    node.rawLink = '';
    node.region = guessRegion(node.name, host);
    this.showPreview([node], [], SOURCE_MANUAL);
  }

  // ---------- 统一预览确认流 ----------

  private runTextPreview(text: string): void {
    this.pasteController.stopEditing();
    const ctx = this.context;
    if (ctx === null) {
      this.reportImportError('导入页尚未准备好，请返回后重新打开。');
      return;
    }
    this.lastError = '';
    try {
    const preview: ImportPreview = SubscriptionManager.importFromText(ctx, text);
    if (preview.kind === 'subscription-url') {
      this.previewKind = 'subscription-url';
      this.previewUrl = text.trim();
      this.previewItems = [];
      this.previewFailures = [];
      this.previewVisible = true;
      return;
    }
    if (preview.kind === 'unknown' || preview.nodes.length === 0) {
      this.previewVisible = false;
      this.reportImportError(preview.failures.length > 0
        ? `没有识别到可用节点：${preview.failures[0].reason}`
        : '内容无法识别，没有识别到任何节点，未做任何更改。');
      return;
    }
    this.showPreview(preview.nodes, preview.failures, SOURCE_IMPORT);
    } catch (error) {
      this.previewVisible = false;
      this.reportImportError(UiFeedback.failure(this.context, 'import-preview', error,
        '识别未完成，请检查链接或文件格式后重试。'));
    }
  }

  private reportImportError(message: string): void {
    this.lastError = message;
    promptAction.showToast({ message: message });
  }

  private showPreview(nodes: Array<ParsedNode>, failures: Array<ShareLinkFailure>, sourceId: string): void {
    const ctx = this.context;
    const existingKeys = new Set<string>();
    if (ctx !== null) {
      const existing = NodeStore.loadNodes(ctx);
      for (let i = 0; i < existing.length; i++) {
        const key = dedupeKeyOfNode(existing[i].protocol, existing[i].outboundJson, existing[i].rawLink);
        if (key.length > 0) {
          existingKeys.add(key);
        }
      }
    }
    const seenIncoming = new Set<string>();
    const items: Array<PreviewItem> = [];
    for (let i = 0; i < nodes.length; i++) {
      const item = new PreviewItem();
      item.node = nodes[i];
      const key = dedupeKeyOfNode(nodes[i].protocol, nodes[i].outboundJson, nodes[i].rawLink);
      item.duplicate = key.length > 0 && (existingKeys.has(key) || seenIncoming.has(key));
      item.runError = outboundRunError(requireCertificateVerification(nodes[i].outboundJson));
      if (key.length > 0) {
        seenIncoming.add(key);
      }
      items.push(item);
    }
    this.previewKind = 'nodes';
    this.previewItems = items;
    this.previewFailures = failures;
    this.previewUrl = '';
    this.previewSourceId = sourceId;
    this.previewVisible = true;
  }

  private duplicateCount(): number {
    let count = 0;
    for (let i = 0; i < this.previewItems.length; i++) {
      if (this.previewItems[i].duplicate) {
        count++;
      }
    }
    return count;
  }

  private confirmImport(): void {
    const ctx = this.context;
    if (ctx === null || this.previewItems.length === 0) {
      return;
    }
    const nodes: Array<ParsedNode> = [];
    for (let i = 0; i < this.previewItems.length; i++) {
      nodes.push(this.previewItems[i].node);
    }
    const summary: CommitSummary = SubscriptionManager.commitImport(ctx, nodes, this.previewSourceId);
    promptAction.showToast({ message: `已添加 ${summary.added} 个节点，跳过 ${summary.skippedDuplicates} 个重复` });
    router.back();
  }

  private cancelPreview(): void {
    this.previewVisible = false;
    this.previewItems = [];
    this.previewFailures = [];
    this.previewUrl = '';
  }

  @Builder
  ImportResultSheet() {
    Scroll(this.previewScroller) {
      Column({ space: 12 }) {
        Text('识别结果').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
        this.PreviewSection()
        if (this.busy) {
          Row({ space: 8 }) {
            LoadingProgress().width(24).height(24)
            Text('正在获取订阅，请稍候…').fontSize(14)
          }.width('100%')
        }
        if (this.lastError.length > 0) {
          Text(this.lastError).fontSize(14).fontColor($r('sys.color.ohos_id_color_warning')).width('100%')
        }
      }.width('100%').padding({ left: 16, right: 16, top: 32, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }

  private async addAsSubscription(): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.previewUrl.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const record = SubscriptionStore.add(ctx, '', this.previewUrl);
      const result: UpdateResult = await SubscriptionManager.updateSubscription(ctx, record.id);
      this.lastError = result.ok ? '' : publicFailure(result.message, result.message);
      promptAction.showToast({ message: result.ok ? '订阅已添加' : publicFailure(result.message, '订阅更新失败，请检查网络和订阅链接。') });
      if (result.ok) {
        router.replaceUrl({ url: 'pages/Subscriptions' });
      }
    } catch (error) {
      this.lastError = UiFeedback.failure(this.context, 'subscription-add', error, '未能添加订阅，请检查链接后重试。');
    } finally {
      this.busy = false;
    }
  }

  private isUserCancelled(error: Object): boolean {
    const record = error as Record<string, Object>;
    const code = record['code'];
    return code === 20001 || code === '20001' || code === 1000500002 || code === '1000500002';
  }

  private truncateLine(line: string): string {
    return line.length > 40 ? `${line.substring(0, 40)}…` : line;
  }

  // ---------- UI ----------


  @Builder
  MethodRow(title: string, detail: string, action: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
        Text(detail)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ top: 3 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(18)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .onClick(action)
  }

  @Builder
  ProtocolChip(value: string, current: string, onPick: (value: string) => void) {
    Text(value)
      .fontSize(13)
      .fontColor(value === current ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('sys.color.ohos_id_color_text_secondary'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(14)
      .backgroundColor(value === current ? $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_button_normal'))
      .onClick(() => {
        onPick(value);
      })
  }

  @Builder
  PreviewSection() {
    Column({ space: 10 }) {
      if (this.previewKind === 'subscription-url') {
        Text('这是一份订阅')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .width('100%')
        Text('添加后可以在“订阅”页更新节点。原始参数会保留，本版连接默认校验证书；证书不匹配时会提示错误，不会自动关闭校验。')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
        Row({ space: 12 }) {
          Button('添加为订阅')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
            .backgroundColor($r('sys.color.ohos_id_color_text_primary_activated'))
            .borderRadius(18)
            .constraintSize({ minHeight: 48 })
            .enabled(!this.busy)
            .onClick(() => {
              this.addAsSubscription();
            })
          Button('取消')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .borderRadius(18)
            .constraintSize({ minHeight: 48 })
            .onClick(() => {
              this.cancelPreview();
            })
        }
        .width('100%')
      } else {
        Text(`识别到 ${this.previewItems.length} 个节点`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')

        if (this.duplicateCount() > 0) {
          Text(`其中 ${this.duplicateCount()} 个与现有节点重复，将被跳过`)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_warning'))
            .width('100%')
        }

        ForEach(this.previewItems, (item: PreviewItem) => {
          Row() {
            Column() {
              Text(item.node.name)
                .fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${item.node.region} · ${item.node.protocol.toUpperCase()}`)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ top: 2 })
                .width('100%')
              if (item.runError.length > 0) {
                Text(item.runError)
                  .fontSize(12)
                  .fontColor($r('sys.color.ohos_id_color_warning'))
                  .margin({ top: 2 })
                  .width('100%')
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (item.runError.length > 0) {
              Text('无法连接')
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_warning'))
                .margin({ left: 8 })
            } else if (item.duplicate) {
              Text('重复')
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_warning'))
                .margin({ left: 8 })
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
        }, (item: PreviewItem, index: number) => `${index}|${item.node.name}`)

        ForEach(this.previewFailures, (failure: ShareLinkFailure, index: number) => {
          Text(`失败：${failure.reason}${failure.line.length > 0 ? `（${this.truncateLine(failure.line)}）` : ''}`)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_warning'))
            .width('100%')
        }, (failure: ShareLinkFailure, index: number) => `failure-${index}`)

        Row({ space: 12 }) {
          Button('确认添加')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
            .backgroundColor($r('sys.color.ohos_id_color_text_primary_activated'))
            .borderRadius(18)
            .constraintSize({ minHeight: 48 })
            .onClick(() => {
              this.confirmImport();
            })
          Button('取消')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .borderRadius(18)
            .constraintSize({ minHeight: 48 })
            .onClick(() => {
              this.cancelPreview();
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  build() {
    Column() {
    NativePage({ title: '导入节点', rootPage: false }) {
    Column() {


      Scroll() {
        Column({ space: 12 }) {
          this.MethodRow('扫码添加', '调用系统扫码界面，无需相机权限', () => {
            this.startCameraScan();
          })

          this.MethodRow('从相册识别二维码', '选择一张带二维码的截图', () => {
            this.selectAlbumQr();
          })

          // 粘贴链接：PasteButton 安全控件放在输入框标题行，点击即临时授权读取剪贴板。
          Column({ space: 10 }) {
            Row() {
              Text('粘贴链接')
                .fontSize(16)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
              Blank()
              PasteButton()
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(8)
                .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                  if (result === PasteButtonOnClickResult.SUCCESS) {
                    this.readClipboardIntoForm();
                  }
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            TextArea({ placeholder: '订阅地址或节点链接；支持 Trojan/VLESS/VMess（TLS）、VLESS Reality、Shadowsocks', text: this.pasteText, controller: this.pasteController })
              .height(110)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
              .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
              .borderRadius(8)
              .padding(10)
              .onChange((value: string) => {
                this.pasteText = value;
              })

            Button('识别')
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
              .backgroundColor($r('sys.color.ohos_id_color_text_primary'))
              .borderRadius(18)
              .constraintSize({ minHeight: 48 })
              .enabled(this.pasteText.trim().length > 0)
              .onClick(() => {
                this.runTextPreview(this.pasteText.trim());
              })
            if (this.lastError.length > 0) {
              Text(this.lastError).fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_warning')).width('100%')
            }
          }
          .width('100%')
          .padding(14)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_primary'))

          this.MethodRow('导入配置文件', 'Clash YAML / JSON / 多行链接，最大 2MB', () => {
            this.pickConfigFile();
          })

          // 手动添加表单
          Column({ space: 10 }) {
            Text('手动添加')
              .fontSize(16)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .width('100%')
            Text('可填写 vless / vmess / trojan / ss；Hysteria2 等可导入但当前无法连接。')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(MANUAL_PROTOCOLS, (proto: string) => {
                this.ProtocolChip(proto, this.manualProtocol, (value: string) => {
                  this.manualProtocol = value;
                })
              }, (proto: string) => proto)
            }

            TextInput({ placeholder: '名称（可选）', text: this.manualName })
              .constraintSize({ minHeight: 48 })
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
              .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
              .borderRadius(8)
              .onChange((value: string) => {
                this.manualName = value;
              })

            TextInput({ placeholder: '服务器地址', text: this.manualHost })
              .constraintSize({ minHeight: 48 })
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
              .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
              .borderRadius(8)
              .onChange((value: string) => {
                this.manualHost = value;
              })

            TextInput({ placeholder: '端口', text: this.manualPort })
              .constraintSize({ minHeight: 48 })
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
              .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
              .borderRadius(8)
              .onChange((value: string) => {
                this.manualPort = value;
              })

            TextInput({ placeholder: this.manualProtocol === 'vless' || this.manualProtocol === 'vmess' ? '用户 UUID' : '密码', text: this.manualSecret })
              .constraintSize({ minHeight: 48 })
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .placeholderColor($r('sys.color.ohos_id_color_text_tertiary'))
              .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
              .borderRadius(8)
              .onChange((value: string) => {
                this.manualSecret = value;
              })

            if (this.manualProtocol === 'ss') {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(SS_METHODS, (method: string) => {
                  this.ProtocolChip(method, this.manualMethod, (value: string) => {
                    this.manualMethod = value;
                  })
                }, (method: string) => method)
              }
            }

            if (this.manualUsesTls()) {
              Row() {
                Text('TLS 加密')
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.manualTls })
                  .onChange((on: boolean) => {
                    this.manualTls = on;
                  })
              }
              .width('100%')
            }

            if (this.manualError.length > 0) {
              Text(this.manualError)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_warning'))
                .width('100%')
            }

            Button('预览并添加')
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
              .backgroundColor($r('sys.color.ohos_id_color_text_primary'))
              .borderRadius(18)
              .constraintSize({ minHeight: 48 })
              .onClick(() => {
                this.runManualPreview();
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_primary'))


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
    }.width('100%').height('100%')
      .bindSheet($$this.previewVisible, this.ImportResultSheet(), {
        height: this.previewKind === 'subscription-url' ? 360 : SheetSize.LARGE,
        showClose: true,
        onDisappear: () => { this.cancelPreview(); }
      })
  }
}
