import { common } from '@kit.AbilityKit';
import { NativePage } from '../components/NativePage';
import { CONNECTION_CONTROLLER } from '../services/ConnectionController';
import { StatusStore } from '../services/StatusStore';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct ConnectionRecovery {
  @State result: string = '正在检查连接…';
  @State working: boolean = false;
  @State canAskStop: boolean = false;
  @State canRecoverOwner: boolean = false;
  @State canConnect: boolean = false;
  aboutToAppear(): void { this.inspect(false); }
  private bearerAbsent(context: common.UIAbilityContext): boolean {
    try {
      const observation = JSON.parse(StatusStore.readText(context, 'system-observation.json')) as Record<string, Object>;
      return observation['bearer'] === 'absent' && typeof observation['at'] === 'number' &&
        Date.now() - (observation['at'] as number) < 10000;
    } catch (_error) { return false; }
  }
  private async inspect(stop: boolean): Promise<void> {
    if (this.working) return;
    this.working = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      let status = stop ? await CONNECTION_CONTROLLER.stop(context) : await CONNECTION_CONTROLLER.reconcileStatus(context, true);
      const absent = this.bearerAbsent(context);
      this.canAskStop = !absent && status.phase !== 'STOPPED' && status.phase !== 'IDLE';
      this.canRecoverOwner = absent && status.phase !== 'STOPPED' && status.phase !== 'IDLE';
      this.canConnect = status.phase === 'STOPPED' || status.phase === 'IDLE';
      if (status.phase === 'STOPPED' || status.phase === 'IDLE') {
        this.result = '可以连接了。返回首页点“连接”。';
      } else {
        this.result = absent ? '系统 VPN 已关闭。点“恢复连接”核实旧进程并重新连接。' :
          '请在手机设置中搜索 VPN，断开“穿山甲”；返回这里点“重新检查”。';
      }
    } catch (_error) { this.result = '检查没有完成，请点“重新检查”。'; }
    finally { this.working = false; }
  }
  private async recover(): Promise<void> {
    if (this.working) return;
    this.working = true;
    this.result = '正在核实旧连接…';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (this.canRecoverOwner) await CONNECTION_CONTROLLER.recoverStoppedOwner(context);
      this.result = '正在重新连接…';
      const status = await CONNECTION_CONTROLLER.start(context);
      if (status.phase === 'STOP_UNCONFIRMED' || status.phase === 'ERROR') {
        this.result = status.lastError || '连接尚未恢复，请重新检查';
      } else { router.back(); }
    } catch (error) { this.result = (error as Error).message || '恢复未完成，请重新检查'; }
    finally { this.working = false; }
  }
  build() {
    Column() {
      NativePage({ title: '恢复连接' }) {
        Scroll() {
          Column({ space: 18 }) {
            Text(this.result).fontSize(18)
            if (this.canRecoverOwner || this.canConnect) {
              Button(this.canConnect ? '连接' : '恢复连接').enabled(!this.working).onClick(() => { this.recover(); })
            }
            Button(this.working ? '正在检查…' : '重新检查').enabled(!this.working).onClick(() => { this.inspect(false); })
            if (this.canAskStop) {
              Button('再试自动关闭').enabled(!this.working).onClick(() => { this.inspect(true); })
            }
          }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
  }
}
