#!/usr/bin/env python3
"""Phase D contracts: Diagnostics page (4 checks + masked report export),
Settings privacy/data-management section (filesDir-only destructive ops with
Chinese confirm dialogs), About page sections, first-launch onboarding flag,
autoConnectOnLaunch once-per-process wiring, WorkScheduler subscription
refresh (workScheduler extension declared, no new permissions, >=2h clamp).
Source-level locks in the test_import_layer / test_ui_pages style."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry/src/main/ets"
PAGES = ETS / "pages"
SERVICES = ETS / "services"
WORK = ETS / "work"
MAIN_PAGES = ROOT / "entry/src/main/resources/base/profile/main_pages.json"
MODULE = ROOT / "entry/src/main/module.json5"

DIAGNOSTICS = PAGES / "Diagnostics.ets"
ABOUT = PAGES / "About.ets"
SETTINGS_PAGE = PAGES / "Settings.ets"
INDEX = PAGES / "Index.ets"
SUBSCRIPTIONS_PAGE = PAGES / "Subscriptions.ets"
DATA_MGMT = SERVICES / "DataManagement.ets"
DIAG_REPORT = SERVICES / "DiagnosticReport.ets"
SCHEDULER = SERVICES / "SubscriptionScheduler.ets"
WORK_ABILITY = WORK / "SubscriptionUpdateWorkAbility.ets"
SETTINGS_STORE = SERVICES / "SettingsStore.ets"
EVENT_STORE = SERVICES / "EventStore.ets"
PROBE = SERVICES / "ProbeSelfCheck.ets"
HUKS = SERVICES / "HuksSecretStore.ets"

# Phase D 不得新增任何权限；今日精确集合锁定。
PERMISSION_SET = {
    "ohos.permission.INTERNET",
    "ohos.permission.GET_NETWORK_INFO",
    "ohos.permission.KEEP_BACKGROUND_RUNNING",
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class RouteRegistration(unittest.TestCase):
    def test_phase_d_pages_registered(self) -> None:
        doc = json.loads(read(MAIN_PAGES))
        src = doc.get("src")
        self.assertIsInstance(src, list)
        self.assertEqual(src[0], "pages/Index", "pages/Index must stay the home page")
        for route in ("pages/Diagnostics", "pages/About"):
            self.assertIn(route, src, f"main_pages.json missing route {route}")

    def test_phase_d_pages_are_entry_components(self) -> None:
        for path in (DIAGNOSTICS, ABOUT):
            self.assertTrue(path.is_file(), f"missing page {path}")
            src = read(path)
            self.assertIn("@Entry", src)
            self.assertIn("@Component", src)


class DiagnosticsPageContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.src = read(DIAGNOSTICS)

    def test_four_checks_present(self) -> None:
        for label in ("本地网络", "DNS", "节点连接", "目标访问"):
            self.assertIn(label, self.src, f"Diagnostics missing check {label}")

    def test_checks_reuse_existing_probes(self) -> None:
        # 不允许重写探测：必须复用 NetReader / ProbeSelfCheck / tcpConnectCanary。
        self.assertIn("NetReader.read", self.src)
        self.assertIn("PROBE_SELF_CHECK.probeDnsOk", self.src)
        self.assertIn("PROBE_SELF_CHECK.probeHttpCode", self.src)
        self.assertIn("tcpConnectCanary", self.src)

    def test_verdicts_and_advice_in_plain_chinese(self) -> None:
        for anchor in (
            "网络没通（请检查 Wi-Fi 或蜂窝）",
            "DNS 解析失败",
            "节点不可用",
            "目标服务异常",
            "未连接（跳过）",
            "建议：",
            "切换节点",
            "检查订阅是否过期",
            "尝试重新连接",
        ):
            self.assertIn(anchor, self.src, f"Diagnostics missing verdict {anchor}")

    def test_report_export_masked_and_copied(self) -> None:
        self.assertIn("导出诊断报告", self.src)
        self.assertIn("DiagnosticReport.build", self.src)
        self.assertIn("pasteboard", self.src)
        self.assertIn("setData", self.src)
        self.assertIn("已复制（报告已脱敏）", self.src)

    def test_probe_self_check_exposes_additive_entrypoints(self) -> None:
        src = read(PROBE)
        self.assertIn("async probeDnsOk()", src)
        self.assertIn("async probeHttpCode(", src)
        # 复用而不是复制：公开入口必须落到既有私有实现上。
        self.assertIn("this.udpDns(", src)
        self.assertIn("this.httpCode(", src)


class DiagnosticReportContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.src = read(DIAG_REPORT)

    def test_scrub_credential_keys(self) -> None:
        for key in ("password", "uuid", "ssk"):
            self.assertIn(key, self.src, f"scrub list missing {key}")
        self.assertIn("'***'", self.src)

    def test_endpoint_masking_reused(self) -> None:
        self.assertIn("NodeStore.maskEndpointAddress", self.src)

    def test_report_shape(self) -> None:
        self.assertIn("diagnostic-report-", self.src)
        self.assertIn("REPORT_EVENT_LIMIT", self.src)
        self.assertIn("EventStore.load", self.src)
        self.assertIn("appVersion", self.src)
        self.assertIn("getBundleInfoForSelf", self.src)
        self.assertIn("FALLBACK_APP_VERSION", self.src)

    def test_no_full_urls_or_raw_subscription_fields(self) -> None:
        # 报告组装只引用状态/事件/检查结果，绝不读 nodes.json / subscriptions.json。
        self.assertNotIn("nodes.json", self.src)
        self.assertNotIn("subscriptions.json", self.src)


class SettingsPrivacyContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.src = read(SETTINGS_PAGE)
        self.mgmt = read(DATA_MGMT)

    def test_section_and_items(self) -> None:
        for anchor in (
            "隐私与数据管理",
            "清理日志",
            "诊断信息保留",
            "删除全部订阅与节点",
            "清空全部数据",
            "导出配置（含凭据）",
        ):
            self.assertIn(anchor, self.src, f"Settings missing {anchor}")

    def test_confirm_dialogs_list_consequences(self) -> None:
        self.assertIn("将删除全部", self.src)
        self.assertIn("个节点和", self.src)
        self.assertIn("个订阅", self.src)
        self.assertIn("节点、订阅、分流规则、设置、日志、已保存的节点凭据", self.src)
        self.assertIn("导出的文件包含节点密码和订阅链接，请勿分享给他人", self.src)
        self.assertIn("请先断开连接", self.src)

    def test_event_keep_persisted(self) -> None:
        self.assertIn("eventKeepCount", self.src)
        self.assertIn("EVENT_KEEP_OPTIONS", self.src)
        store = read(SETTINGS_STORE)
        self.assertIn("eventKeepCount: number = EVENT_KEEP_DEFAULT", store)
        self.assertIn("EVENT_KEEP_OPTIONS: Array<number> = [100, 400, 1000]", store)
        self.assertIn("EVENT_KEEP_DEFAULT: number = 400", store)

    def test_event_store_cap_additive(self) -> None:
        src = read(EVENT_STORE)
        self.assertIn("keepCount: number = 0", src, "append keepCount must be an optional param")
        self.assertIn("MAX_EVENTS", src)
        self.assertIn("eventKeepCount", src, "cap must read settings.json additively")
        self.assertIn("return MAX_EVENTS;", src, "default fallback must stay 400")

    def test_clear_logs_targets_known_filesdir_files(self) -> None:
        # 允许用字面量或 EventStore 常量名引用这些文件。
        accepted = {
            "dataplane-events.jsonl": ("dataplane-events.jsonl", "EVENTS_FILE"),
            "xray-access.log": ("xray-access.log",),
            "xray-access-pub.log": ("xray-access-pub.log",),
            "probe-fetch.json": ("probe-fetch.json",),
            "probe-loop-error.json": ("probe-loop-error.json",),
            "xray-timing.log": ("xray-timing.log",),
            "latency-http.json": ("latency-http.json",),
        }
        for name, spellings in accepted.items():
            ok = any(s in self.mgmt for s in spellings)
            self.assertTrue(ok, f"clearLogs missing {name}")

    def test_filesdir_only_deletion_guard(self) -> None:
        # 删除路径只允许经 StatusStore.removeFile（其内部固定拼 context.filesDir）。
        self.assertIn("assertSafeName", self.mgmt)
        self.assertNotRegex(self.mgmt, r"/data/", "must not reference absolute system paths")
        self.assertNotIn("filesDir}/../", self.mgmt)
        self.assertNotIn("cacheDir", self.mgmt)
        self.assertNotIn("tempDir", self.mgmt)
        self.assertNotIn("distributedFilesDir", self.mgmt)
        # Python mirror：LOG_FILES 每一项必须是纯文件名。
        block = re.search(r"LOG_FILES[^=]*=\s*\[(.*?)\]", self.mgmt, re.DOTALL)
        self.assertIsNotNone(block)
        names = re.findall(r"'([^']+)'", block.group(1))
        self.assertTrue(names, "LOG_FILES empty")
        for name in names:
            self.assertNotIn("/", name)
            self.assertNotIn("..", name)
            self.assertNotIn("\\", name)

    def test_wipe_all_clears_everything_and_huks(self) -> None:
        self.assertIn("USER_RULES_FILE", self.mgmt)
        self.assertIn("SETTINGS_FILE", self.mgmt)
        self.assertIn("HuksSecretStore.removeProtected", self.mgmt)
        huks = read(HUKS)
        self.assertIn("removeProtected", huks)
        self.assertIn("deleteKeyItem", huks)

    def test_export_writes_single_file_without_clipboard_copy(self) -> None:
        self.assertIn("DataManagement.exportConfig", self.src)
        self.assertIn("tongdao-config-export-", self.mgmt)
        # 导出配置不允许复制内容到剪贴板（太危险），只展示路径。
        export_block = re.search(
            r"confirmExportConfig\(\).*?\n  \}\n", self.src, re.DOTALL
        )
        self.assertIsNotNone(export_block)
        self.assertNotIn("pasteboard", export_block.group(0))


class AboutPageContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.src = read(ABOUT)

    def test_sections(self) -> None:
        for anchor in (
            "首次使用",
            "VPN 权限说明",
            "支持的格式与协议",
            "常见问题",
            "隐私政策与用户协议",
            "开源许可",
            "版本",
            "反馈",
        ):
            self.assertIn(anchor, self.src, f"About missing section {anchor}")

    def test_honest_content_anchors(self) -> None:
        for anchor in (
            "GPL-3.0",
            "Xray-core",
            "MPL-2.0",
            "libXray",
            "hev-socks5-tunnel",
            "MIT",
            "vless",
            "vmess",
            "trojan",
            "wireguard",
            "hysteria2",
            "anytls",
            "tuic",
            "Clash YAML",
            "SIP008",
            "base64",
        ):
            self.assertIn(anchor, self.src, f"About missing content {anchor}")

    def test_version_read_with_fallback(self) -> None:
        self.assertIn("DiagnosticReport.appVersion", self.src)
        self.assertIn("FALLBACK_APP_VERSION", self.src)

    def test_feedback_copy_via_pasteboard_write(self) -> None:
        self.assertIn("pasteboard", self.src)
        self.assertIn("setData", self.src)
        self.assertIn("邮箱已复制", self.src)


class OnboardingContracts(unittest.TestCase):
    def test_flag_and_dialog_on_index(self) -> None:
        src = read(INDEX)
        self.assertIn("onboarded.flag", src)
        self.assertIn("欢迎使用穿山", src)
        self.assertIn("开始使用", src)
        # 旗标必须落盘，且只弹一次（先读后写）。
        self.assertIn("StatusStore.readText(ctx, ONBOARD_FLAG_FILE)", src)
        self.assertIn("StatusStore.writeText(ctx, ONBOARD_FLAG_FILE", src)


class AutoConnectContracts(unittest.TestCase):
    def test_once_guard_and_idle_gate(self) -> None:
        src = read(INDEX)
        self.assertIn("autoConnectAttempted", src)
        self.assertIn("autoConnectOnLaunch", src)
        self.assertIn("maybeAutoConnect", src)
        # 必须与连接按钮走同一条路径。
        self.assertIn("this.startTunnel()", src)
        # 只在明确空闲/停止/失败时自动连接。
        self.assertIn("PHASE_IDLE", src)
        self.assertIn("PHASE_STOPPED", src)
        self.assertIn("PHASE_ERROR", src)

    def test_settings_toggle_no_longer_says_unwired(self) -> None:
        src = read(SETTINGS_PAGE)
        self.assertNotIn("只持久化", src, "Phase D 接线后不应再保留'只持久化'注释")


class SchedulerContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.sched = read(SCHEDULER)
        self.work = read(WORK_ABILITY)
        self.module = read(MODULE)

    def test_module_declares_work_scheduler_extension(self) -> None:
        self.assertIn('"type": "workScheduler"', self.module)
        self.assertIn("SubscriptionUpdateWorkAbility", self.module)
        self.assertIn("./ets/work/SubscriptionUpdateWorkAbility.ets", self.module)

    def test_no_new_permissions(self) -> None:
        granted = set(re.findall(r'"name":\s*"(ohos\.permission\.[^"]+)"', self.module))
        self.assertEqual(granted, PERMISSION_SET)

    def test_extension_ability_shape(self) -> None:
        self.assertIn("extends WorkSchedulerExtensionAbility", self.work)
        self.assertIn("onWorkStart", self.work)
        self.assertIn("onWorkStop", self.work)
        self.assertIn("SubscriptionManager.updateSubscription", self.work)
        # 关键正确性：独立进程上下文，存储访问走 this.context。
        self.assertIn("this.context", self.work)
        self.assertNotIn("UIAbilityContext", self.work)
        self.assertIn("MAX_SUBSCRIPTIONS_PER_RUN", self.work)

    def test_interval_clamped_to_two_hours(self) -> None:
        self.assertIn("MIN_REPEAT_MS", self.sched)
        self.assertRegex(self.sched, r"MIN_REPEAT_MS:\s*number\s*=\s*MIN_INTERVAL_HOURS \* 3600 \* 1000")
        self.assertIn("computeRepeatIntervalMs", self.sched)
        self.assertIn("NETWORK_TYPE_ANY", self.sched)
        self.assertIn("isRepeat: true", self.sched)
        self.assertIn("repeatCycleTime", self.sched)
        self.assertIn("workScheduler.startWork", self.sched)
        self.assertIn("workScheduler.stopWork", self.sched)

    def test_reschedule_triggered_from_mutations(self) -> None:
        settings = read(SETTINGS_PAGE)
        subs = read(SUBSCRIPTIONS_PAGE)
        self.assertIn("SubscriptionScheduler.reschedule", settings)
        self.assertIn("SubscriptionScheduler.reschedule", subs)

    def test_repeat_interval_mirror(self) -> None:
        """Python mirror of computeRepeatIntervalMs: min enabled+autoUpdate
        intervalHours, clamped to >= 2h, 0 when no target."""

        def compute(subs: list[dict]) -> int:
            best = 0
            for sub in subs:
                if not sub.get("enabled", True) or not sub.get("autoUpdate", True):
                    continue
                hours = sub.get("intervalHours", 24)
                if best == 0 or hours < best:
                    best = hours
            if best == 0:
                return 0
            ms = best * 3600 * 1000
            return max(ms, 2 * 3600 * 1000)

        self.assertEqual(compute([]), 0)
        self.assertEqual(compute([{"enabled": False}]), 0)
        self.assertEqual(compute([{"autoUpdate": False}]), 0)
        # 订阅页档位最小为 2h；即使落盘值被手工改小，调度也必须钳回 2h。
        self.assertEqual(compute([{"intervalHours": 1}]), 2 * 3600 * 1000)
        self.assertEqual(compute([{"intervalHours": 6}, {"intervalHours": 12}]),
                         6 * 3600 * 1000)
        self.assertEqual(
            compute([
                {"intervalHours": 6, "autoUpdate": False},
                {"intervalHours": 24},
            ]),
            24 * 3600 * 1000,
        )

    def test_max_five_per_fire(self) -> None:
        self.assertIn("MAX_SUBSCRIPTIONS_PER_RUN: number = 5", self.sched)
        self.assertIn("done < MAX_SUBSCRIPTIONS_PER_RUN", self.work)


class DataplaneUntouched(unittest.TestCase):
    def test_validated_dataplane_files_not_rewired(self) -> None:
        """Phase D 接线只允许出现在 pages/services/work/module.json5；
        数据面文件不得引用任何 Phase D 新模块。"""
        protected = (
            ETS / "vpn/TunnelVpnAbility.ets",
            ETS / "core/XrayRuntime.ets",
            ETS / "services/SplitRouter.ets",
            ETS / "services/NodeCatalog.ets",
        )
        for path in protected:
            src = read(path)
            for marker in (
                "pages/Diagnostics",
                "pages/About",
                "DataManagement",
                "DiagnosticReport",
                "SubscriptionScheduler",
                "workScheduler",
            ):
                self.assertNotIn(marker, src, f"{path.name} must not reference {marker}")


if __name__ == "__main__":
    unittest.main()
