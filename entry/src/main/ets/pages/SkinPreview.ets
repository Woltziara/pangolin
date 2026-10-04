import { AnimatorResult } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { NativePage } from '../components/NativePage';
import { PangolinCompanion } from '../components/PangolinCompanion';

class PetObstacle {
  x: number = 0; y: number = 0; width: number = 0; height: number = 0;
}

@Entry
@Component
struct SkinPreview {
  @State state: string = 'idle';
  @State replay: number = 0;
  @State reduceMotion: boolean = false;
  @State petX: number = 0;
  @State petY: number = 0;
  @State petVisible: boolean = false;
  @State faceLeft: boolean = false;
  private motionTimer: number = -1;
  private travel: AnimatorResult | null = null;
  private reduceChanged = (value: boolean): void => { if (value) { this.stopTravel(); } };
  private widthVp: number = 0;
  private heightVp: number = 0;
  private originX: number = 0;
  private originY: number = 0;
  private dragX: number = 0;
  private dragY: number = 0;
  private obstacles: PetObstacle[] = [];

  private label(): string {
    return this.state === 'connecting' ? '正在连接' : this.state === 'connected' ? '已连接' :
      this.state === 'attention' ? '这条线路暂时连不上' : this.state === 'welcome' ? '欢迎使用穿山甲' : '已断开';
  }
  private free(x: number, y: number): boolean {
    if (x < 8 || y < 8 || x + 88 > this.widthVp - 8 || y + 88 > this.heightVp - 8) { return false; }
    const gx = x + this.originX, gy = y + this.originY;
    return !this.obstacles.some((b: PetObstacle) => gx < b.x + b.width + 8 && gx + 88 > b.x - 8 &&
      gy < b.y + b.height + 8 && gy + 88 > b.y - 8);
  }
  private place(): void {
    if (this.free(this.petX, this.petY)) { this.petVisible = true; return; }
    for (let y = 24; y + 96 < this.heightVp; y += 24) {
      for (let x = this.widthVp - 112; x >= 8; x -= 24) {
        if (this.free(x, y)) { this.petX = x; this.petY = y; this.petVisible = true; return; }
      }
    }
    this.petVisible = false;
  }
  private remember(index: number, area: Area): void {
    const b = new PetObstacle(); b.x = Number(area.globalPosition.x); b.y = Number(area.globalPosition.y);
    b.width = Number(area.width); b.height = Number(area.height);
    this.obstacles[index] = b; this.place();
  }
  aboutToAppear(): void { try { accessibility.onAnimationReduceStateChange(this.reduceChanged); } catch (error) {} }
  aboutToDisappear(): void {
    this.stopTravel();
    try { accessibility.offAnimationReduceStateChange(this.reduceChanged); } catch (error) {}
  }
  private stopTravel(): void {
    if (this.motionTimer >= 0) { clearTimeout(this.motionTimer); this.motionTimer = -1; }
    if (this.travel !== null) { this.travel.onFrame = () => {}; this.travel.cancel(); this.travel = null; }
  }
  private demonstrate(state: string): void {
    this.stopTravel();
    this.state = state; this.replay += 1;
    let reduced = true;
    try { reduced = this.reduceMotion || accessibility.isAnimationReduceEnabledSync(); } catch (error) {}
    if (state !== 'connecting' || reduced) { return; }
    const replay = this.replay;
    this.motionTimer = setTimeout(() => {
      if (this.state !== 'connecting' || this.replay !== replay) { return; }
      const direction = this.free(this.petX + 40, this.petY) ? 1 : this.free(this.petX - 40, this.petY) ? -1 : 0;
      if (direction === 0) { return; }
      this.faceLeft = direction < 0;
      const travel = this.getUIContext().createAnimator({ duration: 600, easing: 'linear', delay: 0,
        fill: 'forwards', direction: 'normal', iterations: 1, begin: this.petX, end: this.petX + direction * 40 });
      this.travel = travel;
      travel.onFrame = (x: number) => {
        if (this.state === 'connecting' && this.replay === replay && this.free(x, this.petY)) { this.petX = x; }
      };
      travel.onFinish = () => { if (this.travel === travel) { this.travel = null; } };
      travel.play();
    }, 360);
  }
  private advice(): void {
    AlertDialog.show({ title: '可能原因与建议',
      message: '默认建议顺序，不代表已经检测出故障。\n\n1. 当前节点暂时不可用：先换个节点。\n2. 连接遇到短暂波动：重试当前连接。\n3. 手机网络或连接服务异常：再查看本机诊断。',
      confirm: { value: '知道了', action: () => {} } });
  }
  private chooseNode(): void {
    ActionSheet.show({ title: '选择节点（演示）', message: '仅预览，不修改实际节点或连接。',
      sheets: [
        { title: '美国 · 演示节点', action: () => { this.demonstrate('connecting'); } },
        { title: '日本 · 演示节点', action: () => { this.demonstrate('connecting'); } },
        { title: '中国香港 · 演示节点', action: () => { this.demonstrate('connecting'); } }
      ] });
  }
  build() {
    Column() {
      NativePage({ title: '穿山甲皮肤预览', rootPage: false, maxContentWidth: 900 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Scroll() {
            Column({ space: 24 }) {
              Text('仅演示外观，不操作网络连接。').fontSize(14).width('100%')
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .onAreaChange((_old: Area, area: Area) => { this.remember(0, area); })
              Row({ space: 8 }) {
                Text(this.label()).fontSize(24).fontWeight(FontWeight.Medium).layoutWeight(1)
                  .fontColor(this.state === 'attention' ? $r('sys.color.ohos_id_color_warning') : $r('sys.color.ohos_id_color_text_primary'))
                if (this.state === 'attention') {
                  Button({ type: ButtonType.Normal }) {
                    SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(20)
                      .fontColor([$r('sys.color.ohos_id_color_warning')])
                  }.width(44).height(44).buttonStyle(ButtonStyleMode.TEXTUAL)
                    .accessibilityText('查看诊断与可能原因').onClick(() => { this.advice(); })
                }
              }.width('64%').height(100)
                .onAreaChange((_old: Area, area: Area) => { this.remember(1, area); })
              Row({ space: 12 }) {
                if (this.state === 'attention') {
                  Button('换个节点').onClick(() => { this.chooseNode(); })
                  Button('重试').buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => { this.demonstrate('connecting'); })
                }
              }.width('100%').onAreaChange((_old: Area, area: Area) => { this.remember(2, area); })
              Flex({ wrap: FlexWrap.Wrap }) {
                Button('演示欢迎').margin(4).onClick(() => { this.demonstrate('welcome'); })
                Button('演示连接').margin(4).onClick(() => { this.demonstrate('connecting'); })
                Button('演示完成').margin(4).onClick(() => { this.demonstrate('connected'); })
                Button('演示断开').margin(4).onClick(() => { this.demonstrate('idle'); })
                Button('演示异常').margin(4).onClick(() => { this.demonstrate('attention'); })
              }.width('100%').onAreaChange((_old: Area, area: Area) => { this.remember(3, area); })
              Row() {
                Text('静态外观').fontSize(16).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.reduceMotion })
                  .onChange((value: boolean) => { this.reduceMotion = value; if (value) { this.stopTravel(); } })
              }.width('100%').onAreaChange((_old: Area, area: Area) => { this.remember(4, area); })
              Text('小穿山甲可以拖到空白处，不挡住操作。高级皮肤设计预览。').fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
                .onAreaChange((_old: Area, area: Area) => { this.remember(5, area); })
            }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
          }.width('100%').height('100%').align(Alignment.TopStart)
          Column() {
            PangolinCompanion({ state: this.state, allowPlayback: true, replay: this.replay,
              reduceMotion: this.reduceMotion, iconSize: 88 })
          }.width(88).height(88).scale({ x: this.faceLeft ? -1 : 1 }).position({ x: this.petX, y: this.petY })
            .visibility(this.petVisible ? Visibility.Visible : Visibility.None)
            .gesture(PanGesture().onActionStart(() => { this.stopTravel(); this.dragX = this.petX; this.dragY = this.petY; })
              .onActionUpdate((event: GestureEvent) => {
                const x = this.dragX + event.offsetX, y = this.dragY + event.offsetY;
                if (this.free(x, y)) { this.petX = x; this.petY = y; }
              }))
        }.width('100%').height('100%').clip(true)
          .onAreaChange((_old: Area, area: Area) => {
            this.widthVp = Number(area.width); this.heightVp = Number(area.height);
            this.originX = Number(area.globalPosition.x); this.originY = Number(area.globalPosition.y); this.place();
          })
      }
    }.width('100%').height('100%')
  }
}
