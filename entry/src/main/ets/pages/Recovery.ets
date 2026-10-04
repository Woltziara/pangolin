import { common } from '@kit.AbilityKit';
import { NativePage } from '../components/NativePage';
import { StatusStore } from '../services/StatusStore';
import { BUSINESS_FILE } from '../net/LayerEvidence';
import { ChatgptAppRecovery } from '../services/ChatgptAppRecovery';
import { PROBE_SELF_CHECK } from '../services/ProbeSelfCheck';
import { RecoveryTrace } from '../services/RecoveryTrace';
import { DiagnosticReport } from '../services/DiagnosticReport';

@Entry
@Component
struct Recovery {
  @State reported: string = '';
  @State recovering: boolean = false;
  @State recoveryResult: string = '';
  @State checking: boolean = false;
  @State checkResult: string = '';
  private context: common.UIAbilityContext | null = null;
  private incident: string = '';
  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.incident = DiagnosticReport.latestIncident(this.context);
  }
  private reportBusiness(success: boolean = false): void {
    if (this.context === null) return;
    const live = StatusStore.readOwnerStatus(this.context);
    const record: Record<string, Object> = {};
    record['generation'] = live.generation; record['revision'] = live.sessionRevision; record['at'] = Date.now();
    record['scope'] = 'chatgpt-application'; record['outcome'] = success ? 'user-reported-success' : 'user-reported-failure';
    record['source'] = 'explicit-user-action';
    try {
      StatusStore.writeText(this.context, BUSINESS_FILE, JSON.stringify(record));
      const linked = RecoveryTrace.reportBusiness(this.context, this.incident, success);
      this.reported = linked ? '本次使用结果已记入恢复记录。' : '当前使用结果已记录，未归入旧连接的恢复记录。';
    } catch (_error) { this.reported = '记录失败，请重试。'; }
  }
  private async restartApps(): Promise<void> {
    if (this.context === null || this.recovering) return;
    this.recovering = true; this.recoveryResult = '正在打开出境易…';
    this.incident = RecoveryTrace.begin(this.context, 'open-app-recovery-guide');
    try {
      this.recoveryResult = await ChatgptAppRecovery.openManager(this.context);
    } catch (error) {
      const message = (error as Error).message;
      this.recoveryResult = `打开管理入口未完成：${message || JSON.stringify(error)}。请按下方手动入口操作。`;
    } finally { this.recovering = false; }
  }
  private async checkRecovery(): Promise<void> {
    if (this.context === null || this.checking) return;
    this.checking = true; this.checkResult = '正在检测网络…';
    try { this.checkResult = await PROBE_SELF_CHECK.checkNow(this.context); }
    catch (_error) { this.checkResult = '检测未完成，请返回首页重新连接后再试。'; }
    finally { this.checking = false; }
  }
  build() {
    Column() {
    NativePage({ title: '恢复 ChatGPT 加载' }) {
      Scroll() {
        Column({ space: 18 }) {
          Text('ChatGPT 一直转圈或停在旧记录').fontSize(18).fontWeight(FontWeight.Medium)
          Text('打开出境易后，依次操作下面两项，再重新打开 ChatGPT。').fontSize(16)
          Button(this.recovering ? '正在打开…' : '1. 打开出境易').width('100%')
            .enabled(!this.recovering).onClick(() => { this.restartApps(); })
          if (this.recoveryResult.length > 0) Text(this.recoveryResult).fontSize(14)
          Text('2. 我的 → 应用管理 → ChatGPT → 强行停止。\n返回应用管理 → 出境服务框架 → 强行停止。\n如有确认弹窗，点“确定”；先打开出境服务框架，再打开 ChatGPT。').fontSize(16)
          Text('只点“强行停止”，保留应用数据和登录账号。').fontSize(14)
          Text('3. 在 ChatGPT 中加载新话题，或发消息并确认收到回复。下面的网络检查不能代替这一步。').fontSize(16)
          Button(this.checking ? '正在检测…' : '检查网络通道').width('100%').enabled(!this.checking)
            .onClick(() => { this.checkRecovery(); })
          if (this.checkResult.length > 0) Text(this.checkResult).fontSize(15)
          Button('ChatGPT 已收到新回复').onClick(() => { this.reportBusiness(true); })
          Button('仍有问题，记录本次故障').onClick(() => { this.reportBusiness(); })
          if (this.reported.length > 0) Text(this.reported).fontSize(14)
          Text('如果网络检测失败，请返回首页点“修复并检测”。').fontSize(14)
        }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%')
    }
    }.width('100%').height('100%')
  }
}
