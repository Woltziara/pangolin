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
  private activeAnimationState: string = '';
  private queuedState: string = '';
  private imageListKey: number = -1;
  private imageListSize: number = 0;
  private imageList: ImageFrameInfo[] = [];
  private reductionChanged = (reduced: boolean): void => { this.systemReduced = reduced; this.changed(); };

  aboutToAppear(): void {
    try {
      this.systemReduced = accessibility.isAnimationReduceEnabledSync();
      accessibility.onAnimationReduceStateChange(this.reductionChanged);
    } catch (error) { this.systemReduced = true; }
  }
  aboutToDisappear(): void {
    this.playing = false; this.runKey += 1;
    this.queuedState = ''; this.activeAnimationState = '';
    try { accessibility.offAnimationReduceStateChange(this.reductionChanged); } catch (error) {}
  }
  private changed(): void {
    if (this.playing && this.allowPlayback && this.visible && !this.reduceMotion && !this.systemReduced &&
      (this.state === this.activeAnimationState || this.state === 'connecting' && this.activeAnimationState === 'walking')) {
      return;
    }
    if (this.state === 'connected' && (this.activeAnimationState === 'connecting' || this.activeAnimationState === 'walking') && this.playing &&
      this.allowPlayback && this.visible && !this.reduceMotion && !this.systemReduced) {
      if (this.activeAnimationState === 'walking') {
        this.queuedState = '';
        this.beginState('connected');
        return;
      }
      this.queuedState = 'connected';
      return;
    }
    if (this.state === 'disconnecting' && this.activeAnimationState === 'connected' && this.playing) {
      this.queuedState = 'disconnecting';
      return;
    }
    if (this.state === 'idle' && this.playing &&
      (this.activeAnimationState === 'disconnecting' || this.queuedState === 'disconnecting')) {
      if (this.activeAnimationState === 'disconnecting') this.queuedState = 'idle';
      return;
    }
    this.queuedState = '';
    this.beginState(this.state);
  }
  private beginState(state: string): void {
    this.runKey += 1;
    this.activeAnimationState = state;
    this.frames = pangolinFrames(state, this.reduceMotion || this.systemReduced);
    this.playing = this.allowPlayback && this.visible && this.frames.length > 0;
  }
  private finishRun(key: number): void {
    if (key !== this.runKey) return;
    if (this.queuedState === 'connected' && this.state === 'connected') {
      this.queuedState = '';
      this.beginState('connected');
      return;
    }
    if (this.queuedState === 'disconnecting' && (this.state === 'disconnecting' || this.state === 'idle')) {
      this.queuedState = this.state === 'idle' ? 'idle' : '';
      this.beginState('disconnecting');
      return;
    }
    if (this.activeAnimationState === 'disconnecting' && this.state === 'idle') {
      this.queuedState = '';
      this.playing = false;
      this.activeAnimationState = '';
      return;
    }
    if ((this.activeAnimationState === 'connecting' || this.activeAnimationState === 'walking') &&
      this.state === 'connecting' && this.allowPlayback && this.visible &&
      !this.reduceMotion && !this.systemReduced) {
      this.beginState('walking');
      return;
    }
    this.playing = false;
    this.activeAnimationState = '';
  }
  private pose(name: string): Resource {
    switch (name) {
      case 'wake': return $r('app.media.pangolin_wake');
      case 'walk_a': return $r('app.media.pangolin_walk_a');
      case 'walk_b': return $r('app.media.pangolin_walk_b');
      case 'walk_01': return $r('app.media.pangolin_walk_01');
      case 'walk_02': return $r('app.media.pangolin_walk_02');
      case 'walk_03': return $r('app.media.pangolin_walk_03');
      case 'walk_04': return $r('app.media.pangolin_walk_04');
      case 'walk_05': return $r('app.media.pangolin_walk_05');
      case 'walk_06': return $r('app.media.pangolin_walk_06');
      case 'walk_07': return $r('app.media.pangolin_walk_07');
      case 'walk_08': return $r('app.media.pangolin_walk_08');
      case 'plant': return $r('app.media.pangolin_plant');
      case 'unplant': return $r('app.media.pangolin_unplant_v1');
      case 'stow': return $r('app.media.pangolin_stow_v1');
      case 'ready': return $r('app.media.pangolin_ready');
      case 'alert': return $r('app.media.pangolin_alert');
      case 'wait': return $r('app.media.pangolin_wait');
      default: return $r('app.media.pangolin_rest');
    }
  }
  private images(): ImageFrameInfo[] {
    if (this.imageListKey !== this.runKey || this.imageListSize !== this.iconSize) {
      this.imageList = this.frames.map((frame: PangolinFrame): ImageFrameInfo => {
        return { src: this.pose(frame.pose), duration: frame.duration, width: this.iconSize, height: this.iconSize };
      });
      this.imageListKey = this.runKey;
      this.imageListSize = this.iconSize;
    }
    return this.imageList;
  }
  build() {
    Column() {
      ForEach([this.runKey], (key: number) => {
        if (this.playing) {
          ImageAnimator().images(this.images()).iterations(this.activeAnimationState === 'walking' ? -1 : 1)
            .state(this.visible ? AnimationStatus.Running : AnimationStatus.Paused)
            .width(this.iconSize).height(this.iconSize).saturate(PANGOLIN_SATURATION)
            .onFinish(() => { if (this.activeAnimationState !== 'walking') this.finishRun(key); })
            .accessibilityLevel('no')
        } else {
          Image(this.pose(pangolinFinalPose(this.state))).objectFit(ImageFit.Contain)
            .width(this.iconSize).height(this.iconSize).saturate(PANGOLIN_SATURATION).accessibilityLevel('no')
        }
      }, (key: number) => `${key}`)
    }.width(this.allowPlayback ? this.iconSize : 0).height(this.allowPlayback ? this.iconSize : 0)
      .visibility(this.allowPlayback ? Visibility.Visible : Visibility.None).hitTestBehavior(HitTestMode.None)
      .onVisibleAreaChange([0, 1], (visible: boolean) => {
        this.visible = visible;
        if (visible) { this.changed(); }
        else { this.playing = false; this.queuedState = ''; this.activeAnimationState = ''; }
      })
  }
}
