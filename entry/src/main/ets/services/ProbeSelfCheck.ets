import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { socket } from '@kit.NetworkKit';
import process from '@ohos.process';
import { DataplaneStatus, PHASE_CANARY_OK, PHASE_CORE_RUNNING, PHASE_DEGRADED_UNPROVEN,
  PHASE_FORWARDER_RUNNING, PHASE_STARTING, PHASE_UNPROVEN, PHASE_VPN_CREATED } from '../net/DataplaneStatus';
import { BUNDLE_NAME } from '../vpn/VpnConstants';
import { StatusStore } from './StatusStore';

const FETCH_TIMEOUT_MS: number = 8000;
const LOOP_MS: number = 2000;
const SUCCESS_RECHECK_MS: number = 30000;
const DNS_HOSTS: string[] = ['1.1.1.1', '8.8.8.8'];
const DNS_PORT: number = 53;
const DNS_QUESTION: string = 'www.google.com';
const BACKOFF_MAX_MS: number = 120000;

export class ProbeSelfCheck {
  private inflight: boolean = false;
  private lastOkRid: string = '';
  private observedGeneration: string = '';
  private lastOkAt: number = 0;
  private loopId: number = -1;
  private failCount: number = 0;
  private nextRetryAt: number = 0;

  startLoop(context: common.UIAbilityContext): void {
    if (this.loopId >= 0) {
      return;
    }
    this.loopId = setInterval(() => {
      this.tick(context).catch((error: Object) => {
        this.writeLoopError(context, error);
      });
    }, LOOP_MS);
    this.tick(context).catch((error: Object) => {
      this.writeLoopError(context, error);
    });
  }

  stopLoop(): void {
    if (this.loopId >= 0) {
      clearInterval(this.loopId);
      this.loopId = -1;
    }
  }

  async tick(context: common.UIAbilityContext): Promise<void> {
    if (this.inflight) {
      return;
    }
    const status = StatusStore.readStatus(context);
    if (status.generation !== this.observedGeneration) {
      this.observedGeneration = status.generation;
      this.lastOkRid = '';
      this.lastOkAt = 0;
      this.failCount = 0;
      this.nextRetryAt = 0;
    }
    if (Date.now() < this.nextRetryAt) {
      return;
    }
    if (!this.isLive(status) || !status.probePending || status.evidenceRid.length < 2) {
      return;
    }
    const sinceOk = Date.now() - this.lastOkAt;
    if (this.lastOkRid.length > 0 && sinceOk >= 0 && sinceOk < SUCCESS_RECHECK_MS) {
      return;
    }
    if (status.probeGoogleUrl.length < 8 || status.probeDirectUrl.length < 8) {
      return;
    }
    this.inflight = true;
    try {
      const ok = await this.runFetch(context, status);
      if (ok) {
        this.lastOkRid = status.evidenceRid;
        this.lastOkAt = Date.now();
        this.failCount = 0;
        this.nextRetryAt = 0;
      } else {
        this.lastOkRid = '';
        this.failCount += 1;
        let wait = 2000;
        for (let i = 1; i < this.failCount && wait < BACKOFF_MAX_MS; i++) {
          wait = wait * 2;
        }
        if (wait > BACKOFF_MAX_MS) {
          wait = BACKOFF_MAX_MS;
        }
        this.nextRetryAt = Date.now() + wait;
      }
    } catch (error) {
      this.lastOkRid = '';
      this.writeFetch(context, status, 0, 0, false, false, `${error}`);
      this.failCount += 1;
      this.nextRetryAt = Date.now() + 4000;
    } finally {
      this.inflight = false;
    }
  }

  /**
   * Phase D 诊断页复用入口：对既有 DNS 探针（1.1.1.1/8.8.8.8 查询 www.google.com）
   * 做一次按需检查。与后台循环共用同一份手写 DNS 实现，不复制逻辑。
   */
  async probeDnsOk(question: string = DNS_QUESTION): Promise<boolean> {
    for (let i = 0; i < DNS_HOSTS.length; i++) {
      if (await this.udpDns(DNS_HOSTS[i], DNS_PORT, question)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Phase D 诊断页复用入口：对给定 URL 做一次 HTTP GET 并返回状态码（0 = 失败）。
   * 与后台自证循环共用同一个 httpCode 实现与超时预算。
   */
  async probeHttpCode(url: string): Promise<number> {
    return this.httpCode(url);
  }

  private isLive(status: DataplaneStatus): boolean {
    return status.phase === PHASE_FORWARDER_RUNNING || status.phase === PHASE_CANARY_OK ||
      status.phase === PHASE_UNPROVEN || status.phase === PHASE_DEGRADED_UNPROVEN ||
      status.phase === PHASE_CORE_RUNNING || status.phase === PHASE_VPN_CREATED ||
      status.phase === PHASE_STARTING;
  }

  private async runFetch(context: common.UIAbilityContext, status: DataplaneStatus): Promise<boolean> {
    const googleWork = this.httpCode(status.probeGoogleUrl);
    const directWork = this.httpCode(status.probeDirectUrl);
    const dnsWork = this.probeDnsOk();
    const googleHttp = await googleWork;
    const directHttp = await directWork;
    const dnsOk = await dnsWork;
    const ackOk = googleHttp === 204 && directHttp >= 200 && directHttp < 400 && dnsOk;
    this.writeFetch(context, status, googleHttp, directHttp, dnsOk, ackOk, ackOk ? '' : 'fail-ack');
    return ackOk;
  }

  private writeFetch(context: common.UIAbilityContext, status: DataplaneStatus, googleHttp: number,
    directHttp: number, dnsOk: boolean, ackOk: boolean, error: string): void {
    const rec: Record<string, Object> = {};
    rec['rid'] = status.evidenceRid;
    rec['generation'] = status.generation;
    rec['revision'] = status.sessionRevision;
    rec['googleHttp'] = googleHttp;
    rec['directHttp'] = directHttp;
    rec['dnsOk'] = dnsOk;
    rec['ackOk'] = ackOk;
    rec['failAck'] = !ackOk;
    rec['pid'] = process.pid.toString();
    rec['uid'] = process.uid.toString();
    rec['bundle'] = BUNDLE_NAME;
    rec['source'] = 'entry-background';
    rec['evidence'] = 'http-204+dns';
    rec['error'] = error;
    rec['at'] = Date.now();
    rec['failCount'] = this.failCount;
    rec['nextRetryAt'] = this.nextRetryAt;
    StatusStore.writeText(context, 'probe-fetch.json', JSON.stringify(rec));
  }

  private writeLoopError(context: common.UIAbilityContext, error: Object): void {
    const rec: Record<string, Object> = {};
    rec['error'] = `${error}`;
    rec['at'] = Date.now();
    rec['source'] = 'entry-background';
    StatusStore.writeText(context, 'probe-loop-error.json', JSON.stringify(rec));
  }

  private async httpCode(url: string): Promise<number> {
    const client = http.createHttp();
    try {
      const code = await new Promise<number>((resolve: (value: number) => void) => {
        const timer = setTimeout(() => {
          resolve(0);
        }, FETCH_TIMEOUT_MS + 1000);
        client.request(url, {
          method: http.RequestMethod.GET,
          usingCache: false,
          connectTimeout: FETCH_TIMEOUT_MS,
          readTimeout: FETCH_TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING,
          header: { 'User-Agent': 'tongdao-self-probe' }
        }).then((resp: http.HttpResponse) => {
          clearTimeout(timer);
          resolve(resp.responseCode);
        }).catch(() => {
          clearTimeout(timer);
          resolve(0);
        });
      });
      return code;
    } catch (error) {
      return 0;
    } finally {
      try {
        client.destroy();
      } catch (error) {
        // ignore
      }
    }
  }

  private async udpDns(host: string, port: number, question: string): Promise<boolean> {
    const udp = socket.constructUDPSocketInstance();
    const txid = Math.floor(Math.random() * 65535);
    try {
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      const payload = this.buildDnsQuery(question, txid);
      let ok = false;
      await new Promise<void>((resolve: () => void) => {
        const timer = setTimeout(() => {
          resolve();
        }, 3000);
        udp.on('message', (value: socket.SocketMessageInfo) => {
          const remote = value.remoteInfo;
          const addr = remote.address;
          const rport = remote.port;
          const msg = new Uint8Array(value.message);
          if (this.validateDnsResponse(msg, txid, question, addr, rport, host, port)) {
            ok = true;
          }
          clearTimeout(timer);
          resolve();
        });
        udp.send({
          data: payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength),
          address: { address: host, port: port, family: 1 }
        }).catch(() => {
          clearTimeout(timer);
          resolve();
        });
      });
      return ok;
    } catch (error) {
      return false;
    } finally {
      try {
        udp.close();
      } catch (error) {
        // ignore
      }
    }
  }

  buildDnsQuery(name: string, txid: number): Uint8Array {
    const labels = name.split('.');
    let q = 0;
    for (let i = 0; i < labels.length; i++) {
      q += 1 + labels[i].length;
    }
    q += 1 + 4;
    const out = new Uint8Array(12 + q);
    out[0] = (txid >> 8) & 0xff;
    out[1] = txid & 0xff;
    out[2] = 0x01;
    out[5] = 0x01;
    let off = 12;
    for (let i = 0; i < labels.length; i++) {
      const lab = labels[i];
      out[off] = lab.length;
      off += 1;
      for (let j = 0; j < lab.length; j++) {
        out[off] = lab.charCodeAt(j);
        off += 1;
      }
    }
    out[off] = 0;
    off += 1;
    out[off] = 0;
    out[off + 1] = 1;
    out[off + 2] = 0;
    out[off + 3] = 1;
    return out;
  }

  validateDnsResponse(payload: Uint8Array, txid: number, question: string, source: string,
    sourcePort: number, expectSource: string, expectPort: number): boolean {
    if (source !== expectSource || sourcePort !== expectPort) {
      return false;
    }
    if (payload.length < 12) {
      return false;
    }
    const gotTxid = (payload[0] << 8) | payload[1];
    if (gotTxid !== txid) {
      return false;
    }
    const flags = (payload[2] << 8) | payload[3];
    const qr = (flags >> 15) & 1;
    const rcode = flags & 0x0f;
    if (qr !== 1 || rcode !== 0) {
      return false;
    }
    const qd = (payload[4] << 8) | payload[5];
    const an = (payload[6] << 8) | payload[7];
    if (qd !== 1 || an < 1) {
      return false;
    }
    const qName = this.readDnsName(payload, 12);
    if (!qName.ok || qName.name !== question.toLowerCase()) {
      return false;
    }
    let off = qName.next;
    if (off + 4 > payload.length) {
      return false;
    }
    const qtype = (payload[off] << 8) | payload[off + 1];
    const qclass = (payload[off + 2] << 8) | payload[off + 3];
    if (qtype !== 1 || qclass !== 1) {
      return false;
    }
    off += 4;
    let owner = question.toLowerCase();
    let sawA = false;
    for (let i = 0; i < an; i++) {
      const rr = this.readDnsName(payload, off);
      if (!rr.ok) {
        return false;
      }
      if (rr.name !== owner) {
        return false;
      }
      off = rr.next;
      if (off + 10 > payload.length) {
        return false;
      }
      const atype = (payload[off] << 8) | payload[off + 1];
      const aclass = (payload[off + 2] << 8) | payload[off + 3];
      const rdlen = (payload[off + 8] << 8) | payload[off + 9];
      off += 10;
      if (aclass !== 1 || rdlen < 1 || off + rdlen > payload.length) {
        return false;
      }
      if (atype === 1) {
        if (rdlen !== 4) {
          return false;
        }
        sawA = true;
        off += rdlen;
        break;
      }
      if (atype === 5) {
        const cname = this.readDnsName(payload, off);
        if (!cname.ok) {
          return false;
        }
        owner = cname.name;
        off += rdlen;
        continue;
      }
      return false;
    }
    return sawA;
  }

  private readDnsName(payload: Uint8Array, start: number): DnsName {
    const rec = new DnsName();
    rec.next = start;
    const labels: Array<string> = [];
    let offset = start;
    let jumped = false;
    let end = start;
    let hops = 0;
    while (hops < 20 && offset < payload.length) {
      const length = payload[offset];
      if (length === 0) {
        if (!jumped) {
          end = offset + 1;
        }
        rec.ok = labels.length > 0;
        rec.name = labels.join('.');
        rec.next = end;
        return rec;
      }
      if ((length & 0xc0) === 0xc0) {
        if (offset + 1 >= payload.length) {
          return rec;
        }
        const ptr = ((length & 0x3f) << 8) | payload[offset + 1];
        if (!jumped) {
          end = offset + 2;
        }
        offset = ptr;
        jumped = true;
        hops += 1;
        continue;
      }
      offset += 1;
      if (offset + length > payload.length) {
        return rec;
      }
      let lab = '';
      for (let i = 0; i < length; i++) {
        lab = `${lab}${String.fromCharCode(payload[offset + i])}`.toLowerCase();
      }
      labels.push(lab);
      offset += length;
      if (!jumped) {
        end = offset;
      }
      hops += 1;
    }
    return rec;
  }
}

class DnsName {
  ok: boolean = false;
  name: string = '';
  next: number = 0;
}

export const PROBE_SELF_CHECK: ProbeSelfCheck = new ProbeSelfCheck();
