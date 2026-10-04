import { PangolinCompanion } from './PangolinCompanion';
import { accessibility } from '@kit.AccessibilityKit';

/** Lives in measured blank space only; never overlays controls or moves them. */
@Component
export struct PangolinPet {
  @Prop @Watch('changed') state: string = 'idle';
  @Prop motionEnabled: boolean = true;
  @State x: number = 0;
  @State widthVp: number = 0;
  @State faceLeft: boolean = false;
  private origin: number = 0;
  private timer: number = -1;
  private stop(): void { if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; } }
  aboutToDisappear(): void { this.stop(); }
  private changed(): void {
    this.stop();
    let reduced = true;
    try { reduced = accessibility.isAnimationReduceEnabledSync(); } catch (error) {}
    if (this.state !== 'connecting' || reduced || !this.motionEnabled || this.widthVp < 112) { return; }
    this.timer = setTimeout(() => {
      if (this.state !== 'connecting') { return; }
      const delta = this.x + 104 <= this.widthVp ? 32 : -32;
      this.faceLeft = delta < 0;
      this.getUIContext().animateTo({ duration: 600, curve: Curve.Linear }, () => {
        this.x = Math.max(0, Math.min(this.widthVp - 72, this.x + delta));
      });
    }, 360);
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() { PangolinCompanion({ state: this.state, allowPlayback: this.motionEnabled, iconSize: 72 }) }
        .width(72).height(72).position({ x: this.x, y: 0 }).scale({ x: this.faceLeft ? -1 : 1 })
        .gesture(PanGesture().onActionStart(() => { this.stop(); this.origin = this.x; })
          .onActionUpdate((event: GestureEvent) => { this.x = Math.max(0, Math.min(this.widthVp - 72, this.origin + event.offsetX)); }))
    }.width('100%').height(this.motionEnabled ? 72 : 0).clip(true)
      .visibility(this.motionEnabled ? Visibility.Visible : Visibility.None)
      .onAreaChange((_old: Area, area: Area) => {
        this.widthVp = Number(area.width); this.x = Math.max(0, Math.min(this.x, this.widthVp - 72));
      })
  }
}
