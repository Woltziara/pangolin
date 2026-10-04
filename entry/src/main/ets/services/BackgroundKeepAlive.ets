import { AppLog as hilog } from './AppLog';
import { common, wantAgent, Want } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BUNDLE_NAME } from '../vpn/VpnConstants';
import { StatusStore } from './StatusStore';

const LOG_DOMAIN: number = 0x3200;
const LOG_TAG: string = 'BgKeep';
const KEEP_FILE: string = 'background-keepalive.json';
const DOC: string = 'https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-network-134';

export class BackgroundKeepAlive {
  private running: boolean = false;
  private listening: boolean = false;
  private lastCode: number = 0;
  private lastError: string = '';
  private lastSource: string = '';
  private notificationId: number = -1;
  private continuousTaskId: number = -1;
  private progress: number = 0;
  private lastEvent: string = '';
  private systemPresent: boolean = false;
  private systemSuspend: boolean = false;
  private liveViewOk: boolean = false;
  private gate: Promise<boolean> = Promise.resolve(true);
  private touchTimerId: number = -1;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private screenOff: boolean = false;

  async ensure(context: common.UIAbilityContext, source: string): Promise<boolean> {
    const next = this.gate.then(() => {
      return this.ensureLocked(context, source);
    }, () => {
      return this.ensureLocked(context, source);
    });
    this.gate = next.then((ok: boolean) => {
      return ok;
    }, () => {
      return false;
    });
    return await next;
  }

  private async ensureLocked(context: common.UIAbilityContext, source: string): Promise<boolean> {
    this.subscribe(context);
    await this.subscribeScreen(context);
    if (this.running) {
      const touched = await this.touch(context);
      if (!touched) {
        return false;
      }
      this.write(context, source);
      return this.isOk();
    }
    try {
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: 'EntryAbility'
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      const modes: Array<string> = ['dataTransfer'];
      const notice = await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
      return await this.adoptStarted(context, source, notice.notificationId,
        notice.continuousTaskId !== undefined ? notice.continuousTaskId : -1);
    } catch (error) {
      const businessError = error as BusinessError;
      const code = businessError.code !== undefined ? businessError.code : -1;
      if (code === 9800005) {
        const present = await this.readBack(context);
        if (present) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'DATA_TRANSFER already applied, adopting existing task');
          return await this.adoptStarted(context, source, this.notificationId, this.continuousTaskId);
        }
      }
      this.markDead(context, this.errorText(businessError, error), code);
      this.write(context, source);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'startBackgroundRunning code=%{public}d %{public}s',
        this.lastCode, this.lastError);
      return false;
    }
  }

  private async adoptStarted(context: common.UIAbilityContext, source: string, notificationId: number,
    continuousTaskId: number): Promise<boolean> {
    this.notificationId = notificationId;
    this.continuousTaskId = continuousTaskId;
    if (this.notificationId < 0 && this.continuousTaskId < 0) {
      const presentEarly = await this.readBack(context);
      if (!presentEarly) {
        this.markDead(context, 'start returned no notification identity', -1);
        this.write(context, source);
        return false;
      }
    }
    this.running = true;
    this.lastCode = 0;
    this.lastError = '';
    this.lastSource = source;
    this.progress = 1;
    this.lastEvent = 'start';
    this.liveViewOk = false;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'DATA_TRANSFER keep-alive without synthetic download progress');
    const present = await this.readBack(context);
    if (!present) {
      this.markDead(context, 'system has no matching DATA_TRANSFER task after start', -2);
      this.write(context, source);
      return false;
    }
    this.write(context, source);
    this.startTouchTimer(context);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'DATA_TRANSFER keep-alive started from %{public}s id=%{public}d nid=%{public}d live=%{public}s',
      source, this.continuousTaskId, this.notificationId, this.liveViewOk ? '1' : '0');
    return this.isOk();
  }

  async touch(context: common.UIAbilityContext): Promise<boolean> {
    if (!this.running) {
      return false;
    }
    try {
      this.lastEvent = 'readback';
      this.liveViewOk = false;
      this.lastCode = 0;
      this.lastError = '';
      const present = await this.readBack(context);
      if (!present) {
        this.markDead(context, 'touch succeeded locally but system task missing', -3);
        this.write(context, `${this.lastSource}+touch`);
        return false;
      }
      this.write(context, `${this.lastSource}+touch`);
      return this.isOk();
    } catch (error) {
      const businessError = error as BusinessError;
      this.markDead(context, this.errorText(businessError, error),
        businessError.code !== undefined ? businessError.code : this.lastCode);
      this.write(context, `${this.lastSource}+touch`);
      return false;
    }
  }

  async stop(context: common.UIAbilityContext, source: string): Promise<void> {
    const next = this.gate.then(() => {
      return this.stopLocked(context, source);
    }, () => {
      return this.stopLocked(context, source);
    });
    this.gate = next.then(() => {
      return false;
    }, () => {
      return false;
    });
    await next;
  }

  private async stopLocked(context: common.UIAbilityContext, source: string): Promise<void> {
    this.stopTouchTimer();
    this.unsubscribeScreen();
    try {
      if (this.continuousTaskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(context, this.continuousTaskId);
      } else if (this.running) {
        await backgroundTaskManager.stopBackgroundRunning(context);
      }
    } catch (error) {
      const businessError = error as BusinessError;
      this.lastCode = businessError.code !== undefined ? businessError.code : -1;
      this.lastError = this.errorText(businessError, error);
    }
    this.running = false;
    this.systemPresent = false;
    this.systemSuspend = false;
    this.notificationId = -1;
    this.continuousTaskId = -1;
    this.lastEvent = 'stop';
    this.lastSource = source;
    this.write(context, source);
  }

  private isOk(): boolean {
    return this.running && this.systemPresent && !this.systemSuspend && this.notificationId >= 0;
  }

  private startTouchTimer(context: common.UIAbilityContext): void {
    this.stopTouchTimer();
    this.touchTimerId = setInterval(() => {
      this.ensure(context, `${this.lastSource}+period`).catch((error: Object) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'period touch %{public}s', `${error}`);
      });
    }, 60000);
  }

  private async subscribeScreen(context: common.UIAbilityContext): Promise<void> {
    if (this.subscriber !== null) {
      return;
    }
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: ['usual.event.SCREEN_OFF', 'usual.event.SCREEN_ON']
      };
      this.subscriber = await commonEventManager.createSubscriber(info);
      const sub = this.subscriber;
      commonEventManager.subscribe(sub, (error: BusinessError, data: commonEventManager.CommonEventData) => {
        if (error) {
          return;
        }
        const eventName = data.event;
        if (eventName === 'usual.event.SCREEN_OFF') {
          this.screenOff = true;
          this.lastEvent = 'screen-off';
          this.ensure(context, 'screen-off').catch((err: Object) => {
            hilog.error(LOG_DOMAIN, LOG_TAG, 'screen-off keep %{public}s', `${err}`);
          });
          return;
        }
        if (eventName === 'usual.event.SCREEN_ON') {
          this.screenOff = false;
          this.lastEvent = 'screen-on';
          this.write(context, 'screen-on');
        }
      });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'screen subscriber %{public}s', `${error}`);
    }
  }

  private unsubscribeScreen(): void {
    if (this.subscriber === null) {
      return;
    }
    try {
      commonEventManager.unsubscribe(this.subscriber);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'screen unsubscribe %{public}s', `${error}`);
    }
    this.subscriber = null;
  }

  private stopTouchTimer(): void {
    if (this.touchTimerId >= 0) {
      clearInterval(this.touchTimerId);
      this.touchTimerId = -1;
    }
  }

  private subscribe(context: common.UIAbilityContext): void {
    if (this.listening) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        if (this.matchesId(info.id)) {
          this.markDead(context, `cancel id=${info.id} reason=${this.cancelReason(info.reason)}`, info.reason);
          this.write(context, 'event-cancel');
        }
      });
      backgroundTaskManager.on('continuousTaskSuspend', (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => {
        if (this.matchesId(info.continuousTaskId)) {
          this.systemSuspend = info.suspendState === true;
          this.lastEvent = 'suspend';
          this.write(context, 'event-suspend');
        }
      });
      backgroundTaskManager.on('continuousTaskActive', (info: backgroundTaskManager.ContinuousTaskActiveInfo) => {
        if (this.matchesId(info.id)) {
          this.systemSuspend = false;
          this.lastEvent = 'active';
          this.write(context, 'event-active');
        }
      });
      this.listening = true;
    } catch (error) {
      this.listening = false;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'keep-alive subscribe failed %{public}s', `${error}`);
    }
  }

  private matchesId(id: number): boolean {
    if (this.continuousTaskId >= 0) {
      return id === this.continuousTaskId;
    }
    return this.running;
  }

  private async readBack(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const tasks = await backgroundTaskManager.getAllContinuousTasks(context, true);
      let found = false;
      let suspend = false;
      for (let i = 0; i < tasks.length; i++) {
        const task = tasks[i];
        const unmatched = this.continuousTaskId < 0 && this.notificationId < 0;
        const idMatch = this.continuousTaskId >= 0 && task.continuousTaskId === this.continuousTaskId;
        const nidMatch = this.notificationId >= 0 && task.notificationId === this.notificationId;
        if (unmatched || idMatch || nidMatch) {
          found = true;
          suspend = task.suspendState === true;
          if (task.continuousTaskId >= 0) {
            this.continuousTaskId = task.continuousTaskId;
          }
          if (task.notificationId >= 0) {
            this.notificationId = task.notificationId;
          }
          if (unmatched) {
            break;
          }
        }
      }
      this.systemPresent = found;
      this.systemSuspend = suspend;
      return found;
    } catch (error) {
      this.systemPresent = false;
      this.lastError = `getAllContinuousTasks ${error}`;
      return false;
    }
  }

  private markDead(context: common.UIAbilityContext, message: string, code: number): void {
    this.stopTouchTimer();
    this.running = false;
    this.systemPresent = false;
    this.lastError = message;
    this.lastCode = code;
    this.lastEvent = 'dead';
    hilog.error(LOG_DOMAIN, LOG_TAG, 'keep-alive dead %{public}s', message);
  }

  private cancelReason(code: number): string {
    if (code === 4) {
      return '4 DATA_TRANSFER_LOW_SPEED';
    }
    if (code === 12) {
      return '12 DATA_TRANSFER_NOT_UPDATE';
    }
    if (code === 3) {
      return '3 USER_CANCEL_REMOVE_NOTIFICATION';
    }
    return `${code}`;
  }

  private errorText(businessError: BusinessError, error: Object): string {
    if (businessError.message !== undefined && businessError.message.length > 0) {
      return businessError.message;
    }
    return JSON.stringify(error);
  }

  private write(context: common.UIAbilityContext, source: string): void {
    const rec: Record<string, Object> = {};
    rec['ok'] = this.isOk();
    rec['running'] = this.running;
    rec['systemPresent'] = this.systemPresent;
    rec['systemSuspend'] = this.systemSuspend;
    rec['mode'] = 'dataTransfer';
    rec['permission'] = 'ohos.permission.KEEP_BACKGROUND_RUNNING';
    rec['notificationId'] = this.notificationId;
    rec['continuousTaskId'] = this.continuousTaskId;
    rec['progress'] = this.progress;
    rec['liveView'] = this.liveViewOk;
    rec['lastEvent'] = this.lastEvent;
    rec['screenOff'] = this.screenOff;
    rec['errorCode'] = this.lastCode;
    rec['error'] = this.lastError;
    rec['source'] = source;
    rec['doc'] = DOC;
    rec['at'] = Date.now();
    StatusStore.writeText(context, KEEP_FILE, JSON.stringify(rec));
  }
}

export const BACKGROUND_KEEP_ALIVE: BackgroundKeepAlive = new BackgroundKeepAlive();
