import { vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';

export const BUNDLE_NAME: string = 'com.oscarwoltz.tongdao';
export const BROWSER_BUNDLE: string = 'com.huawei.hmos.browser';
export const VPN_ABILITY_NAME: string = 'TunnelVpnAbility';
export const VPN_INTERFACE_NAME: string = 'vpn-tun';
export const VPN_COMMAND_KEY: string = 'command';
export const VPN_COMMAND_STOP: string = 'stop';
export const VPN_MODE_KEY: string = 'mode';
export const VPN_GENERATION_KEY: string = 'generation';
export const MODE_PROBE_BROWSER: string = 'probe-browser';
export const MODE_PROBE_SELF: string = 'probe-self';
export const MODE_FULL: string = 'full';
export const TUN_IPV4: string = '10.7.0.2';
export const TUN_IPV6: string = 'fd00:7::2';
export const TUN_IPV6_GATEWAY: string = 'fd00:7::1';
export const VPN_MTU: number = 1400;
export const VPN_DNS: string[] = ['1.1.1.1', '8.8.8.8'];
export const XRAY_CONFIG_PARAM: string = 'xrayConfigJson';

const FAMILY_IPV4: number = 1;
const FAMILY_IPV6: number = 2;

export function createStartWant(mode: string, generation: string): Want {
  return {
    deviceId: '',
    bundleName: BUNDLE_NAME,
    abilityName: VPN_ABILITY_NAME,
    parameters: {
      mode: mode as Object,
      generation: generation as Object
    }
  };
}

export function createVpnAbilityWant(): Want {
  return {
    deviceId: '',
    bundleName: BUNDLE_NAME,
    abilityName: VPN_ABILITY_NAME
  };
}

export function createStopWant(generation: string = ''): Want {
  const want = createVpnAbilityWant();
  want.parameters = {
    command: VPN_COMMAND_STOP as Object,
    generation: generation as Object
  };
  return want;
}

export function createTunnelVpnConfig(trustedApps: string[]): vpnExtension.VpnConfig {
  const addresses: Array<vpnExtension.LinkAddress> = [
    {
      address: {
        address: TUN_IPV4,
        family: FAMILY_IPV4
      },
      prefixLength: 30
    },
    {
      address: {
        address: TUN_IPV6,
        family: FAMILY_IPV6
      },
      prefixLength: 64
    }
  ];
  const config: vpnExtension.VpnConfig = {
    addresses: addresses,
    routes: [
      createIpv4DefaultRoute(),
      createIpv6DefaultRoute()
    ],
    dnsAddresses: VPN_DNS,
    mtu: VPN_MTU,
    isIPv4Accepted: true,
    isIPv6Accepted: true
  };
  if (trustedApps.length > 0) {
    config.trustedApplications = trustedApps;
  }
  // MODE_FULL: do not exclude the UI process. CGo sockets are excluded
  // per-fd via VpnConnection.protect, reached through NAPI TSFN.
  // protectProcessNet only covers ArkTS NetworkKit in this process.
  // The EntryAbility worker must traverse the system TUN for self-check.
  return config;
}

export function trustedAppsForMode(mode: string): string[] {
  if (mode === MODE_PROBE_BROWSER) {
    return [BROWSER_BUNDLE];
  }
  if (mode === MODE_PROBE_SELF) {
    return [BUNDLE_NAME];
  }
  return [];
}

function createIpv4DefaultRoute(): vpnExtension.RouteInfo {
  return {
    interface: VPN_INTERFACE_NAME,
    destination: {
      address: {
        address: '0.0.0.0',
        family: FAMILY_IPV4
      },
      prefixLength: 0
    },
    gateway: {
      address: '0.0.0.0',
      family: FAMILY_IPV4,
      port: 0
    },
    hasGateway: false,
    isDefaultRoute: true
  };
}

function createIpv6DefaultRoute(): vpnExtension.RouteInfo {
  // 同平台实测：HarmonyOS 上 ::/0 必须空 gateway，且 isDefaultRoute=false，
  // 否则 v6 仍可能从 Wi-Fi 旁路。IPv4 默认路由仍是 isDefaultRoute=true。
  return {
    interface: VPN_INTERFACE_NAME,
    destination: {
      address: {
        address: '::',
        family: FAMILY_IPV6
      },
      prefixLength: 0
    },
    gateway: { address: '' },
    hasGateway: false,
    isDefaultRoute: false
  };
}
