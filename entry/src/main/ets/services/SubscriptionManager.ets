// 穿山 (GPL-3.0) — 订阅抓取与导入编排。
// 抓取逻辑（手动重定向链 ≤5、Accept-Encoding: identity、IDN 规范化）参考
// Hey (GPL-3.0) entry/src/main/ets/services/SubscriptionManager.ets，移植日期 2026-09-06。
// Hey: https://github.com/popsiclelmlm/Hey （GPL-3.0）。
// 解析 subscription-userinfo 响应头。订阅下载采用 Clash/Mihomo 格式兼容标识；
// 后缀保留本客户端身份。这只是订阅格式协商，不代表使用 Mihomo 连接内核。
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { encodeUtf8ToBase64 } from '../core/Encoding';
import { toIdnUrl } from '../core/IdnUrl';
import { publicFailure, redactDiagnosticText } from '../core/UserFacingCopy';
import { ParsedNode, ShareLinkFailure } from '../core/ShareLinkParser';
import { classifyImport, ImportKind, looksLikeHtmlContent, parseSubscriptionContent } from '../core/SubscriptionParser';
import { NodeStore } from './NodeStore';
import { SubscriptionRecord, SubscriptionStore, SubscriptionUserinfo } from './SubscriptionStore';
import { StatusStore } from './StatusStore';
import { VPN_DNS } from '../vpn/VpnConstants';
import { PROBE_SELF_CHECK } from './ProbeSelfCheck';

export const APP_USER_AGENT: string = 'mihomo/1.19.0 (compatible; Pangolin)';
const MAX_REDIRECTS: number = 5;
const HTTP_TIMEOUT_MS: number = 30000;

export class FetchOptions {
  userAgent: string = '';
  allowInsecureHttp: boolean = false;
  proxyPort: number = 0;
  dnsServers: string[] = [];
}

export class FetchResult {
  content: string = '';
  userinfo: SubscriptionUserinfo | null = null;
}

export class UpdateResult {
  ok: boolean = false;
  message: string = '';
  nodeCount: number = 0;
}

export class ImportPreview {
  kind: ImportKind = 'unknown';
  nodes: Array<ParsedNode> = [];
  failures: Array<ShareLinkFailure> = [];
  duplicates: number = 0;
}

export class CommitSummary {
  added: number = 0;
  skippedDuplicates: number = 0;
}

interface SubscriptionRequestHeader {
  'User-Agent': string;
  'Accept': string;
  'Accept-Encoding': string;
  'Content-Type': string;
  Authorization?: string;
}

export class SubscriptionManager {
  /** 抓取订阅内容；失败抛出带中文信息的 Error。 */
  static async fetchSubscription(url: string, opts: FetchOptions): Promise<FetchResult> {
    const trimmedUrl = url.trim();
    const requestUrl = toIdnUrl(trimmedUrl);
    const validationMessage = SubscriptionManager.validateSubscriptionUrl(requestUrl, opts.allowInsecureHttp);
    if (validationMessage.length > 0) {
      throw new Error(validationMessage);
    }
    return SubscriptionManager.fetchText(requestUrl, 0, opts);
  }

  /**
   * 更新单条订阅：抓取 → 解析 → 去重合并进 NodeStore（保留运行时字段）→
   * 回写 SubscriptionStore（lastUpdateAt/lastError/userinfo/nodeCount）。
   */
  static async updateSubscription(context: common.Context, id: string): Promise<UpdateResult> {
    const record = SubscriptionStore.findById(context, id);
    const result = new UpdateResult();
    if (record === null) {
      result.message = '订阅不存在。';
      return result;
    }

    const snapshotUrl = record.url;
    const snapshotEnabled = record.enabled;
    let fetched: FetchResult;
    try {
      const opts = new FetchOptions();
      const plane = StatusStore.readStatus(context);
      if (plane.vpnCreated && plane.tunFdValid && plane.xrayRunning && plane.forwarderOk) {
        // Use this request's resolver inside the active tunnel. System-service
        // resolution can use a different network than the app's HTTP socket.
        opts.dnsServers = VPN_DNS.slice();
      }
      fetched = await SubscriptionManager.fetchSubscription(record.url, opts);
    } catch (error) {
      result.message = SubscriptionManager.describeFetchError(error);
      if ((error as Record<string, Object>)['code'] === 2300006) {
        const match = /^https?:\/\/(?:[^/@]+@)?([^/:?#]+)/i.exec(record.url);
        if (match !== null) {
          const directDns = await PROBE_SELF_CHECK.probeDnsOk(match[1]);
          const googleDns = await PROBE_SELF_CHECK.probeDnsOk();
          const check: Record<string, Object> = {};
          check['at'] = Date.now(); check['sdkDnsCode'] = 2300006;
          check['rawSubscriptionDnsOk'] = directDns; check['rawControlDnsOk'] = googleDns;
          StatusStore.writeText(context, 'subscription-dns-check.json', JSON.stringify(check));
        }
      }
      const still = SubscriptionStore.findById(context, id);
      if (still !== null && still.url === snapshotUrl) {
        still.lastError = result.message;
        SubscriptionStore.update(context, still);
      }
      return result;
    }

    const live = SubscriptionStore.findById(context, id);
    if (live === null || !live.enabled || live.url !== snapshotUrl || !snapshotEnabled) {
      result.message = '订阅已删除、关闭或已更改，未写入节点';
      return result;
    }

    const outcome = parseSubscriptionContent(fetched.content);
    if (outcome.nodes.length === 0) {
      result.message = outcome.format === 'unknown'
        ? (looksLikeHtmlContent(fetched.content) ? '该地址返回的是网页内容而不是配置数据。' : '内容无法识别。')
        : '没有可用节点。';
      live.lastError = result.message;
      SubscriptionStore.update(context, live);
      return result;
    }

    const merge = NodeStore.mergeRuntime(context, outcome.nodes, live.id);
    live.lastUpdateAt = Date.now();
    live.lastError = '';
    live.userinfo = fetched.userinfo;
    live.nodeCount = outcome.nodes.length;
    SubscriptionStore.update(context, live);

    result.ok = true;
    result.nodeCount = outcome.nodes.length;
    result.message = outcome.skipped > 0
      ? `订阅更新完成，共 ${outcome.nodes.length} 个可用节点，跳过 ${outcome.skipped} 条不支持的记录（新增 ${merge.added}，更新 ${merge.updated}）。`
      : `订阅更新完成，共 ${outcome.nodes.length} 个可用节点（新增 ${merge.added}，更新 ${merge.updated}）。`;
    return result;
  }

  /**
   * 文本导入预览（不落盘）：区分单个节点 / 订阅内容，统计与现有节点的重复数。
   */
  static importFromText(context: common.Context, text: string): ImportPreview {
    const preview = new ImportPreview();
    const kind = classifyImport(text);
    preview.kind = kind;
    if (kind === 'single-node') {
      const outcome = parseSubscriptionContent(text.trim());
      preview.nodes = outcome.nodes;
      preview.failures = outcome.failures;
    } else if (kind === 'subscription-content') {
      const outcome = parseSubscriptionContent(text);
      preview.nodes = outcome.nodes;
      preview.failures = outcome.failures;
    }
    if (preview.nodes.length > 0) {
      const existing = NodeStore.loadNodes(context);
      const merge = NodeStore.mergeParsedNodes(existing, preview.nodes, 'preview');
      preview.duplicates = merge.updated + merge.skippedDuplicates;
    }
    return preview;
  }


  /**
   * 确认导入：写入 NodeStore，sourceId 由调用方给出（'manual'/'import'/subscriptionId）；
   * 与既有节点重复的跳过并计数。
   */
  static commitImport(context: common.Context, nodes: Array<ParsedNode>, sourceId: string): CommitSummary {
    const merge = NodeStore.upsertNodes(context, nodes, sourceId);
    const summary = new CommitSummary();
    summary.added = merge.added;
    summary.skippedDuplicates = merge.skippedDuplicates + merge.updated;
    return summary;
  }

  static validateSubscriptionUrl(url: string, allowInsecureHttp: boolean): string {
    const trimmedUrl = url.trim();
    if (!SubscriptionManager.isHttpUrl(trimmedUrl)) {
      return '订阅地址无效：必须是 http:// 或 https:// 链接。';
    }
    if (!allowInsecureHttp && trimmedUrl.toLowerCase().startsWith('http://')) {
      return '订阅地址无效：HTTP 明文链接不安全，请改用 https://。';
    }
    return '';
  }

  private static describeFetchError(error: Object): string {
    const text = error instanceof Error ? error.message : JSON.stringify(error);
    if (/HTTP\s+\d{3}/.test(text)) {
      return publicFailure(text, '订阅服务器返回了错误，请稍后重试。');
    }
    if (text.indexOf('订阅地址无效') >= 0) {
      return text;
    }
    if (text.indexOf('重定向') >= 0) {
      return text;
    }
    return publicFailure(text, `无法获取订阅：${redactDiagnosticText(text)}`);
  }

  private static async fetchText(url: string, redirectCount: number, opts: FetchOptions): Promise<FetchResult> {
    if (redirectCount > MAX_REDIRECTS) {
      throw new Error('重定向次数过多（超过 5 次）。');
    }

    const requestUrl = toIdnUrl(url);
    const request = http.createHttp();
    try {
      const header = SubscriptionManager.buildRequestHeader(requestUrl, opts.userAgent);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: HTTP_TIMEOUT_MS,
        connectTimeout: HTTP_TIMEOUT_MS,
        usingCache: false,
        // 手动跟随重定向（逐跳校验 scheme），系统层不再自动跳转。
        maxRedirects: 0,
        header
      };
      if (opts.dnsServers.length > 0) { options.dnsServers = opts.dnsServers; }
      if (opts.proxyPort > 0 && opts.proxyPort <= 65535) {
        const proxy: http.HttpProxy = {
          host: '127.0.0.1',
          port: opts.proxyPort,
          exclusionList: []
        };
        options.usingProxy = proxy;
      }
      const response = await request.request(requestUrl, options);
      const responseCode = Number(response.responseCode);
      if (SubscriptionManager.isRedirectCode(responseCode)) {
        const redirectUrl = SubscriptionManager.redirectUrl(requestUrl, response.header);
        if (redirectUrl.length > 0) {
          const validationMessage = SubscriptionManager.validateSubscriptionUrl(redirectUrl, opts.allowInsecureHttp);
          if (validationMessage.length > 0) {
            throw new Error(`重定向目标无效：${validationMessage}`);
          }
          return SubscriptionManager.fetchText(redirectUrl, redirectCount + 1, opts);
        }
      }
      if (responseCode < 200 || responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }

      const result = new FetchResult();
      result.userinfo = SubscriptionManager.parseUserinfoHeader(response.header);
      if (typeof response.result === 'string') {
        result.content = response.result;
      } else if (response.result instanceof ArrayBuffer) {
        const decoder = util.TextDecoder.create('utf-8');
        result.content = decoder.decodeToString(new Uint8Array(response.result));
      } else {
        const objectText = JSON.stringify(response.result);
        result.content = objectText === undefined ? '' : objectText;
      }
      return result;
    } finally {
      request.destroy();
    }
  }

  private static buildRequestHeader(url: string, userAgent: string): SubscriptionRequestHeader {
    const header: SubscriptionRequestHeader = {
      'User-Agent': userAgent.trim().length > 0 ? userAgent.trim() : APP_USER_AGENT,
      'Accept': 'text/plain, application/octet-stream, application/json, application/yaml, text/yaml, */*',
      'Accept-Encoding': 'identity',
      'Content-Type': 'text/plain; charset=utf-8'
    };
    const authorization = SubscriptionManager.buildEmbeddedBasicAuthorizationHeader(url);
    if (authorization.length > 0) {
      header.Authorization = authorization;
    }
    return header;
  }

  /** 解析 subscription-userinfo 响应头：upload=..; download=..; total=..; expire=.. */
  static parseUserinfoHeader(header: Object | undefined): SubscriptionUserinfo | null {
    const raw = SubscriptionManager.headerValue(header, 'subscription-userinfo');
    if (raw.length === 0) {
      return null;
    }
    const info = new SubscriptionUserinfo();
    let found = false;
    const pairs = raw.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair = pairs[i].trim();
      const equalIndex = pair.indexOf('=');
      if (equalIndex <= 0) {
        continue;
      }
      const key = pair.substring(0, equalIndex).trim().toLowerCase();
      const value = Number(pair.substring(equalIndex + 1).trim());
      if (Number.isNaN(value)) {
        continue;
      }
      if (key === 'upload') {
        info.upload = value;
        found = true;
      } else if (key === 'download') {
        info.download = value;
        found = true;
      } else if (key === 'total') {
        info.total = value;
        found = true;
      } else if (key === 'expire') {
        info.expire = value;
        found = true;
      }
    }
    return found ? info : null;
  }

  private static headerValue(header: Object | undefined, name: string): string {
    if (header === undefined || header === null || typeof header !== 'object') {
      return '';
    }
    const record = header as Record<string, Object>;
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() !== name) {
        continue;
      }
      const value = record[keys[i]];
      if (typeof value === 'string') {
        return value;
      }
      if (value instanceof Array && value.length > 0 && typeof value[0] === 'string') {
        return value[0] as string;
      }
    }
    return '';
  }

  private static isRedirectCode(code: number): boolean {
    return code === 301 || code === 302 || code === 303 || code === 307 || code === 308;
  }

  private static redirectUrl(currentUrl: string, header: Object | undefined): string {
    const location = SubscriptionManager.headerValue(header, 'location');
    if (location.length === 0) {
      return '';
    }
    return SubscriptionManager.resolveUrl(currentUrl, location);
  }

  private static resolveUrl(currentUrl: string, location: string): string {
    const trimmed = location.trim();
    if (SubscriptionManager.isHttpUrl(trimmed)) {
      return trimmed;
    }
    const schemeEnd = currentUrl.indexOf('://');
    if (schemeEnd < 0) {
      return '';
    }
    const scheme = currentUrl.substring(0, schemeEnd);
    if (trimmed.startsWith('//')) {
      return `${scheme}:${trimmed}`;
    }
    const originEnd = currentUrl.indexOf('/', schemeEnd + 3);
    const origin = originEnd < 0 ? currentUrl : currentUrl.substring(0, originEnd);
    if (trimmed.startsWith('/')) {
      return `${origin}${trimmed}`;
    }
    const queryStart = currentUrl.indexOf('?');
    const withoutQuery = queryStart < 0 ? currentUrl : currentUrl.substring(0, queryStart);
    const slashIndex = withoutQuery.lastIndexOf('/');
    if (slashIndex <= schemeEnd + 2) {
      return `${origin}/${trimmed}`;
    }
    return `${withoutQuery.substring(0, slashIndex + 1)}${trimmed}`;
  }

  private static isHttpUrl(value: string): boolean {
    const lower = value.toLowerCase();
    return lower.startsWith('https://') || lower.startsWith('http://');
  }

  private static buildEmbeddedBasicAuthorizationHeader(url: string): string {
    const trimmed = url.trim();
    const scheme = trimmed.indexOf('://');
    if (scheme < 0) {
      return '';
    }
    const start = scheme + 3;
    let end = trimmed.length;
    const terminators = ['/', '?', '#'];
    for (let index = 0; index < terminators.length; index++) {
      const position = trimmed.indexOf(terminators[index], start);
      if (position >= 0 && position < end) {
        end = position;
      }
    }
    const authority = trimmed.substring(start, end);
    const separator = authority.lastIndexOf('@');
    if (separator < 0) {
      return '';
    }
    const userInfo = authority.substring(0, separator);
    const colon = userInfo.indexOf(':');
    const rawUser = colon >= 0 ? userInfo.substring(0, colon) : userInfo;
    const rawPass = colon >= 0 ? userInfo.substring(colon + 1) : '';
    const user = SubscriptionManager.decodeUrlUserInfo(rawUser);
    const pass = SubscriptionManager.decodeUrlUserInfo(rawPass);
    return `Basic ${encodeUtf8ToBase64(`${user}:${pass}`)}`;
  }

  private static decodeUrlUserInfo(value: string): string {
    try {
      return decodeURIComponent(value);
    } catch (error) {
      return value;
    }
  }
}
