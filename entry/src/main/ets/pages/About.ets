import { BuildIdentity } from '../services/BuildIdentity';
import { UiFeedback } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
// 穿山 (GPL-3.0) — 帮助与关于页（Phase D 新增）：纯静态中文内容 +
// 版本号读取（bundleManager，失败回退常量）+ 反馈邮箱复制。
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { DiagnosticReport, FALLBACK_APP_VERSION } from '../services/DiagnosticReport';

const FEEDBACK_EMAIL: string = 'tongdao-feedback@oscarwoltz.dev';

@Entry
@Component
struct About {
  @State versionName: string = FALLBACK_APP_VERSION;
  @State sourceIdentity: string = '';
  private context: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.sourceIdentity = BuildIdentity.source(this.context);
    DiagnosticReport.appVersion().then((version: string) => {
      this.versionName = version;
    }).catch(() => {
      this.versionName = FALLBACK_APP_VERSION;
    });
  }

  private copyEmail(): void {
    const board = pasteboard.getSystemPasteboard();
    const data = pasteboard.createPlainTextData(FEEDBACK_EMAIL);
    board.setData(data).then(() => {
      promptAction.showToast({ message: '邮箱已复制' });
    }).catch((error: Object) => {
      promptAction.showToast({ message: UiFeedback.failure(null, 'copy-contact', error, '复制未完成，请稍后重试。') });
    });
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_primary'))
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  @Builder
  Body(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      .width('100%')
      .lineHeight(20)
  }

  @Builder
  QA(question: string, answer: string) {
    Column() {
      Text(question)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')
      Text(answer)
        .fontSize(12)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .lineHeight(18)
        .margin({ top: 4 })
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  build() {
    Column() {
    NativePage({ title: '帮助与关于', rootPage: false }) {
    Column() {


      List({ space: 0 }) {
        ListItem() {
          Column() {
            this.SectionTitle('应用与服务')
            this.Body(`版本：${this.versionName}`)
            this.Body(this.sourceIdentity.length > 0 ? `源码身份：${this.sourceIdentity}` : '未嵌入实测构建身份；请通过 build_candidate.py 构建。')
            this.Body('本版提供单通道和双通道连接、配置与管理工具，不提供节点、网络流量或相关网络服务。你需要自行获取节点，并按服务提供方的要求使用。')
            this.SectionTitle('首次使用')
            this.Body('1. 在「节点」页打开导入入口，扫码、粘贴链接或选择配置文件\n' +
              '2. 选择一个节点，或保持自动选择\n' +
              '3. 回到「连接」页点连接，首次会弹出系统 VPN 授权，点允许即可')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.SectionTitle('VPN 权限说明')
            this.Body('首次连接时系统会弹出 VPN 授权对话框，这是 HarmonyOS 的强制要求：只有用户亲手允许，应用才能建立隧道。' +
              '穿山甲只用它创建本地 TUN 隧道，实际网络连接取决于你选择的节点和规则。节点及网络服务由你自行选择的服务提供方负责。')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.SectionTitle('支持的格式与协议')
            this.Body('当前可连接：trojan / vless / vmess（TLS）、vless Reality、ss（AEAD）。\n' +
              '可解析但暂不能连接：hysteria2 / tuic / anytls / wireguard / socks / http。\n' +
              '订阅内容：Clash YAML、SIP008 JSON、base64 编码的链接列表\n' +
              '导入方式：扫码、剪贴板粘贴、配置文件\n' +
              '导入预览会标明每个节点能否连接。')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.SectionTitle('常见问题')
            this.QA('连不上怎么办？',
              '先打开「诊断」点「保存故障现场」，再尝试恢复或一键检查。现场保存不发起网络请求、不重连；导出的完整文件可用于对照故障前后的运行状态。')
            this.QA('订阅更新失败？',
              '多数是订阅地址失效或网络不通。在「订阅」页点单条订阅的立即更新能看到具体错误；过期订阅需要向提供方续期后重新添加。')
            this.QA('为什么会自动切换节点？',
              '设置中开启自动切换备用节点后，当前节点连续检查失败时会尝试备用节点，首页会显示切换提示。未限定分组时可从全部节点选择；你可以在设置里关闭或限定分组。')
            this.QA('三种连接模式有什么区别？',
              '按规则连接：国内直连、其余走代理（推荐）；全局代理：几乎全部流量走代理；全部直连：VPN 开着但不代理，方便快速切回。')
            this.QA('我的数据存在哪里？',
              '节点、订阅、规则、设置和诊断记录保存在本机应用沙箱。运行时节点配置另用 HUKS 加密；节点目录仍包含连接所需凭据，导出的配置文件也含凭据，请勿分享给他人。连接时会联系你选择的节点，更新订阅时会访问你提供的订阅地址。')
            this.QA('后台为什么不更新订阅？',
              '系统对后台任务有配额：循环任务最短 2 小时一次，且长期不使用的应用会被系统降频。这是平台限制，不是故障。')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.SectionTitle('隐私政策与用户协议')
            this.Body('隐私说明：本版不设软件账号、不做云同步或开发者遥测上报。节点、订阅、规则和设置保存在本机应用沙箱。' +
              '连接功能会处理并转发网络流量至你选择的节点；DNS 解析和连接状态检查会访问相应网络服务，订阅更新会访问你提供的地址。' +
              '本版不记录详细访问日志或聊天内容。VPN 运行时在本机滚动记录网络变化、转发和分流计数，最多保留 48 小时且受 4 MiB 容量限制；满后提前淘汰，不自动上传。' +
              '你主动保存的故障现场另保留最近 5 份，报告已脱敏（不含密码、UUID 和订阅链接）；可在设置中清理日志。' +
              '你可导出配置或删除本地数据；导出的配置文件包含节点凭据，请妥善保管。\n\n' +
              '用户协议：节点需你自备并保证来源合法；你自行承担使用节点产生的全部责任。' +
              '穿山甲只是工具，不提供、不出售、不推荐任何节点服务。')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.SectionTitle('开源许可')
            this.Body('穿山甲以 GPL-3.0 发布。借用的开源组件：\n' +
              '· Hey（GPL-3.0）— N-API 桥、VPN 扩展生命周期与交叉编译配方\n' +
              '· Xray-core（MPL-2.0）— 代理内核 libxray.so\n' +
              '· libXray（MIT）— CGo 导出层\n' +
              '· hev-socks5-tunnel（MIT）— TUN 到 SOCKS 的数据面\n' +
              '完整清单见安装包内 THIRD-PARTY-NOTICES。')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.SectionTitle('版本')
            Text(`穿山甲 ${this.versionName}`)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .width('100%')

            this.SectionTitle('反馈')
            Row() {
              Text(FEEDBACK_EMAIL)
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .layoutWeight(1)
              Button('复制')
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
                .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                .borderRadius(16)
                .constraintSize({ minHeight: 48 })
                .onClick(() => {
                  this.copyEmail();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 24 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
    }
    }.width('100%').height('100%')
  }
}
