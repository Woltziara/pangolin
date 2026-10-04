import { PangolinWelcome } from '../components/PangolinWelcome';
import { PangolinPet } from '../components/PangolinPet';
import { pangolinState } from '../core/PangolinMotion';
import { display, window } from '@kit.ArkUI';
import { CONNECTION_POLICY } from '../services/ConnectionPolicy';
import { NodeStore, StoredNode } from '../services/NodeStore';
import { NODE_LATENCY_TEST, NODE_LATENCY_FILE, NodeLatencyBatch } from '../services/NodeLatencyTest';
import { nodeSpeedHint, NodeSpeedEntry } from '../core/NodeSpeedHint';
import { AppliedPolicy } from '../services/AppliedPolicy';
import { connectionCopy } from '../core/UserFacingCopy';
import { HEALTH_STATUS_MAX_AGE_MS, isConnectionEstablished } from '../net/ConnectionHealth';
import { UiFeedback } from '../services/UiFeedback';
import { NativePage } from '../components/NativePage';
import { Nodes } from './Nodes';
import { Rules } from './Rules';
import { Settings } from './Settings';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import {
  DataplaneStatus,
  PHASE_CANARY_OK,
  PHASE_CORE_RUNNING,
  PHASE_DEGRADED,
  PHASE_DEGRADED_UNPROVEN,
  PHASE_ERROR,
  PHASE_FORWARDER_RUNNING,
  PHASE_IDLE,
  PHASE_RECONNECTING,
  PHASE_STARTING,
  PHASE_STOPPED,
  PHASE_UNPROVEN,
  PHASE_VPN_CREATED
} from '../net/DataplaneStatus';
import { tcpConnectCanary } from '../net/DataplaneCanary';
import { NODE_META_FILE } from '../core/XrayRuntime';
import { BACKGROUND_KEEP_ALIVE } from '../services/BackgroundKeepAlive';
import { BACKGROUND_PROBE_HOST } from '../services/BackgroundProbeHost';
import { CONNECTION_CONTROLLER } from '../services/ConnectionController';
import { NodeRecord, REGION_US, nodeUsableForSplit } from '../services/NodeCatalog';
import {
  AppSettings,
  ROUTE_DIRECT,
  ROUTE_GLOBAL,
  SELECT_MANUAL,
  SettingsStore
} from '../services/SettingsStore';
import { PREPARE_HINT_FILE } from '../services/SplitRouter';
import { StatusStore } from '../services/StatusStore';
import { MODE_FULL } from '../vpn/VpnConstants';

const PING_TIMEOUT_MS: number = 2500;
const PING_BATCH: number = 4;

const STALE_STATUS_MS: number = HEALTH_STATUS_MAX_AGE_MS;

// Phase D：首次启动引导旗标（filesDir/onboarded.flag，存在即不再弹）。
const ONBOARD_FLAG_FILE: string = 'onboarded.flag';
// Phase D：启动即连接的进程级一次性旗标——从子页面返回首页不会重复触发。
let autoConnectAttempted: boolean = false;

@Entry
@Component
struct Index {
  @State activeTab: number = 0;
  @State pageRevision: number = 0;
  @State honestLabel: string = '未连接';
  @State hintText: string = '选择节点后即可连接。';
  @State operationError: string = '';
  @State needsHelp: boolean = false;
  @State statusWarning: boolean = false;
  @State selectedName: string = '';
  @State ytName: string = '';
  @State usName: string = '';
  @State nodes: Array<NodeRecord> = [];
  @State busy: boolean = false;
  @State petState: string = 'idle';
  @State statusSyncing: boolean = false;
  @State running: boolean = false;
  @State testing: boolean = false;
  // Phase C：连接模式行 / 故障切换提示 / 固定节点失效回退提示。
  @State modeLine: string = '';
  @State failoverText: string = '';
  @State prepareHint: string = '';
  @State settings: AppSettings = new AppSettings();
  @State viewWidth: number = 0;
  @State viewHeight: number = 0;
  @State connectionContentHeight: number = 160;
  @State foldStatus: number = 0;
  @State foldable: boolean = false;
  @State configuredNodes: StoredNode[] = [];
  @State configPending: boolean = false;
  @State dualChannel: boolean = false;
  @State nodeSpeedRunning: boolean = false;
  @State nodeSpeedText: string = '';
  @State nodeSpeedTip: string = '';
  @State nodeSpeedRecommendedId: string = '';
  private nodeSpeedRunId: string = '';
  private nodeSpeedSelectedId: string = '';
  private nodeSpeedStartedAt: number = 0;
  private refreshCount: number = 0;
  private lastStatusSyncAt: number = 0;
  private mainWindow: window.Window | null = null;
  private foldChanged = (_mode: display.FoldDisplayMode): void => { this.readFoldState(); };
  private foldPostureChanged = (_status: display.FoldStatus): void => { this.readFoldState(); };
  private welcomeController: CustomDialogController | null = null;
  private timerId: number = -1;
  private context: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.readFoldState();
    try { display.on('foldDisplayModeChange', this.foldChanged); display.on('foldStatusChange', this.foldPostureChanged); } catch (error) {}
    const ctx = this.context;
    if (ctx !== null) {
      window.getLastWindow(ctx).then((win: window.Window) => { this.mainWindow = win; }).catch(() => {});
      this.nodes = StatusStore.readNodes(ctx);
      const meta = StatusStore.readNodeMeta(ctx);
      this.selectedName = meta.name;
      this.ytName = meta.ytName;
      this.usName = meta.usName.length > 0 ? meta.usName : meta.name;
      this.maybeShowOnboarding(ctx);
      this.honestLabel = '连接';
      this.hintText = '';
      this.synchronizeStatus(ctx, true);
    }
    this.refresh();
    this.timerId = setInterval(() => {
      this.refresh();
    }, 1000);
  }

  aboutToDisappear(): void {
    try { display.off('foldDisplayModeChange', this.foldChanged); display.off('foldStatusChange', this.foldPostureChanged); } catch (error) {}
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  // 从导入/订阅/节点页返回时刷新节点列表（这些页会写 nodes.json）。
  onPageShow(): void {
    this.pageRevision += 1;
    const ctx = this.context;
    if (ctx !== null) {
      this.nodes = StatusStore.readNodes(ctx);
    }
    this.maybeAutoConnect();
  }

  /**
   * Phase D 首次启动引导：filesDir 没有 onboarded.flag 时弹一次三步引导，
   * 展示后立即写旗标。不阻塞、不自动请求任何权限。
   */
  private maybeShowOnboarding(ctx: common.UIAbilityContext): void {
    if (StatusStore.readText(ctx, ONBOARD_FLAG_FILE).length > 0) {
      return;
    }
    this.welcomeController = new CustomDialogController({
      builder: PangolinWelcome({ message: '三步上手：\n1. 在「节点」中选择添加节点，进入导入页扫码、粘贴链接或选择配置文件\n' +
        '2. 选择一个节点，或保持自动选择\n' +
        '3. 回到「首页」点连接，首次会弹出系统 VPN 授权，点允许即可\n\n' +
        '本版可按需要使用单通道或双通道，可导入和保存多个节点，使用订阅、测速、自动选路、规则和数据管理。节点和网络服务需自行准备。' }),
      autoCancel: true
    });
    this.welcomeController.open();
    StatusStore.writeText(ctx, ONBOARD_FLAG_FILE, `onboarded ${Date.now()}`);
  }

  /**
   * Phase D 启动即连接：进程内只尝试一次（autoConnectAttempted），
   * 仅在开关打开且当前明确空闲/已停止/失败时走与连接按钮相同的路径；
   * 失败经 startTunnel 内部 try/catch 落到状态行，不弹窗。
   */
  private maybeAutoConnect(): void {
    if (this.statusSyncing) { return; }
    if (autoConnectAttempted) {
      return;
    }
    autoConnectAttempted = true;
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    try {
      if (!SettingsStore.load(ctx).autoConnectOnLaunch) {
        return;
      }
      const plane = StatusStore.readStatus(ctx);
      const idle = plane.phase === PHASE_IDLE || plane.phase === PHASE_STOPPED ||
        plane.phase === PHASE_ERROR;
      if (!idle || this.running || this.busy) {
        return;
      }
      this.startTunnel().catch((error: Object) => {
        this.operationError = UiFeedback.failure(this.context, 'auto-connect', error, '自动连接未成功，请检查网络和节点后重试。');
      });
    } catch (error) {
      this.operationError = UiFeedback.failure(this.context, 'auto-connect', error, '自动连接未成功，请检查网络和节点后重试。');
    }
  }

  private liveStatus(ctx: common.UIAbilityContext): DataplaneStatus {
    const plane: DataplaneStatus = StatusStore.readStatus(ctx);
    const claimingLive: boolean = plane.phase === PHASE_CANARY_OK || plane.phase === PHASE_DEGRADED ||
      plane.phase === PHASE_DEGRADED_UNPROVEN || plane.phase === PHASE_UNPROVEN ||
      plane.phase === PHASE_RECONNECTING || plane.phase === PHASE_FORWARDER_RUNNING ||
      plane.phase === PHASE_CORE_RUNNING || plane.phase === PHASE_VPN_CREATED ||
      plane.phase === PHASE_STARTING || plane.vpnCreated;
    if (claimingLive && plane.at > 0 && Date.now() - plane.at > STALE_STATUS_MS) {
      // Display-only. Never persist STOPPED over a live VPN process.
      plane.honestLabel = '状态过期，不能当成已断开';
    }
    return plane;
  }

  private refresh(): void {
    if (this.statusSyncing) { return; }
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    this.dualChannel = CONNECTION_POLICY.mode(ctx) === 'dual';
    const plane: DataplaneStatus = this.liveStatus(ctx);
    const stale = plane.honestLabel === '状态过期，不能当成已断开';
    if (stale) {
      this.synchronizeStatus(ctx);
      return;
    }
    this.running = !stale && (plane.phase === PHASE_CANARY_OK || plane.phase === PHASE_DEGRADED ||
      plane.phase === PHASE_DEGRADED_UNPROVEN || plane.phase === PHASE_UNPROVEN ||
      plane.phase === PHASE_RECONNECTING || plane.phase === PHASE_FORWARDER_RUNNING ||
      plane.phase === PHASE_CORE_RUNNING || plane.phase === PHASE_VPN_CREATED ||
      plane.phase === PHASE_STARTING);
    const copy = connectionCopy(plane.phase, stale, this.canStart(), plane.connectionHealth,
      isConnectionEstablished(plane, Date.now()));
    this.honestLabel = copy.title;
    this.petState = pangolinState(isConnectionEstablished(plane, Date.now()), plane.phase, this.busy, this.operationError.length > 0);
    this.needsHelp = copy.needsHelp;
    this.statusWarning = copy.warning;
    if (!this.testing) {
      this.hintText = this.makeHint(plane);
    }
    if (this.running && plane.nodeName.length > 0) {
      this.selectedName = plane.nodeName;
    }
    const meta = StatusStore.readNodeMeta(ctx);
    this.ytName = meta.ytName;
    this.usName = meta.usName.length > 0 ? meta.usName : meta.name;
    // Phase C：模式行常显；故障切换/固定节点回退提示来自 meta 与 prepare 提示文件。
    this.settings = SettingsStore.load(ctx);
    this.configuredNodes = NodeStore.loadNodes(ctx);
    this.refreshNodeSpeed();
    if (AppliedPolicy.matches(ctx)) { this.configPending = false; }
    else if (AppliedPolicy.current(ctx) !== null) { this.configPending = true; }
    this.refreshCount += 1;
    if (this.refreshCount % 5 === 0) { this.pageRevision += 1; }
    this.modeLine = this.makeModeLine(this.settings);
    this.failoverText = this.makeFailoverText(ctx);
    this.prepareHint = this.makePrepareHint(ctx);
  }

  private synchronizeStatus(ctx: common.UIAbilityContext, force: boolean = false): void {
    if (this.statusSyncing || (!force && Date.now() - this.lastStatusSyncAt < 5000)) { return; }
    this.statusSyncing = true;
    this.lastStatusSyncAt = Date.now();
    CONNECTION_CONTROLLER.reconcileStatus(ctx, force).then(() => {
      this.statusSyncing = false;
      this.refresh();
      this.maybeAutoConnect();
    }).catch(() => {
      this.statusSyncing = false;
      this.honestLabel = '连接服务异常';
      this.hintText = '请重新连接。';
      this.statusWarning = true;
      this.running = false;
    });
  }

  private makeModeLine(settings: AppSettings): string {
    let mode = '按规则连接';
    if (settings.routeMode === ROUTE_GLOBAL) {
      mode = '全局代理';
    } else if (settings.routeMode === ROUTE_DIRECT) {
      mode = '全部直连';
    }
    const selection = settings.selectionMode === SELECT_MANUAL ? '固定节点' : '自动选择';
    return `模式：${mode} · ${selection}`;
  }

  private makeFailoverText(ctx: common.UIAbilityContext): string {
    const raw = StatusStore.readText(ctx, NODE_META_FILE);
    if (raw.length < 8) {
      return '';
    }
    try {
      const meta = JSON.parse(raw) as Record<string, Object>;
      const usSwapped = meta['usFailedOver'] === true;
      const ytSwapped = meta['ytFailedOver'] === true;
      if (!usSwapped && !ytSwapped) {
        return '';
      }
      const name = usSwapped ? this.metaString(meta, 'usName') : this.metaString(meta, 'ytName');
      if (name.length === 0) {
        return '';
      }
      return `已切换到备用节点：${name}（原线路持续无法连接）`;
    } catch (error) {
      return '';
    }
  }

  private metaString(meta: Record<string, Object>, key: string): string {
    const value = meta[key];
    return typeof value === 'string' ? value : '';
  }

  private makePrepareHint(ctx: common.UIAbilityContext): string {
    const raw = StatusStore.readText(ctx, PREPARE_HINT_FILE);
    if (raw.length < 8) {
      return '';
    }
    try {
      const rec = JSON.parse(raw) as Record<string, Object>;
      const text = rec['text'];
      if (typeof text !== 'string' || text.length === 0) { return ''; }
      if (text.indexOf('固定节点已失效') >= 0) { return '原先固定的节点已失效，本次改为自动选择。'; }
      if (text.indexOf('内无备用节点') >= 0) { return '所选分组没有备用节点，当前线路失败时将无法自动切换。'; }
      return '连接设置有一条提示，可在诊断详情中查看。';
    } catch (error) {
      return '';
    }
  }

  private shortStatus(plane: DataplaneStatus): string {
    return connectionCopy(plane.phase, plane.honestLabel === '状态过期，不能当成已断开',
      this.canStart(), plane.connectionHealth, isConnectionEstablished(plane, Date.now())).title;
  }

  private makeHint(plane: DataplaneStatus): string {
    return connectionCopy(plane.phase, plane.honestLabel === '状态过期，不能当成已断开',
      this.canStart(), plane.connectionHealth, isConnectionEstablished(plane, Date.now())).detail;
  }

  private hasUsCatalog(): boolean {
    for (let i = 0; i < this.nodes.length; i++) {
      const node = this.nodes[i];
      if (nodeUsableForSplit(node) && node.region === REGION_US) {
        return true;
      }
    }
    return false;
  }

  private hasRunnableCatalog(): boolean {
    for (let i = 0; i < this.nodes.length; i++) {
      if (nodeUsableForSplit(this.nodes[i])) {
        return true;
      }
    }
    return false;
  }

  private canStart(): boolean {
    if (this.settings.selectionMode === SELECT_MANUAL && this.settings.manualNodeId.length > 0) {
      return true;
    }
    return this.hasRunnableCatalog() || this.selectedName.length > 0;
  }

  private cloneNodes(): Array<NodeRecord> {
    const next: Array<NodeRecord> = [];
    for (let i = 0; i < this.nodes.length; i++) {
      const src = this.nodes[i];
      const rec = new NodeRecord();
      rec.name = src.name;
      rec.region = src.region;
      rec.server = src.server;
      rec.port = src.port;
      rec.protocol = src.protocol;
      rec.outboundJson = src.outboundJson;
      rec.latencyText = src.latencyText;
      rec.latencyMs = src.latencyMs;
      next.push(rec);
    }
    return next;
  }

  private async pingOne(index: number): Promise<void> {
    if (index < 0 || index >= this.nodes.length) {
      return;
    }
    const node = this.nodes[index];
    node.latencyText = '测...';
    const result = await tcpConnectCanary(node.server, node.port, PING_TIMEOUT_MS);
    if (result.ok) {
      node.latencyMs = result.elapsedMs;
      node.latencyText = `${result.elapsedMs}ms`;
    } else {
      node.latencyMs = -1;
      node.latencyText = '超时';
    }
  }

  private async testLatency(): Promise<void> {
    if (this.testing || this.nodes.length === 0) {
      return;
    }
    this.testing = true;
    this.hintText = '正在测试各节点延迟';
    for (let i = 0; i < this.nodes.length; i++) {
      this.nodes[i].latencyText = '';
      this.nodes[i].latencyMs = -1;
    }
    this.nodes = this.cloneNodes();
    for (let start = 0; start < this.nodes.length; start += PING_BATCH) {
      const jobs: Array<Promise<void>> = [];
      const end = Math.min(start + PING_BATCH, this.nodes.length);
      for (let i = start; i < end; i++) {
        jobs.push(this.pingOne(i));
      }
      await Promise.all(jobs);
      this.nodes = this.cloneNodes();
    }
    let bestName = '';
    let bestMs = 1000000;
    let okCount = 0;
    for (let i = 0; i < this.nodes.length; i++) {
      if (this.nodes[i].latencyMs >= 0) {
        okCount += 1;
        if (this.nodes[i].latencyMs < bestMs) {
          bestMs = this.nodes[i].latencyMs;
          bestName = this.nodes[i].name;
        }
      }
    }
    this.testing = false;
    if (okCount === 0) {
      this.hintText = '延迟测试失败，请检查网络';
    } else {
      this.hintText = `最快 ${bestName} · ${bestMs}ms`;
    }
  }

  private async startTunnel(existingEpoch: number = -1): Promise<void> {
    if (this.busy || this.statusSyncing || this.running || this.context === null) {
      return;
    }
    if (!this.canStart()) {
      this.hintText = '还没有可连接的节点';
      return;
    }
    this.operationError = '';
    this.busy = true;
    this.honestLabel = '正在连接';
    this.petState = 'connecting';
    this.hintText = '正在请求系统 VPN 权限';
    const startEpoch = existingEpoch >= 0 ? existingEpoch : CONNECTION_CONTROLLER.beginStartIntent();
    if (existingEpoch >= 0 && !CONNECTION_CONTROLLER.isStartIntentLive(startEpoch)) {
      this.busy = false;
      this.refresh();
      return;
    }
    try {
      const keep = await BACKGROUND_KEEP_ALIVE.ensure(this.context, 'Index.startTunnel');
      if (!CONNECTION_CONTROLLER.isStartIntentLive(startEpoch)) {
        this.busy = false;
        this.refresh();
        return;
      }
      if (!keep) {
        this.honestLabel = '连接失败';
        this.operationError = '暂时无法保持后台连接，请稍后重试。';
        this.busy = false;
        this.refresh();
        return;
      }
      // startTunnel can be invoked after EntryAbility.onCreate has already
      // returned while disconnected.  Start the reachability receipt loop at
      // the moment the user actually asks for a tunnel.
      BACKGROUND_PROBE_HOST.start(this.context, 'Index.startTunnel');
      const plane = await CONNECTION_CONTROLLER.start(this.context, MODE_FULL, startEpoch);
      if (!CONNECTION_CONTROLLER.isStartIntentLive(startEpoch) && plane.phase !== PHASE_STOPPED &&
        plane.phase !== PHASE_ERROR) {
        this.busy = false;
        this.refresh();
        return;
      }
      this.honestLabel = this.shortStatus(plane);
      this.hintText = this.makeHint(plane);
    } catch (error) {
      if (!CONNECTION_CONTROLLER.isStartIntentLive(startEpoch)) {
        this.busy = false;
        this.refresh();
        return;
      }
      this.honestLabel = '连接失败';
      this.operationError = UiFeedback.failure(this.context, 'connect', error, '连接未成功，请查看诊断后重试。');
    }
    this.busy = false;
    this.refresh();
  }

  private async stopTunnel(cancelIntent: boolean = true): Promise<void> {
    if (this.context === null) {
      return;
    }
    this.busy = true;
    this.operationError = '';
    this.hintText = this.running ? '正在断开连接，请稍候。' : '正在取消连接';
    try {
      const plane = await CONNECTION_CONTROLLER.stop(this.context, cancelIntent);
      if (plane.phase === PHASE_STOPPED) {
        BACKGROUND_PROBE_HOST.stop(this.context, 'Index.stopTunnel');
        this.honestLabel = '已断开';
      } else {
        this.honestLabel = this.shortStatus(plane);
      }
      this.hintText = this.makeHint(plane);
    } catch (error) {
      this.operationError = UiFeedback.failure(this.context, 'disconnect', error, '未能确认连接已断开，请查看诊断。');
    }
    this.busy = false;
    this.refresh();
  }

  private labelColor(): ResourceColor {
    if (this.honestLabel === '已连接') {
      return $r('sys.color.ohos_id_color_text_primary_activated');
    }
    if (this.statusWarning || this.operationError.length > 0) {
      return $r('sys.color.ohos_id_color_warning');
    }
    return $r('sys.color.ohos_id_color_text_primary');
  }

  private readFoldState(): void {
    try {
      const foldable = display.isFoldable();
      const status = foldable ? display.getFoldStatus() : 0;
      this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
        this.foldable = foldable;
        this.foldStatus = status;
      });
    } catch (error) {}
  }

  private narrow(): boolean { return this.viewWidth < 600; }
  private triple(): boolean { return !this.narrow() && this.foldable && this.foldStatus === 11 &&
    (!this.landscape() || this.viewWidth >= 960); }
  private landscape(): boolean {
    // Keyboard avoidance changes panel height, not physical window orientation.
    try {
      if (this.mainWindow !== null) {
        const rect = this.mainWindow.getWindowProperties().windowRect;
        return rect.width > rect.height;
      }
    } catch (error) {}
    return this.viewWidth > this.viewHeight;
  }
  private combined(): boolean { return !this.narrow() && (this.activeTab < 2 || this.triple()); }
  private panelVisible(panel: number): boolean {
    if (this.activeTab === 3) { return false; }
    if (this.narrow()) { return this.activeTab === panel; }
    if (this.triple()) { return true; }
    if (this.activeTab === 2) { return panel === 2; }
    return panel < 2;
  }

  private panelSpan(panel: number): number {
    if (!this.panelVisible(panel)) { return 0; }
    if (!this.combined() || !this.landscape()) { return 24; }
    if (this.triple()) { return panel === 0 ? 5 : panel === 1 ? 11 : 8; }
    if (!this.foldable) { return 24; }
    return panel === 0 ? 9 : 15;
  }

  private panelHeight(panel: number): Length {
    const h = Math.max(1, this.viewHeight);
    if (!this.panelVisible(panel)) { return 0; }
    if (!this.combined() || (this.landscape() && this.foldable)) { return h; }
    if (panel === 0) { return 'auto'; }
    if (this.triple()) {
      const rulesHeight = Math.min(300, Math.max(180, h * 0.27));
      return panel === 1 ? Math.max(80, h - this.connectionContentHeight - rulesHeight - 32) : rulesHeight;
    }
    return Math.max(80, h - this.connectionContentHeight - 16);
  }

  private horizontalControl(): boolean {
    return !this.narrow() && (!this.landscape() || !this.foldable);
  }

  private shortName(name: string): string {
    return name.replace('-PRO-', ' · ').replace(/-流量倍率:[0-9.]+$/, '');
  }

  private roleOptions(): SelectOption[] {
    const out: SelectOption[] = [{ value: '自动选择' }];
    this.configuredNodes.forEach((node: StoredNode) => { out.push({ value: this.shortName(NodeStore.displayName(node)) }); });
    return out;
  }

  private roleIndex(chatgpt: boolean): number {
    const id = !this.dualChannel ? this.settings.singleNodeId : chatgpt ? this.settings.chatgptNodeId : this.settings.generalNodeId;
    return this.configuredNodes.findIndex((node: StoredNode) => node.id === id) + 1;
  }

  private roleValue(chatgpt: boolean): string {
    const id = !this.dualChannel ? this.settings.singleNodeId : chatgpt ? this.settings.chatgptNodeId : this.settings.generalNodeId;
    if (id.length === 0) { return '自动选择'; }
    const node = this.configuredNodes.find((n: StoredNode) => n.id === id);
    return node === undefined ? '节点已不可用' : this.shortName(NodeStore.displayName(node));
  }

  private selectRole(chatgpt: boolean, index: number): void {
    this.activeTab = 0;
    if (this.context === null) { return; }
    const id = index > 0 ? this.configuredNodes[index - 1].id : '';
    if (id === (!this.dualChannel ? this.settings.singleNodeId : chatgpt ? this.settings.chatgptNodeId : this.settings.generalNodeId)) { return; }
    SettingsStore.update(this.context, (settings) => {
      if (!this.dualChannel) { settings.singleNodeId = id; }
      else {
        settings.selectionMode = 'auto'; settings.manualNodeId = '';
        if (chatgpt) { settings.chatgptNodeId = id; } else { settings.generalNodeId = id; }
      }
    });
    this.configPending = true;
    this.pageRevision += 1;
    this.refresh();
  }

  private async applyConnection(): Promise<void> {
    if (this.busy) { return; }
    const epoch = CONNECTION_CONTROLLER.beginStartIntent();
    if (this.running) { await this.stopTunnel(false); }
    if (!CONNECTION_CONTROLLER.isStartIntentLive(epoch)) {
      this.pageRevision += 1;
      return;
    }
    if (!this.running) { await this.startTunnel(epoch); }
    this.pageRevision += 1;
  }

  private async repairConnection(): Promise<void> {
    if (this.busy || this.statusSyncing || this.context === null) { return; }
    this.operationError = '';
    this.hintText = '正在重建连接，请稍候。';
    await this.applyConnection();
  }

  private async testSelectedNode(): Promise<void> {
    const ctx = this.context;
    const selectedId = this.settings.singleNodeId;
    if (ctx === null || this.nodeSpeedRunning || this.busy || selectedId.length === 0) { return; }
    this.nodeSpeedRunning = true;
    this.nodeSpeedSelectedId = selectedId;
    this.nodeSpeedStartedAt = Date.now();
    this.nodeSpeedRunId = '';
    this.nodeSpeedText = '当前节点测速中…';
    this.nodeSpeedTip = '';
    this.nodeSpeedRecommendedId = '';
    try {
      this.nodeSpeedRunId = await NODE_LATENCY_TEST.begin(ctx, selectedId);
      this.refreshNodeSpeed();
    } catch (error) {
      this.nodeSpeedRunning = false;
      this.nodeSpeedText = this.settings.singleNodeId === selectedId ? '暂时无法测速，请在连接稳定后重试' : '';
    }
  }

  private refreshNodeSpeed(): void {
    this.nodeSpeedRecommendedId = '';
    if (this.nodeSpeedSelectedId.length === 0 || this.context === null) { return; }
    if (this.settings.singleNodeId !== this.nodeSpeedSelectedId || this.dualChannel) {
      this.nodeSpeedText = ''; this.nodeSpeedTip = '';
      // Keep the in-flight guard until its bounded run finishes; never attach its result to the new selection.
    }
    if (!this.nodeSpeedRunning) {
      if (Date.now() - this.nodeSpeedStartedAt > 120000 && this.nodeSpeedText.length > 0) {
        this.nodeSpeedText = '测速结果已过期，请重测'; this.nodeSpeedTip = '';
      }
      if (Date.now() - this.nodeSpeedStartedAt > 120000 || this.nodeSpeedText.length === 0) { return; }
    }
    if (this.nodeSpeedRunning && Date.now() - this.nodeSpeedStartedAt > 90000) {
      this.nodeSpeedRunning = false;
      if (this.settings.singleNodeId === this.nodeSpeedSelectedId) { this.nodeSpeedText = '测速超时，请重试'; this.nodeSpeedTip = ''; }
      return;
    }
    if (this.nodeSpeedRunId.length === 0) { return; }
    try {
      const raw = StatusStore.readText(this.context, NODE_LATENCY_FILE);
      if (raw.length === 0) { return; }
      const batch = JSON.parse(raw) as NodeLatencyBatch;
      if (batch.runId !== this.nodeSpeedRunId) {
        this.nodeSpeedRunning = false;
        if (this.settings.singleNodeId === this.nodeSpeedSelectedId) { this.nodeSpeedText = '测速任务已变化，请重试'; this.nodeSpeedTip = ''; }
        return;
      }
      if (batch.complete) { this.nodeSpeedRunning = false; }
      if (this.settings.singleNodeId !== this.nodeSpeedSelectedId || this.dualChannel) { return; }
      const samples: NodeSpeedEntry[] = [];
      batch.samples.forEach((sample) => {
        const node = this.configuredNodes.find((item: StoredNode) => item.id === sample.id);
        if (node === undefined) { return; }
        const entry = new NodeSpeedEntry();
        entry.id = node.id; entry.label = this.shortName(NodeStore.displayName(node)); entry.milliseconds = sample.milliseconds;
        samples.push(entry);
      });
      const view = nodeSpeedHint(this.nodeSpeedSelectedId, batch.region, samples, batch.complete, batch.outcome);
      this.nodeSpeedText = view.current;
      this.nodeSpeedTip = view.tip;
      this.nodeSpeedRecommendedId = view.recommendedId;
    } catch (error) {
      this.nodeSpeedRunning = false;
      this.nodeSpeedText = '测速结果无法读取，请重试'; this.nodeSpeedTip = '';
    }
  }

  private async useFasterNode(): Promise<void> {
    this.refreshNodeSpeed();
    if (this.busy || this.statusSyncing || this.nodeSpeedRunning || this.dualChannel ||
      this.settings.singleNodeId !== this.nodeSpeedSelectedId ||
      Date.now() - this.nodeSpeedStartedAt > 120000 || this.nodeSpeedRecommendedId.length === 0) { return; }
    const index = this.configuredNodes.findIndex((node: StoredNode) => node.id === this.nodeSpeedRecommendedId);
    if (index < 0) { this.nodeSpeedTip = '推荐节点已不存在，请重新测速'; this.nodeSpeedRecommendedId = ''; return; }
    const reconnect = this.running;
    this.selectRole(false, index + 1);
    this.nodeSpeedText = ''; this.nodeSpeedTip = ''; this.nodeSpeedRecommendedId = '';
    if (reconnect) { await this.applyConnection(); }
  }

  @Builder
  RolePicker(chatgpt: boolean) {
    Column({ space: 8 }) {
      Text(!this.dualChannel ? '单通道节点' : chatgpt ? 'ChatGPT' : '通用').fontSize(16).fontWeight(FontWeight.Medium)
      Row({ space: 8 }) {
        Select(this.roleOptions()).selected(this.roleIndex(chatgpt)).value(this.roleValue(chatgpt))
          .layoutWeight(1).onSelect((index: number) => { this.selectRole(chatgpt, index); })
        if (!this.dualChannel) {
          Button(this.nodeSpeedRunning ? '测速中' : '测速').fontSize(14)
            .enabled(!this.nodeSpeedRunning && !this.busy && !this.statusSyncing && this.settings.singleNodeId.length > 0)
            .onClick(() => { this.testSelectedNode(); })
        }
      }.width('100%')
      if (!this.dualChannel) {
        if (this.nodeSpeedText.length > 0) {
          Text(this.nodeSpeedText).fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
        if (this.nodeSpeedTip.length > 0) {
          if (this.nodeSpeedRecommendedId.length > 0) {
            Button(`${this.nodeSpeedTip} · 点击切换`).type(ButtonType.Normal).fontSize(12)
              .padding(8).borderRadius(8).width('100%')
              .enabled(!this.busy && !this.statusSyncing && !this.nodeSpeedRunning)
              .onClick(() => { this.useFasterNode(); })
          } else {
            Text(this.nodeSpeedTip).fontSize(12).fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .padding(8).borderRadius(8).backgroundColor($r('sys.color.ohos_id_color_component_normal')).width('100%')
          }
        }
        Text(this.settings.singleNodeId.length === 0 ? '先选择具体节点即可测速' : '测当前及同地区节点的 TCP 延迟；点击推荐才切换，已连接时会重连。非下载速度或代理验证')
          .fontSize(11).fontColor($r('sys.color.ohos_id_color_text_secondary'))
      }
      if (this.running) {
        Text(`本次：${this.shortName(chatgpt ? this.usName : this.ytName) || '待确认'}`)
          .fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary')).maxLines(2)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  StatusControl() {
    Column({ space: 12 }) {
      PangolinPet({ state: this.petState, motionEnabled: this.settings.companionEnabled })
      Text(this.honestLabel).fontSize(26).fontWeight(FontWeight.Medium).fontColor(this.labelColor())
      if (this.needsHelp || this.operationError.length > 0) {
        Text(this.operationError || this.hintText).fontSize(14).fontColor($r('sys.color.ohos_id_color_text_secondary'))
        Button('查看诊断').buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick(() => { router.pushUrl({ url: 'pages/Diagnostics' }); })
      }
      Select([{ value: '按规则连接' }, { value: '全局代理' }, { value: '全部直连' }])
        .value(this.settings.routeMode === ROUTE_GLOBAL ? '全局代理' : this.settings.routeMode === ROUTE_DIRECT ? '全部直连' : '按规则连接')
        .selected(this.settings.routeMode === ROUTE_GLOBAL ? 1 : this.settings.routeMode === ROUTE_DIRECT ? 2 : 0)
        .width('100%').onSelect((index: number) => {
          if (this.context !== null) {
            SettingsStore.update(this.context, (settings) => { settings.routeMode = index === 1 ? ROUTE_GLOBAL : index === 2 ? ROUTE_DIRECT : 'rule'; });
            this.configPending = true; this.pageRevision += 1; this.refresh();
          }
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  ConnectionActions() {
    Column({ space: 8 }) {
      if (this.configPending) {
        Text(this.running ? '设置已保存，待应用' : '下次连接时使用新设置').fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
        Button(this.running ? '重新连接并应用' : '连接').width('100%').enabled(!this.busy && !this.statusSyncing)
          .onClick(() => { this.applyConnection(); })
        if (this.running || this.busy) {
          Button(this.running ? '断开' : '取消').width('100%').buttonStyle(ButtonStyleMode.NORMAL)
            .onClick(() => { this.stopTunnel(); })
        }
      } else {
        Button(this.busy && !this.running ? '取消' : this.running ? '断开' : '连接').width('100%')
          .enabled(!this.statusSyncing && (this.busy || this.running || this.canStart()))
          .buttonStyle(this.running || this.busy ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
          .onClick(() => { if (this.running || this.busy) { this.stopTunnel(); } else { this.startTunnel(); } })
        if (this.running && !this.busy) {
          Button('修复连接').width('100%').buttonStyle(ButtonStyleMode.NORMAL)
            .enabled(!this.statusSyncing)
            .onClick(() => { this.repairConnection(); })
          Text('短暂断开并按当前设置重建 VPN；不清除 ChatGPT 或其他应用的数据。')
            .fontSize(11).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
        }
      }
      if (this.busy) { LoadingProgress().width(24).height(24) }
      if (this.failoverText.length > 0) { Text(this.failoverText).fontSize(13).width('100%') }
      if (this.prepareHint.length > 0) { Text(this.prepareHint).fontSize(13).width('100%') }
    }.width('100%')
  }

  @Builder
  ModePicker() {
    Column({ space: 8 }) {
      Text('连接模式').fontSize(16).fontWeight(FontWeight.Medium)
      Select([{ value: '按规则连接' }, { value: '全局代理' }, { value: '全部直连' }])
        .value(this.settings.routeMode === ROUTE_GLOBAL ? '全局代理' : this.settings.routeMode === ROUTE_DIRECT ? '全部直连' : '按规则连接')
        .selected(this.settings.routeMode === ROUTE_GLOBAL ? 1 : this.settings.routeMode === ROUTE_DIRECT ? 2 : 0)
        .width('100%').onSelect((index: number) => {
          if (this.context !== null) {
            SettingsStore.update(this.context, (settings) => { settings.routeMode = index === 1 ? ROUTE_GLOBAL : index === 2 ? ROUTE_DIRECT : 'rule'; });
            this.configPending = true; this.pageRevision += 1; this.refresh();
          }
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  ConnectionPage() {
    Column() {
      if (this.horizontalControl()) {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Text(this.honestLabel).fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.labelColor())
            if (this.needsHelp || this.operationError.length > 0) {
              Button('查看诊断').buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick(() => { router.pushUrl({ url: 'pages/Diagnostics' }); })
            }
            Column() { PangolinPet({ state: this.petState, motionEnabled: this.settings.companionEnabled }) }.layoutWeight(1)
            if ((this.running || this.busy) && this.configPending) {
              Button(this.running ? '断开' : '取消').buttonStyle(ButtonStyleMode.NORMAL).onClick(() => { this.stopTunnel(); })
            }
            Button(this.configPending ? '应用并连接' : this.busy && !this.running ? '取消' : this.running ? '断开' : '连接')
              .buttonStyle(this.running && !this.configPending ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
              .enabled(this.busy || this.running || this.canStart()).onClick(() => {
                if (this.busy && !this.configPending) { this.stopTunnel(); }
                else if (this.configPending) { this.applyConnection(); }
                else if (this.running) { this.stopTunnel(); } else { this.startTunnel(); }
              })
            if (this.running && !this.busy && !this.configPending) {
              Button('修复连接').buttonStyle(ButtonStyleMode.NORMAL).enabled(!this.statusSyncing)
                .onClick(() => { this.repairConnection(); })
            }
          }.width('100%')
          GridRow({ columns: 12, gutter: 16 }) {
            GridCol({ span: 4 }) { this.ModePicker() }
            if (this.dualChannel) { GridCol({ span: 4 }) { this.RolePicker(true) } }
            GridCol({ span: 4 }) { this.RolePicker(false) }
          }.width('100%')
          this.ChannelSelector()
          if (this.configPending) {
            Text('设置已保存，应用时会重新连接。').fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary')).width('100%')
          }
        }.width('100%').padding(8).alignItems(HorizontalAlign.Start)
      } else {
        Scroll() {
          Column({ space: 24 }) {
            Text('连接').fontSize(22).fontWeight(FontWeight.Bold).width('100%')
            this.StatusControl()
            if (this.dualChannel) { this.RolePicker(true) }
            this.RolePicker(false)
            this.ChannelSelector()
            this.ConnectionActions()
          }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 16 }).alignItems(HorizontalAlign.Start)
        }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
      }
    }.width('100%')
  }

  @Builder
  SectionButton(label: string, section: number) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        SymbolGlyph(section === 0 ? $r('sys.symbol.house') : section === 1 ? $r('sys.symbol.square_link_square') :
          section === 2 ? $r('sys.symbol.list_bullet') : $r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor([this.activeTab === section || (section === 0 && this.combined()) ?
            $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_text_secondary')])
        Text(label).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.activeTab === section || (section === 0 && this.combined()) ?
            $r('sys.color.ohos_id_color_text_primary_activated') : $r('sys.color.ohos_id_color_text_secondary'))
      }.width('100%')
    }.height(56).borderRadius(0).backgroundColor(Color.Transparent)
      .accessibilityText(label).layoutWeight(1)
      .onClick(() => { this.activeTab = section; this.refresh(); })
  }

  @Builder
  ChannelSelector() {
    Row({ space: 8 }) {
      Text('连接通道').fontSize(13).fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Select([{ value: '单通道' }, { value: '双通道' }]).selected(this.dualChannel ? 1 : 0)
        .value(this.dualChannel ? '双通道' : '单通道').onSelect((index: number) => {
          if (this.context === null) { return; }
          SettingsStore.update(this.context, (settings) => { settings.channelMode = index === 1 ? 'dual' : 'single'; });
          this.configPending = true; this.pageRevision += 1; this.refresh();
        })
    }.width('100%')
  }

  build() {
    Column() {
    NativePage({ title: '', rootPage: true, hideTitle: true, maxContentWidth: 1800 }) {
      Column({ space: 8 }) {
        if (this.triple()) {
          Row() {
            if (this.activeTab === 3) {
              Button('返回工作台').buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => { this.activeTab = 0; })
            }
            Blank()
            Button('设置').buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => { this.activeTab = 3; })
          }.width('100%').height(40)
        }
        Stack({ alignContent: Alignment.TopStart }) {
          GridRow({ columns: 24, gutter: { x: 24, y: 16 }, breakpoints: { value: ['600vp', '840vp'], reference: BreakpointsReference.ComponentSize } }) {
            GridCol({ span: this.panelSpan(0) }) { this.ConnectionPage() }
              .height(this.panelHeight(0)).visibility(this.panelVisible(0) ? Visibility.Visible : Visibility.None)
              .onAreaChange((_old: Area, current: Area) => {
                if (this.horizontalControl() && this.panelVisible(0) && Number(current.height) > 0) {
                  this.connectionContentHeight = Number(current.height);
                }
              })
            GridCol({ span: this.panelSpan(1) }) {
              Nodes({ embedded: true, revision: this.pageRevision, onInteraction: () => { this.activeTab = 1; }, onRoleChange: () => { this.configPending = true; this.pageRevision += 1; this.refresh(); } })
            }.height(this.panelHeight(1)).visibility(this.panelVisible(1) ? Visibility.Visible : Visibility.None)
            GridCol({ span: this.panelSpan(2) }) { Rules({ embedded: true, revision: this.pageRevision, onInteraction: () => { this.activeTab = 2; } }) }
              .height(this.panelHeight(2)).visibility(this.panelVisible(2) ? Visibility.Visible : Visibility.None)
          }.width('100%').height('100%')
          Column() { Settings({ embedded: true }) }.width('100%').height('100%')
            .visibility(this.activeTab === 3 ? Visibility.Visible : Visibility.None)
        }.width('100%').layoutWeight(1).clip(true)
          .onAreaChange((_old: Area, current: Area) => {
            const width = Number(current.width), height = Number(current.height);
            if (Math.abs(width - this.viewWidth) < 1 && Math.abs(height - this.viewHeight) < 1) { return; }
            this.getUIContext().animateTo({ duration: this.viewWidth > 0 ? 280 : 0, curve: Curve.EaseInOut }, () => {
              this.viewWidth = width; this.viewHeight = height;
            });
          })
        if (!this.triple()) {
          Row({ space: 8 }) {
            this.SectionButton('首页', 0)
            if (this.narrow()) { this.SectionButton('节点', 1) }
            this.SectionButton('规则', 2)
            this.SectionButton('设置', 3)
          }.width('100%').padding({ top: 8, bottom: 8 })
        }
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8 })
    }
    }.width('100%').height('100%')
  }
}
