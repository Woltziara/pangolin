import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, hdsMaterial } from '@kit.UIDesignKit';

@Component
export struct NativePage {
  @Prop maxContentWidth: number = 1440;
  @Prop hideTitle: boolean = false;
  @Prop title: string = '';
  @Prop rootPage: boolean = false;
  @BuilderParam content: () => void;

  @Builder
  Body() {
    Row() {
      Column() { this.content() }
        .width('100%')
        .constraintSize({ maxWidth: this.maxContentWidth })
        .height('100%')
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  build() {
    if (canIUse('SystemCapability.UIDesign.HDSComponent.Core')) {
      HdsNavigation() { this.Body() }
        .titleBar({ enableComponentSafeArea: true, content: {
          title: { mainTitle: this.title },
          backIcon: { action: () => { router.back(); } }
        }, style: { systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        } } })
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(this.rootPage)
        .hideTitleBar(this.hideTitle)
        .mode(NavigationMode.Stack)
        .width('100%').height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
    } else {
      NavDestination() { this.Body() }
        .title(this.title)
        .hideBackButton(this.rootPage)
        .hideTitleBar(this.hideTitle)
        .onBackPressed(() => { router.back(); return true; })
        .width('100%').height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
    }
  }
}
