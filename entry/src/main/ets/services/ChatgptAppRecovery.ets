import { common } from '@kit.AbilityKit';

const ABROAD_BUNDLE: string = 'com.easy.hmos.abroad';
const ABROAD_ABILITY: string = 'EntryAbility';

// HarmonyOS does not grant third-party VPN apps the cross-app kill permission
// required for Anco/Abroad container packages. Keep this shortcut honest: it
// opens the supported manager and never claims that a restart already happened.
export class ChatgptAppRecovery {
  static async openManager(context: common.UIAbilityContext): Promise<string> {
    await context.startAbility({
      deviceId: '',
      bundleName: ABROAD_BUNDLE,
      abilityName: ABROAD_ABILITY
    });
    return '我的 → 应用管理：先强行停止 ChatGPT，再强行停止出境服务框架；先打开出境服务框架，再打开 ChatGPT。';
  }
}
