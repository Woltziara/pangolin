@CustomDialog
export struct PangolinWelcome {
  controller?: CustomDialogController;
  message: string = '';
  build() {
    Column({ space: 16 }) {
      Image($r('app.media.pangolin_wait')).width(96).height(96).objectFit(ImageFit.Contain)
        .saturate(0.82).accessibilityLevel('no')
      Text('欢迎使用穿山甲').fontSize(22).fontWeight(FontWeight.Medium)
      Scroll() { Text(this.message).fontSize(15).width('100%') }.constraintSize({ maxHeight: 320 })
        .width('100%').align(Alignment.TopStart)
      Button('开始使用').width('100%').onClick(() => { this.controller?.close(); })
    }.width('100%').padding(24)
  }
}
