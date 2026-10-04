import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection, http } from '@kit.NetworkKit';
import { SocksSession } from '../core/XrayRuntime';
import { socksHttpCanary } from '../net/DataplaneCanary';
import { StatusStore } from './StatusStore';
import { getNativeStats } from '../native/TunnelNative';

interface HttpTarget {
  name: string;
  url: string;
  method: http.RequestMethod;
}

interface SocksTarget {
  name: string;
  host: string;
  path: string;
}

const HTTP_TARGETS: HttpTarget[] = [
  { name: 'google-http', url: 'http://www.google.com/generate_204', method: http.RequestMethod.GET },
  { name: 'google-https', url: 'https://www.google.com/generate_204', method: http.RequestMethod.GET },
  { name: 'qq-https-head', url: 'https://www.qq.com/', method: http.RequestMethod.HEAD },
  { name: 'chatgpt-https-head', url: 'https://chatgpt.com/', method: http.RequestMethod.HEAD }
];

const ANDROID_HTTP_TARGETS: HttpTarget[] = [
  { name: 'android-chatgpt-https-head', url: 'https://android.chat.openai.com/', method: http.RequestMethod.HEAD },
  { name: 'chatgpt-https-head', url: 'https://chatgpt.com/', method: http.RequestMethod.HEAD }
];

const SOCKS_TARGETS: SocksTarget[] = [
  { name: 'baidu-http', host: 'www.baidu.com', path: '/' },
  { name: 'google-http', host: 'www.google.com', path: '/generate_204' },
  { name: 'youtube-http', host: 'www.youtube.com', path: '/generate_204' }
];

class LatencyBatch {
  schema: string = 'chuanshan-latency@1';
  path: string = '';
  runId: string = '';
  generation: string = '';
  startedAt: number = Date.now();
  at: number = Date.now();
  complete: boolean = false;
  outcome: string = 'running';
  timingKind: string = 'cumulative-ms-from-request-start';
  forceFreshConnections: boolean = false;
  samples: Array<Record<string, Object>> = [];
}

// Explicit one-shot diagnostics only. No periodic scheduling, URL input,
// cookies, response bodies, or credentials are recorded. No health/failover
// state is updated by these measurements.
class LatencyProbe {
  private httpBusy: boolean = false;
  private socksBusy: boolean = false;
  private lastHttpId: string = '';
  private lastSocksId: string = '';

  validRunId(runId: string): boolean {
    return /^[a-zA-Z0-9_-]{1,64}$/.test(runId);
  }

  private live(context: common.Context, generation: string): boolean {
    const status = StatusStore.readStatus(context);
    return status.generation === generation && status.desiredRunning &&
      status.xrayRunning && status.forwarderOk && Date.now() - status.at < 45000;
  }

  private publish(context: common.Context, batch: LatencyBatch): void {
    batch.at = Date.now();
    let filename = 'latency-http.json';
    if (batch.path === 'local-socks') { filename = 'latency-socks.json'; }
    if (batch.path === 'native-http-over-socks-proxy-dns') { filename = 'latency-native-socks.json'; }
    StatusStore.writeText(context, filename, JSON.stringify(batch));
  }

  async runHttp(context: common.Context, runId: string, socks: SocksSession | null = null,
    forceFresh: boolean = false, androidEndpoint: boolean = false): Promise<void> {
    if (!this.validRunId(runId) || this.httpBusy || runId === this.lastHttpId) {
      return;
    }
    this.httpBusy = true;
    this.lastHttpId = runId;
    const batch = new LatencyBatch();
    batch.path = socks === null ? 'entry-networkkit-transparent-tun' : 'native-http-over-socks-proxy-dns';
    batch.forceFreshConnections = forceFresh;
    batch.runId = runId;
    batch.generation = StatusStore.readStatus(context).generation;
    const targets: HttpTarget[] = androidEndpoint ? ANDROID_HTTP_TARGETS : HTTP_TARGETS;
    try {
      this.publish(context, batch);
      for (let round = 1; round <= 2; round++) {
        for (let i = 0; i < targets.length; i++) {
          if (!this.live(context, batch.generation)) {
            batch.outcome = 'session-not-live-or-changed';
            return;
          }
          const sample = await this.httpSample(targets[i], socks, forceFresh);
          sample['round'] = round;
          batch.samples.push(sample);
          this.publish(context, batch);
        }
      }
      batch.outcome = 'measured';
    } finally {
      batch.complete = true;
      this.httpBusy = false;
      this.publish(context, batch);
    }
  }

  private async httpSample(target: HttpTarget, socks: SocksSession | null,
    forceFresh: boolean): Promise<Record<string, Object>> {
    const sample: Record<string, Object> = {};
    const started = Date.now();
    const protectBefore = getNativeStats();
    const client = http.createHttp();
    sample['target'] = target.name;
    sample['method'] = target.method;
    sample['startedAt'] = started;
    sample['responseCode'] = 0;
    let timer: number = -1;
    try {
      const options: http.HttpRequestOptions = {
        method: target.method,
        usingCache: false,
        reuseConnections: !forceFresh,
        connectTimeout: 6000,
        readTimeout: 6000,
        maxLimit: 1024 * 1024,
        expectDataType: http.HttpDataType.STRING,
        header: { 'User-Agent': 'chuanshan-latency-probe' }
      };
      if (socks !== null) {
        options.usingSocks5Proxy = {
          host: socks.host,
          port: socks.port,
          username: socks.user,
          password: socks.pass,
          dnsStrategy: connection.Socks5DnsStrategy.PROXY_MODE
        };
      }
      const timeout = new Promise<http.HttpResponse>((_resolve: (value: http.HttpResponse) => void,
        reject: (reason: Error) => void) => {
        timer = setTimeout(() => { reject(new Error('diagnostic-deadline')); }, 14000);
      });
      const response = await Promise.race([client.request(target.url, options), timeout]);
      sample['responseCode'] = response.responseCode;
      sample['performance'] = response.performanceTiming;
      const extra = response.connectionExtraInfo;
      sample['requestedFresh'] = forceFresh;
      sample['requestedSocks'] = socks !== null;
      sample['socksConfirmed'] = socks !== null && extra !== undefined && extra.isProxyConnection;
      if (extra !== undefined) {
        const connection: Record<string, Object> = {};
        connection['protocol'] = extra.networkProtocolName;
        connection['reused'] = extra.isReusedConnection;
        connection['cacheHit'] = extra.isCacheHit;
        connection['redirectCount'] = extra.redirectCount;
        // Fixed public diagnostic destinations only; never record local IPs.
        connection['remoteAddress'] = extra.remoteAddress;
        connection['httpExplicitProxy'] = extra.isProxyConnection;
        sample['connection'] = connection;
      }
    } catch (error) {
      const business = error as BusinessError;
      sample['errorCode'] = typeof business.code === 'number' ? business.code : -1;
    } finally {
      if (timer >= 0) { clearTimeout(timer); }
      sample['wallMs'] = Date.now() - started;
      if (socks !== null) {
        const after = getNativeStats();
        sample['protectCallsDelta'] = after.protectMeasured - protectBefore.protectMeasured;
        sample['protectTotalUsDelta'] = after.protectTotalUs - protectBefore.protectTotalUs;
        sample['protectMaxUsLifetime'] = after.protectMaxUs;
        sample['protectTcp4Delta'] = after.protectTcp4 - protectBefore.protectTcp4;
        sample['protectTcp6Delta'] = after.protectTcp6 - protectBefore.protectTcp6;
        sample['protectUdpDelta'] = after.protectUdp - protectBefore.protectUdp;
        if (after.protectTcp4 - protectBefore.protectTcp4 === 1 && after.protectTcp4At >= started) {
          sample['tcp4AttemptMs'] = after.protectTcp4At - started;
        }
        if (after.protectTcp6 - protectBefore.protectTcp6 === 1 && after.protectTcp6At >= started) {
          sample['tcp6AttemptMs'] = after.protectTcp6At - started;
        }
      }
      client.destroy();
    }
    return sample;
  }

  async runSocks(context: common.Context, socks: SocksSession, generation: string,
    runId: string): Promise<void> {
    if (!this.validRunId(runId) || this.socksBusy || runId === this.lastSocksId) {
      return;
    }
    this.socksBusy = true;
    this.lastSocksId = runId;
    const batch = new LatencyBatch();
    batch.path = 'local-socks';
    batch.runId = runId;
    batch.generation = generation;
    try {
      this.publish(context, batch);
      for (let round = 1; round <= 2; round++) {
        for (let i = 0; i < SOCKS_TARGETS.length; i++) {
          if (!this.live(context, generation) || socks.port <= 0) {
            batch.outcome = 'session-not-live-or-changed';
            return;
          }
          const target = SOCKS_TARGETS[i];
          const result = await socksHttpCanary(socks.host, socks.port, target.host, 80,
            target.host, target.path, 6000, socks.user, socks.pass);
          const sample: Record<string, Object> = {};
          sample['target'] = target.name;
          sample['round'] = round;
          sample['ok'] = result.ok;
          sample['responseCode'] = result.httpCode;
          sample['wallMs'] = result.elapsedMs;
          sample['marks'] = result.marks;
          batch.samples.push(sample);
          this.publish(context, batch);
        }
      }
      batch.outcome = 'measured';
    } finally {
      batch.complete = true;
      this.socksBusy = false;
      this.publish(context, batch);
    }
  }
}

export const LATENCY_PROBE = new LatencyProbe();
