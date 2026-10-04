import { redactDiagnosticText } from '../core/UserFacingCopy';
import { UiFeedback, UI_FEEDBACK_FILE } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 诊断页（Phase D 新增）：一键四项检查 + 导出脱敏诊断报告。
// 检查全部复用既有探针原语：NetReader（本地网络）/ ProbeSelfCheck 手写 DNS 与
// HTTP 探测（DNS、目标访问）/ tcpConnectCanary（节点 TCP 延迟，同首页测速）。
// 目标访问说明：数据面 SOCKS 会话（端口/凭据）由 VPN 进程内 newSocksSession()
// 每次会话动态分配，UI 进程拿不到，因此与 ProbeSelfCheck 后台自证一致走
// 直连 HTTP 探测（UI 进程流量随系统 VPN 进隧道），目标是现有探测地址 generate_204。
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import {
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
import { tcpConnectCanary } from '../net/DataplaneCanary';
import { NetReader } from '../net/NetSnapshot';
import { DiagnosticCheck, DiagnosticReport } from '../services/DiagnosticReport';
import { NodeStore, StoredNode } from '../services/NodeStore';
import { PROBE_SELF_CHECK } from '../services/ProbeSelfCheck';
import { SELECT_MANUAL, SettingsStore } from '../services/SettingsStore';
import { StatusStore } from '../services/StatusStore';
import { AppliedPolicy } from '../services/AppliedPolicy';
import { isConnectionEstablished } from '../net/ConnectionHealth';

const NODE_PING_TIMEOUT_MS: number = 2500;
const DEFAULT_TARGET_URL: string = 'http://www.google.com/generate_204';

const STATE_WAITING: string = 'waiting';
const STATE_RUNNING: string = 'running';
const STATE_OK: string = 'ok';
const STATE_FAIL: string = 'fail';
const STATE_SKIP: string = 'skip';

class CheckRow {
  name: string = '';
  state: string = STATE_WAITING;
  verdict: string = '待检查';
  advice: string = '';

  clone(): CheckRow {
    const next = new CheckRow();
    next.name = this.name;
    next.state = this.state;
    next.verdict = this.verdict;
    next.advice = this.advice;
    return next;
  }
}

@Entry
@Component
struct Diagnostics {
  @State rows: Array<CheckRow> = Diagnostics.initialRows();
  @State busy: boolean = false;
  @State exporting: boolean = false;
  @State lastReportPath: string = '';
  @State incidentName: string = '';
  @State showTechnicalDetails: boolean = false;
  @State technicalDetails: string = '';
  private context: common.UIAbilityContext | null = null;

  private static initialRows(): Array<CheckRow> {
    const names: Array<string> = ['本地网络', 'DNS', '节点连接', '目标访问'];
    const rows: Array<CheckRow> = [];
    for (let i = 0; i < names.length; i++) {
      const row = new CheckRow();
      row.name = names[i];
      rows.push(row);
    }
    return rows;
  }

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.incidentName = DiagnosticReport.latestIncident(this.context);
  }

  private toggleTechnicalDetails(): void {
    this.showTechnicalDetails = !this.showTechnicalDetails;
    if (!this.showTechnicalDetails || this.context === null) { return; }
    const status = StatusStore.readStatus(this.context);
    const lastUi = StatusStore.readText(this.context, UI_FEEDBACK_FILE);
    this.technicalDetails = redactDiagnosticText([
      `运行阶段：${status.phase}`,
      `状态更新时间：${status.at > 0 ? new Date(status.at).toLocaleString() : '暂无'}`,
      `运行说明：${status.honestLabel || '暂无'}`,
      `最近错误：${status.lastError || '暂无'}`,
      `最近检查：${status.lastCanary || '暂无'}`,
      `会话：${status.generation || '暂无'} / ${status.sessionRevision}`,
      `界面操作记录：${lastUi || '暂无'}`
    ].join('\n\n'));
  }

  private setRow(index: number, state: string, verdict: string, advice: string): void {
    const next: Array<CheckRow> = [];
    for (let i = 0; i < this.rows.length; i++) {
      const row = this.rows[i].clone();
      if (i === index) {
        row.state = state;
        row.verdict = verdict;
        row.advice = advice;
      }
      next.push(row);
    }
    this.rows = next;
  }

  private isConnected(): boolean {
    const ctx = this.context;
    if (ctx === null) {
      return false;
    }
    const plane = StatusStore.readStatus(ctx);
    return plane.phase === PHASE_CANARY_OK || plane.phase === PHASE_DEGRADED ||
      plane.phase === PHASE_DEGRADED_UNPROVEN || plane.phase === PHASE_UNPROVEN ||
      plane.phase === PHASE_RECONNECTING || plane.phase === PHASE_FORWARDER_RUNNING ||
      plane.phase === PHASE_CORE_RUNNING || plane.phase === PHASE_VPN_CREATED ||
      plane.phase === PHASE_STARTING;
  }

  /** Current applied node first; a saved-but-unapplied choice must not replace it. */
  private pickNode(): StoredNode | null {
    const ctx = this.context;
    if (ctx === null) {
      return null;
    }
    const settings = SettingsStore.load(ctx);
    const nodes = NodeStore.loadNodes(ctx);
    const wanted: Array<string> = [];
    const applied = AppliedPolicy.current(ctx);
    if (applied !== null && typeof applied['singleNodeId'] === 'string') {
      wanted.push(applied['singleNodeId'] as string);
    }
    if (applied !== null) {
      const name = StatusStore.readNodeMeta(ctx).name;
      const actual = nodes.find((node: StoredNode) => node.name === name);
      if (actual !== undefined && wanted.filter((id: string) => id.length > 0).length === 0) { return actual; }
    }
    if (settings.singleNodeId.length > 0) { wanted.push(settings.singleNodeId); }
    if (settings.selectionMode === SELECT_MANUAL && settings.manualNodeId.length > 0) {
      wanted.push(settings.manualNodeId);
    }
    if (settings.lastGoodNodeId.length > 0) {
      wanted.push(settings.lastGoodNodeId);
    }
    for (let w = 0; w < wanted.length; w++) {
      for (let i = 0; i < nodes.length; i++) {
        if (nodes[i].id === wanted[w] && nodes[i].server.length > 0) {
          return nodes[i];
        }
      }
    }
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].server.length > 0 && nodes[i].port > 0) {
        return nodes[i];
      }
    }
    return null;
  }

  private async runChecks(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.rows = Diagnostics.initialRows();
    try {
      // 1. 本地网络
      this.setRow(0, STATE_RUNNING, '检查中', '');
      const snap = await NetReader.read();
      if (snap.ok && snap.defaultNetId > 0) {
        const bearer = snap.defaultBearer.length > 0 ? snap.defaultBearer : '未知类型';
        this.setRow(0, STATE_OK, `正常（${bearer}）`, '');
      } else {
        this.setRow(0, STATE_FAIL, '网络没通（请检查 Wi-Fi 或蜂窝）', '检查 Wi-Fi 或蜂窝网络是否可用');
      }

      // 2. DNS（复用 ProbeSelfCheck 手写 DNS 探针）
      this.setRow(1, STATE_RUNNING, '检查中', '');
      const dnsOk = await PROBE_SELF_CHECK.probeDnsOk();
      if (dnsOk) {
        this.setRow(1, STATE_OK, '正常', '');
      } else {
        this.setRow(1, STATE_FAIL, 'DNS 解析失败', '切换网络或稍后重试；仍失败请检查路由器 DNS');
      }

      // 3. 节点连接（与首页测速同一个 tcpConnectCanary）
      this.setRow(2, STATE_RUNNING, '检查中', '');
      const node = this.pickNode();
      const current = this.context !== null ? StatusStore.readStatus(this.context) : null;
      if (node === null) {
        this.setRow(2, STATE_FAIL, '没有可用节点', '先导入节点或添加订阅');
      } else if (current !== null && isConnectionEstablished(current, Date.now())) {
        this.setRow(2, STATE_OK, '当前线路已建立', '目标访问在下一项单独检查；不以单次 TCP 探测替代实际连接状态。');
      } else {
        const ping = await tcpConnectCanary(node.server, node.port, NODE_PING_TIMEOUT_MS);
        if (ping.ok) {
          this.setRow(2, STATE_OK, `节点 TCP 可达（${ping.elapsedMs} 毫秒）`, '此项不代表代理登录或目标网站已可用。');
        } else {
          this.setRow(2, STATE_FAIL, '节点 TCP 探测未通过', '可能受当前网络或探测方式影响，不能仅据此判断订阅过期。');
        }
      }

      // 4. 目标访问（未连接时跳过）
      this.setRow(3, STATE_RUNNING, '检查中', '');
      if (!this.isConnected()) {
        this.setRow(3, STATE_SKIP, '未连接（跳过）', '');
      } else {
        const ctx = this.context;
        let target = DEFAULT_TARGET_URL;
        if (ctx !== null) {
          const plane = StatusStore.readStatus(ctx);
          if (plane.probeGoogleUrl.length >= 8) {
            target = plane.probeGoogleUrl;
          }
        }
        const code = await PROBE_SELF_CHECK.probeHttpCode(target);
        if (code === 204 || (code >= 200 && code < 400)) {
          this.setRow(3, STATE_OK, '正常', '');
        } else {
          this.setRow(3, STATE_FAIL, '目标服务异常', '尝试重新连接，或切换节点');
        }
      }
    } finally {
      this.busy = false;
    }
  }

  private async captureReport(): Promise<Record<string, Object>> {
    const checks: Array<DiagnosticCheck> = [];
    for (let i = 0; i < this.rows.length; i++) {
      const row = this.rows[i];
      const check = new DiagnosticCheck();
      check.name = row.name;
      check.ok = row.state === STATE_OK;
      check.skipped = row.state === STATE_SKIP || row.state === STATE_WAITING;
      check.verdict = row.verdict;
      check.advice = row.advice;
      checks.push(check);
    }
    return DiagnosticReport.build(this.context as common.UIAbilityContext, checks);
  }

  private async saveIncident(): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.exporting || this.busy) { return; }
    this.exporting = true;
    try {
      const doc = await this.captureReport();
      const incident: Record<string, Object> = { 'reportedAt': Date.now(), 'note': '用户在此刻保存故障现场；不是推断出的故障开始时间。' };
      doc['incident'] = incident;
      const path = DiagnosticReport.write(ctx, doc, true);
      this.incidentName = path.substring(path.lastIndexOf('/') + 1);
      this.lastReportPath = `已保存故障现场：${new Date(doc['time'] as number).toLocaleString()}`;
      promptAction.showToast({ message: '现场已保留，未重连、未发起网络检查' });
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(ctx, 'export', error, '故障现场未保存，请重试。') });
    } finally { this.exporting = false; }
  }

  private async exportReport(): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      // Prefer the frozen incident, not a new post-reconnect state.
      let raw = this.incidentName.length > 0 ? StatusStore.readText(ctx, this.incidentName) : '';
      if (raw.length === 0) { raw = JSON.stringify(await this.captureReport(), null, 2); }
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.incidentName.length > 0 ? `穿山甲-${this.incidentName}` : `穿山甲-诊断-${Date.now()}.json`];
      const uris = await new picker.DocumentViewPicker(ctx).save(options);
      if (uris === undefined || uris.length === 0) { return; }
      const dest = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(dest.fd, raw); } finally { fileIo.closeSync(dest); }
      this.lastReportPath = '完整诊断文件已保存到所选位置';
      promptAction.showToast({ message: '已导出诊断文件' });
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(this.context, 'export', error, '导出未完成，请检查保存位置后重试。') });
    } finally {
      this.exporting = false;
    }
  }

  private async copySummary(): Promise<void> {
    if (this.context === null || this.exporting || this.busy) { return; }
    this.exporting = true;
    try {
      const doc = await this.captureReport();
      // Clipboard stays small. The bounded full history is exported as a file.
      const summary: Record<string, Object> = {};
      Object.keys(doc).forEach((key: string) => { if (key !== 'runtimeJournal') { summary[key] = doc[key]; } });
      summary['note'] = '摘要不含跨会话运行历史；详细排查请导出诊断文件。';
      await pasteboard.getSystemPasteboard().setData(pasteboard.createPlainTextData(JSON.stringify(summary, null, 2)));
      promptAction.showToast({ message: '已复制（报告已脱敏）' });
    } catch (error) {
      promptAction.showToast({ message: UiFeedback.failure(this.context, 'export', error, '摘要未复制，请重试。') });
    } finally { this.exporting = false; }
  }

  private stateMark(row: CheckRow): string {
    if (row.state === STATE_OK) {
      return '✓';
    }
    if (row.state === STATE_FAIL) {
      return '✗';
    }
    if (row.state === STATE_RUNNING) {
      return '…';
    }
    if (row.state === STATE_SKIP) {
      return '—';
    }
    return '·';
  }

  private stateColor(row: CheckRow): ResourceColor {
    if (row.state === STATE_OK) {
      return $r('sys.color.ohos_id_color_text_primary_activated');
    }
    if (row.state === STATE_FAIL) {
      return $r('sys.color.ohos_id_color_warning');
    }
    if (row.state === STATE_SKIP) {
      return $r('sys.color.ohos_id_color_text_secondary');
    }
    return $r('sys.color.ohos_id_color_text_secondary');
  }

  @Builder
  CheckRowView(row: CheckRow) {
    Column() {
      Row() {
        Text(this.stateMark(row))
          .fontSize(16)
          .fontColor(this.stateColor(row))
          .width(24)
        Text(row.name)
          .fontSize(15)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)
        Text(row.verdict)
          .fontSize(13)
          .fontColor(this.stateColor(row))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      if (row.advice.length > 0) {
        Text(`建议：${row.advice}`)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .width('100%')
          .margin({ top: 4, left: 24 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .margin({ bottom: 8 })
  }

  build() {
    Column() {
    NativePage({ title: '诊断', rootPage: false }) {
    Column() {


      List({ space: 0 }) {
        ListItem() {
          Column({ space: 8 }) {
            Text('遇到微信等应用未连接时，先保存故障现场，再尝试恢复。保存只读取本机记录，不重连或发送探测请求。')
              .fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Button(this.exporting ? '正在处理…' : '保存故障现场')
              .width('100%').constraintSize({ minHeight: 48 })
              .enabled(!this.exporting && !this.busy)
              .onClick(() => { this.saveIncident(); })
            Text('运行时自动记录网络变化、转发与分流计数；最多 48 小时 / 4 MiB，满后提前滚动。仅本机保存，不含聊天或访问内容。故障现场另保留最近 5 份。')
              .fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Button(this.showTechnicalDetails ? '收起技术详情' : '查看技术详情')
              .onClick(() => { this.toggleTechnicalDetails(); })
            if (this.showTechnicalDetails) {
              Text('以下信息用于排查问题，不表示连接已经恢复。')
                .fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary'))
              Text(this.technicalDetails).fontSize(12).fontFamily('monospace')
                .width('100%').fontColor($r('sys.color.ohos_id_color_text_secondary'))
            }
          }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 16 })
        }

        ForEach(this.rows, (row: CheckRow) => {
          ListItem() {
            this.CheckRowView(row)
          }
        }, (row: CheckRow) => `${row.name}|${row.state}|${row.verdict}`)

        ListItem() {
          Column() {
            Button(this.busy ? '正在检查…' : '一键检查')
              .fontSize(15)
              .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
              .backgroundColor($r('sys.color.ohos_id_color_text_primary_activated'))
              .borderRadius(22)
              .height(44)
              .width('100%')
              .enabled(!this.busy)
              .onClick(() => {
                this.runChecks();
              })

            Button(this.exporting ? '正在导出…' : this.incidentName.length > 0 ? '导出最近故障现场' : '导出诊断报告')
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(18)
              .constraintSize({ minHeight: 48 })
              .width('100%')
              .margin({ top: 12 })
              .enabled(!this.exporting && !this.busy)
              .onClick(() => {
                this.exportReport();
              })

            Button('复制当前诊断摘要').margin({ top: 12 }).enabled(!this.exporting && !this.busy)
              .onClick(() => { this.copySummary(); })

            Text('完整历史请导出文件，由你决定发给谁；复制摘要只含当前状态与最近事件。已保存现场不会被后续重连改写。')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .width('100%')
              .margin({ top: 8 })

            if (this.lastReportPath.length > 0) {
              Text(this.lastReportPath)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .width('100%')
                .margin({ top: 8 })
            }
          }
          .width('100%')
          .margin({ top: 8 })
        }
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
