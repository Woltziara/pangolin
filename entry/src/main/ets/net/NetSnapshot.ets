import { connection } from '@kit.NetworkKit';

export class NetLine {
  netId: number = -1;
  iface: string = '';
  dns: string = '';
  bearer: string = '';
  isDefault: boolean = false;
}

export class NetSnapshot {
  ok: boolean = false;
  error: string = '';
  defaultNetId: number = -1;
  defaultIface: string = '';
  defaultDns: string = '';
  defaultBearer: string = '';
  tunSeen: boolean = false;
  verdict: string = '尚未读取';
  lines: NetLine[] = [];
}

export class NetReader {
  static async read(): Promise<NetSnapshot> {
    const snap = new NetSnapshot();
    try {
      const defaultHandle = await connection.getDefaultNet();
      snap.defaultNetId = defaultHandle.netId;
      const defaultLine = await NetReader.describe(defaultHandle, true);
      snap.defaultIface = defaultLine.iface;
      snap.defaultDns = defaultLine.dns;
      snap.defaultBearer = defaultLine.bearer;

      const nets = await connection.getAllNets();
      const lines: NetLine[] = [];
      for (let index = 0; index < nets.length; index++) {
        const isDefault = nets[index].netId === snap.defaultNetId;
        const line = await NetReader.describe(nets[index], isDefault);
        if (line.iface.indexOf('vpn-tun') >= 0 || line.bearer.indexOf('VPN') >= 0) {
          snap.tunSeen = true;
        }
        lines.push(line);
      }
      snap.lines = lines;
      snap.ok = true;
      snap.verdict = NetReader.verdictOf(snap);
    } catch (error) {
      snap.error = JSON.stringify(error);
      snap.verdict = '读取失败';
    }
    return snap;
  }

  private static async describe(handle: connection.NetHandle, isDefault: boolean): Promise<NetLine> {
    const line = new NetLine();
    line.netId = handle.netId;
    line.isDefault = isDefault;
    try {
      const props = await connection.getConnectionProperties(handle);
      line.iface = props.interfaceName ?? '';
      line.dns = NetReader.dnsText(props);
    } catch (error) {
      line.iface = '(无法读网卡)';
    }
    try {
      const caps = connection.getNetCapabilitiesSync(handle);
      line.bearer = NetReader.bearerText(caps.bearerTypes ?? []);
    } catch (error) {
      line.bearer = '(无法读类型)';
    }
    return line;
  }

  private static dnsText(props: connection.ConnectionProperties): string {
    const dnses = props.dnses;
    if (dnses === undefined || dnses.length === 0) {
      return '';
    }
    const names: string[] = [];
    for (let i = 0; i < dnses.length; i++) {
      const item = dnses[i] as Object;
      if (typeof item === 'string') {
        names.push(item);
      } else {
        const addr = (item as connection.NetAddress).address;
        if (addr !== undefined && addr.length > 0) {
          names.push(addr);
        }
      }
    }
    return names.join(', ');
  }

  private static bearerText(types: connection.NetBearType[]): string {
    const names: string[] = [];
    for (let i = 0; i < types.length; i++) {
      const item = types[i];
      if (item === connection.NetBearType.BEARER_WIFI) {
        names.push('Wi-Fi');
      } else if (item === connection.NetBearType.BEARER_CELLULAR) {
        names.push('蜂窝');
      } else if (item === connection.NetBearType.BEARER_VPN) {
        names.push('VPN');
      } else if (item === connection.NetBearType.BEARER_ETHERNET) {
        names.push('有线');
      } else {
        names.push(`其他(${item})`);
      }
    }
    if (names.length === 0) {
      return '未知';
    }
    return names.join('+');
  }

  private static verdictOf(snap: NetSnapshot): string {
    const iface = snap.defaultIface;
    const bearer = snap.defaultBearer;
    if (iface.indexOf('vpn-tun') >= 0 || bearer.indexOf('VPN') >= 0) {
      return '系统默认网现在报成了 VPN。按鸿蒙合同这不该发生，不能当成成功条件。';
    }
    if (snap.tunSeen) {
      return '隧道网卡在。默认网仍是物理网，这是正常设计，不能说明浏览器没进隧道。';
    }
    return '还没有看到 vpn-tun。系统默认网继续显示物理网是正常的。';
  }
}
