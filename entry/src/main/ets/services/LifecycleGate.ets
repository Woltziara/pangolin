/** Process-local admission shared by connection preparation and destructive data actions.
 * The durable control record supplies the cross-process fence. Never use a UI busy flag as authority. */
export class LifecycleGate {
  private preparations: number = 0;
  private maintenance: boolean = false;
  beginPreparation(): () => void {
    if (this.maintenance) throw new Error('正在清理数据，未启动连接。');
    this.preparations += 1;
    let live = true;
    return (): void => { if (live) { live = false; this.preparations -= 1; } };
  }
  beginMaintenance(): () => void {
    if (this.maintenance || this.preparations > 0) throw new Error('连接操作尚未结束，未清理数据。');
    this.maintenance = true;
    return (): void => { this.maintenance = false; };
  }
  blocked(): boolean { return this.maintenance || this.preparations > 0; }
}
export const LIFECYCLE_GATE: LifecycleGate = new LifecycleGate();
