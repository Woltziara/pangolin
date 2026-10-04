import { accessibility } from '@kit.AccessibilityKit';
import { pangolinFrames, pangolinFinalPose, PangolinFrame, PANGOLIN_SATURATION } from '../core/PangolinMotion';

/** Caller owns verified premium access; only the explicit preview opts in today. */
@Component
export struct PangolinCompanion {
  @Prop @Watch('changed') state: string = 'idle';
  @Prop @Watch('changed') allowPlayback: boolean = false;
  @Prop @Watch('changed') reduceMotion: boolean = false;
  @Prop @Watch('changed') replay: number = 0;
  @Prop iconSize: number = 72;
  @State systemReduced: boolean = false;
  @State visible: boolean = false;
  @State playing: boolean = false;
  @State frames: PangolinFrame[] = [];
  @State runKey: number = 0;
  private reductionChanged = (reduced: boolean): void => { this.systemReduced = reduced; this.changed(); };

  aboutToAppear(): void {
    try {
      this.systemReduced = accessibility.isAnimationReduceEnabledSync();
      accessibility.onAnimationReduceStateChange(this.reductionChanged);
    } catch (error) { this.systemReduced = true; }
  }
  aboutToDisappear(): void {
    this.playing = false; this.runKey += 1;
    try { accessibility.offAnimationReduceStateChange(this.reductionChanged); } catch (error) {}
  }
  private changed(): void {
    this.runKey += 1;
    this.frames = pangolinFrames(this.state, this.reduceMotion || this.systemReduced);
    this.playing = this.allowPlayback && this.visible && this.frames.length > 0;
  }
  private pose(name: string): Resource {
    switch (name) {
      case 'wake': return $r('app.media.pangolin_wake');
      case 'walk_a': return $r('app.media.pangolin_walk_a');
      case 'walk_b': return $r('app.media.pangolin_walk_b');
      case 'plant': return $r('app.media.pangolin_plant');
      case 'ready': return $r('app.media.pangolin_ready');
      case 'alert': return $r('app.media.pangolin_alert');
      case 'wait': return $r('app.media.pangolin_wait');
      default: return $r('app.media.pangolin_rest');
    }
  }
  private images(): ImageFrameInfo[] {
    return this.frames.map((frame: PangolinFrame): ImageFrameInfo => {
      return { src: this.pose(frame.pose), duration: frame.duration, width: this.iconSize, height: this.iconSize };
    });
  }
  build() {
    Column() {
      ForEach([this.runKey], (key: number) => {
        if (this.playing) {
          ImageAnimator().images(this.images()).iterations(1).fillMode(FillMode.Forwards)
            .state(this.visible ? AnimationStatus.Running : AnimationStatus.Paused)
            .width(this.iconSize).height(this.iconSize).saturate(PANGOLIN_SATURATION)
            .onFinish(() => { if (key === this.runKey) { this.playing = false; } })
            .accessibilityLevel('no')
        } else {
          Image(this.pose(pangolinFinalPose(this.state))).objectFit(ImageFit.Contain)
            .width(this.iconSize).height(this.iconSize).saturate(PANGOLIN_SATURATION).accessibilityLevel('no')
        }
      }, (key: number) => `${key}`)
    }.width(this.allowPlayback ? this.iconSize : 0).height(this.allowPlayback ? this.iconSize : 0)
      .visibility(this.allowPlayback ? Visibility.Visible : Visibility.None).hitTestBehavior(HitTestMode.None)
      .onVisibleAreaChange([0, 1], (visible: boolean) => { this.visible = visible; if (!visible) { this.playing = false; } })
  }
}
