import { deadline } from './AsyncDeadline';
import { common } from '@kit.AbilityKit';
import { http, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import process from '@ohos.process';
import { DataplaneStatus } from '../net/DataplaneStatus';
import { probeIdentity, receiptSucceeded, probeSummary } from '../net/ProbeResult';
import { BUNDLE_NAME } from '../vpn/VpnConstants';
import { StatusStore } from './StatusStore';

const FETCH_TIMEOUT_MS: number = 8000;
const LOOP_MS: number = 2000;
const SUCCESS_RECHECK_MS: number = 30000;
const DNS_HOSTS: string[] = ['1.1.1.1', '8.8.8.8'];
const DNS_PORT: number = 53;
const DNS_QUESTION: string = 'www.google.com';
const BACKOFF_MAX_MS: number = 120000;
const FAILURE_RECHECK_MS: number = 15000;

class ProbeWork {
  valid: boolean = true;
  cancelActions: Array<() => void> = [];
  cancel(): void {
    this.valid = false;
    this.cancelActions.forEach((action: () => void) => { try { action(); } catch (_error) {} });
    this.cancelActions = [];
  }
  add(action: () => void): void { if (this.valid) this.cancelActions.push(action); else action(); }
  remove(action: () => void): void { this.cancelActions = this.cancelActions.filter((item) => item !== action); }
}
class HttpObservation {
  code: number = 0; errorCode: number = 0; stage: string = 'not-tested';
}
export class ProbeSelfCheck {
  private work: ProbeWork = new ProbeWork();
  private inflightWork: ProbeWork | null = null;
  private flight: Promise<void> | null = null;
  private batchId: string = '';
  private lastOkRid: string = '';
  private observedGeneration: string = '';
  private lastOkAt: number = 0;
  private loopId: number = -1;
  private failCount: number = 0;
  private nextRetryAt: number = 0;
  private foreground: boolean = true;
  private returnedAt: number = 0;

  setForeground(value: boolean): void {
    this.foreground = value;
    if (value) { this.returnedAt = Date.now(); this.lastOkAt = 0; this.nextRetryAt = 0; }
  }
  lastReturnAt(): number { return this.returnedAt; }
  startLoop(context: common.UIAbilityContext): void {
    if (this.loopId >= 0) return;
    this.work = new ProbeWork(); this.observedGeneration = '';
    this.loopId = setInterval(() => { this.tick(context).catch(() => {}); }, LOOP_MS);
    this.tick(context).catch(() => {});
  }
  stopLoop(): void {
    this.work.cancel(); this.inflightWork = null; this.flight = null;
    if (this.loopId >= 0) { clearInterval(this.loopId); this.loopId = -1; }
  }
  async tick(context: common.UIAbilityContext, force: boolean = false): Promise<void> {
    if (this.loopId < 0 || !this.work.valid) return;
    const status = StatusStore.readStatus(context);
    const identity = probeIdentity(status);
    if (identity !== this.observedGeneration) {
      this.work.cancel(); this.work = new ProbeWork(); this.inflightWork = null; this.flight = null;
      this.observedGeneration = identity; this.lastOkRid = ''; this.lastOkAt = 0; this.failCount = 0; this.nextRetryAt = 0;
    }
    if (this.flight !== null) { if (force) await this.flight; return; }
    if (this.inflightWork !== null || (!force && Date.now() < this.nextRetryAt)) return;
    if (!this.isLive(status)) return;
    const cadence = this.foreground ? SUCCESS_RECHECK_MS : 120000;
    if (!force && this.lastOkAt > 0 && Date.now() >= this.lastOkAt && Date.now() - this.lastOkAt < cadence) return;
    const work = this.work; this.inflightWork = work; this.batchId = util.generateRandomUUID();
    const flight = this.perform(context, status, work);
    this.flight = flight;
    try { await flight; } finally { if (this.flight === flight) this.flight = null; if (this.inflightWork === work) this.inflightWork = null; }
  }
  private async perform(context: common.UIAbilityContext, status: DataplaneStatus, work: ProbeWork): Promise<void> {
    try {
      const ok = await this.runFetch(context, status, work);
      if (!this.current(context, status, work)) return;
      if (ok) { this.lastOkRid = probeIdentity(status); this.lastOkAt = Date.now(); this.failCount = 0; this.nextRetryAt = 0; }
      else { this.lastOkRid = ''; this.failCount += 1;
        this.nextRetryAt = Date.now() + Math.min(BACKOFF_MAX_MS, FAILURE_RECHECK_MS * Math.pow(2, Math.min(4, this.failCount - 1))); }
    } catch (_error) {
      if (this.current(context, status, work)) { this.lastOkRid = ''; this.nextRetryAt = Date.now() + FAILURE_RECHECK_MS; }
    }
  }
  private current(context: common.UIAbilityContext, status: DataplaneStatus, work: ProbeWork): boolean {
    if (!work.valid || this.work !== work || this.loopId < 0) return false;
    const live = StatusStore.readStatus(context);
    return this.isLive(live) && probeIdentity(live) === probeIdentity(status);
  }
  async checkNow(context: common.UIAbilityContext): Promise<string> {
    const before = StatusStore.readStatus(context);
    if (!this.isLive(before)) return before.networkState === 'unavailable' ? '手机网络当前不可用，请恢复网络后检测。' : '当前没有可检测的运行隧道，请先连接。';
    if (this.loopId < 0) this.startLoop(context);
    const identity = probeIdentity(before);
    const run = this.tick(context, true);
    const batchId = this.batchId; const ownedWork = this.work;
    try { await deadline(run, 18000, '网络检测超时'); }
    catch (_error) {
      ownedWork.cancel();
      if (this.work === ownedWork && this.batchId === batchId) {
        this.work = new ProbeWork(); this.inflightWork = null; this.flight = null;
      }
      return '检测超时，已取消本次请求；未改变线路。';
    }
    const after = StatusStore.readStatus(context);
    if (probeIdentity(after) !== identity || !this.isLive(after)) return '检测期间网络或连接发生变化，旧结果已丢弃。';
    const raw = StatusStore.readText(context, 'probe-fetch.json');
    try { if (batchId.length === 0 || (JSON.parse(raw) as Record<string, Object>)['rid'] !== batchId) return '本次检测未取得回执，旧结果未被当成本次成功。'; }
    catch (_error) { return '本次检测结果无法读取，未改变线路。'; }
    return probeSummary(raw, after, Date.now()) || '本次未取得当前网络的完整结果，请重试。';
  }
  private isLive(status: DataplaneStatus): boolean {
    return status.desiredRunning && status.vpnCreated && status.tunFdValid && status.xrayRunning && status.forwarderOk &&
      !status.cleanupPending && !status.nativePoisoned && status.networkState !== 'unavailable' &&
      ['STOPPED','IDLE','ERROR','POISONED','RECONNECTING','STOP_UNCONFIRMED'].indexOf(status.phase) < 0 &&
      status.at > 0 && Date.now() >= status.at && Date.now() - status.at <= 25000;
  }
  private async runFetch(context: common.UIAbilityContext, status: DataplaneStatus, work: ProbeWork): Promise<boolean> {
    const rid = this.batchId; const startedAt = Date.now();
    const empty = Promise.resolve(new HttpObservation());
    const googleWork = status.routeMode === 'direct' ? empty : this.httpObserve(`https://www.google.com/generate_204?rid=${rid}`, false, work);
    const cloudWork = status.routeMode === 'direct' ? empty : this.httpObserve(`https://cp.cloudflare.com/generate_204?rid=${rid}`, false, work);
    const directWork = this.httpObserve(`https://www.baidu.com/robots.txt?rid=${rid}`, false, work);
    const dnsWork = this.probeDnsOk(DNS_QUESTION, work);
    const google = await googleWork, cloud = await cloudWork, direct = await directWork,
      dnsOk = await dnsWork;
    if (!this.current(context, status, work)) return false;
    const rec: Record<string, Object> = {
      'schema': 2, 'rid': rid, 'generation': status.generation, 'revision': status.sessionRevision,
      'ownerInstance': status.ownerInstance, 'networkEpoch': status.networkEpoch, 'policyDigest': status.payloadDigest,
      'scope': 'pangolin-ui-path', 'observedRoute': 'not-observed', 'routeMode': status.routeMode,
      'channelMode': status.channelMode, 'googleHttp': google.code, 'cloudflareHttp': cloud.code,
      'directHttp': direct.code,
      'dnsOk': dnsOk, 'dnsScope': 'raw-udp-application-path',
      'googleStage': google.stage, 'cloudflareStage': cloud.stage, 'domesticStage': direct.stage,
      'googleErrorCode': google.errorCode, 'cloudflareErrorCode': cloud.errorCode, 'domesticErrorCode': direct.errorCode,
      'pid': process.pid.toString(), 'uid': process.uid.toString(), 'bundle': BUNDLE_NAME,
      'source': 'entry-foreground', 'startedAt': startedAt, 'at': Date.now()
    };
    const stages: string[] = [];
    if (google.stage !== 'not-tested' && google.stage !== 'http') stages.push(`google:${google.stage}`);
    if (cloud.stage !== 'not-tested' && cloud.stage !== 'http') stages.push(`cloudflare:${cloud.stage}`);
    if (direct.stage !== 'http') stages.push(`domestic:${direct.stage}`);
    if (!dnsOk) stages.push('raw-dns:no-valid-answer');
    rec['failureStages'] = stages.join('; ');
    const ok = receiptSucceeded(rec, status.routeMode, status.channelMode === 'dual');
    rec['ackOk'] = ok; rec['failAck'] = !ok; rec['evidence'] = 'scoped-https-v2';
    StatusStore.writeText(context, 'probe-fetch.json', JSON.stringify(rec));
    return ok;
  }
  async probeDnsOk(question: string = DNS_QUESTION, work: ProbeWork | null = null): Promise<boolean> {
    for (let i = 0; i < DNS_HOSTS.length; i++) {
      if (work !== null && !work.valid) return false;
      if (await this.udpDns(DNS_HOSTS[i], DNS_PORT, question, work)) return true;
    }
    return false;
  }
  async probeHttpCode(url: string): Promise<number> { return this.httpCode(url); }
  private async httpCode(url: string, work: ProbeWork | null = null): Promise<number> {
    return (await this.httpObserve(url, false, work)).code;
  }
  private async httpObserve(url: string, head: boolean, work: ProbeWork | null = null): Promise<HttpObservation> {
    const result = new HttpObservation();
    if (work !== null && !work.valid) { result.stage = 'cancelled'; return result; }
    const client = http.createHttp(); let cancel: () => void = (): void => {};
    try {
      return await new Promise<HttpObservation>((resolve: (value: HttpObservation) => void) => {
        let done = false;
        const finish = (): void => { if (!done) { done = true; clearTimeout(timer); resolve(result); } };
        const timer = setTimeout(() => { result.stage = 'timeout'; try { client.destroy(); } catch (_error) {} finally { finish(); } }, FETCH_TIMEOUT_MS + 500);
        cancel = (): void => { result.stage = 'cancelled'; try { client.destroy(); } catch (_error) {} finally { finish(); } };
        work?.add(cancel); if (work !== null && !work.valid) return;
        client.request(url, { method: head ? http.RequestMethod.HEAD : http.RequestMethod.GET,
          usingCache: false, maxRedirects: 0, connectTimeout: FETCH_TIMEOUT_MS, readTimeout: FETCH_TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING, header: { 'User-Agent': 'Pangolin-network-check' }
        }).then((resp: http.HttpResponse) => {
          if (done) return; result.code = resp.responseCode; result.stage = 'http'; finish();
        }).catch((error: Object) => {
          if (done) return;
          const code = (error as Record<string, Object>)['code'];
          result.errorCode = typeof code === 'number' && Number.isFinite(code) ? code : 0;
          result.stage = code === 2300006 ? 'dns' : code === 2300007 ? 'connect' : code === 2300028 ? 'timeout' :
            code === 2300035 || code === 2300060 ? 'tls' : 'transport-unknown';
          finish();
        });
      });
    } catch (_error) { result.stage = 'transport-unknown'; return result; }
    finally { work?.remove(cancel); try { client.destroy(); } catch (_error) {} }
  }
  private async udpDns(host: string, port: number, question: string, work: ProbeWork | null = null): Promise<boolean> {
    if (work !== null && !work.valid) { return false; }
    let cancel: () => void = () => {};
    const udp = socket.constructUDPSocketInstance();
    const txid = Math.floor(Math.random() * 65535);
    try {
      let cancelBind: () => void = () => {};
      const cancelledBind = new Promise<void>((_resolve, reject) => {
        cancelBind = (): void => { reject(new Error('probe-cancelled')); };
        work?.add(cancelBind);
      });
      try {
        await deadline(Promise.race([udp.bind({ address: '0.0.0.0', port: 0, family: 1 }), cancelledBind]),
          3000, 'probe-bind-timeout');
      } finally { work?.remove(cancelBind); }
      if (work !== null && !work.valid) { return false; }
      const payload = this.buildDnsQuery(question, txid);
      let ok = false;
      await new Promise<void>((resolve: () => void) => {
        const timer = setTimeout(() => {
          resolve();
        }, 3000);
        cancel = (): void => { clearTimeout(timer); try { udp.close(); } finally { resolve(); } };
        work?.add(cancel);
        udp.on('message', (value: socket.SocketMessageInfo) => {
          const remote = value.remoteInfo;
          const addr = remote.address;
          const rport = remote.port;
          const msg = new Uint8Array(value.message);
          if (this.validateDnsResponse(msg, txid, question, addr, rport, host, port)) {
            ok = true;
            clearTimeout(timer);
            resolve();
          }
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
      work?.remove(cancel);
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
class DnsName { ok: boolean = false; name: string = ''; next: number = 0; }
export const PROBE_SELF_CHECK: ProbeSelfCheck = new ProbeSelfCheck();
