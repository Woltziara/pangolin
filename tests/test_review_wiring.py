#!/usr/bin/env python3
"""Wiring locks from 穿山-首版实现复核 2026-09-06."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry/src/main/ets"


def read(rel: str) -> str:
    return (ETS / rel).read_text(encoding="utf-8")


class RuntimeCapability(unittest.TestCase):
    def test_import_and_runtime_share_outbound_ready(self) -> None:
        xray = read("core/XrayRuntime.ets")
        ready = read("core/OutboundReady.ets")
        preview = read("pages/Import.ets")
        catalog = read("services/NodeCatalog.ets")
        self.assertIn("outboundRunError", ready)
        self.assertIn("enforceOutboundReady", xray)
        self.assertNotIn("Stage 1 只接受 TLS 节点", xray)
        self.assertIn("outboundRunError", preview)
        self.assertIn("无法连接", preview)
        self.assertIn("outboundIsRunnable", catalog)


class SelectionAndHealth(unittest.TestCase):
    def test_auto_select_does_not_require_us(self) -> None:
        split = read("services/SplitRouter.ets")
        index = read("pages/Index.ets")
        self.assertIn("没有可连接的节点", split)
        self.assertNotIn("没有可用的美国或其他节点", split)
        self.assertIn("hasRunnableCatalog", index)
        self.assertIn("SELECT_MANUAL", index)
        self.assertIn("还没有可连接的节点", index)

    def test_health_consumes_route_mode(self) -> None:
        tun = read("vpn/TunnelVpnAbility.ets")
        self.assertIn("tagsMatchRoute", tun)
        self.assertIn("googleDirect", tun)
        self.assertIn("payloadRouteMode", tun)
        self.assertNotIn("这是已知取舍", read("core/XrayRuntime.ets"))


class SubscriptionAndData(unittest.TestCase):
    def test_redirect_keeps_https_policy(self) -> None:
        sub = read("services/SubscriptionManager.ets")
        self.assertIn("opts.allowInsecureHttp", sub)
        self.assertNotIn("validateSubscriptionUrl(redirectUrl, true)", sub)
        self.assertIn("订阅已删除、关闭或已更改，未写入节点", sub)

    def test_wipe_removes_export_cache_and_save_picker(self) -> None:
        mgmt = read("services/DataManagement.ets")
        settings = read("pages/Settings.ets")
        self.assertIn("removeExportCaches", mgmt)
        self.assertIn("EXPORT_PREFIX", mgmt)
        self.assertIn("DocumentSaveOptions", settings)
        self.assertIn("请先断开连接再清理日志", settings)

    def test_group_unmapped_fails_closed(self) -> None:
        rules = read("core/UserRuleMap.ets")
        xray = read("core/XrayRuntime.ets")
        self.assertIn("unmappedGroupRuleError", rules)
        self.assertIn("unmappedGroupRuleError", xray)
        self.assertIn("当前没有对应线路", rules)

    def test_manual_failover_has_backup(self) -> None:
        catalog = read("services/NodeCatalog.ets")
        split = read("services/SplitRouter.ets")
        self.assertIn("single2", catalog)
        self.assertIn("version === 4", catalog)
        self.assertIn("pickManualBackup", split)


class HostPaths(unittest.TestCase):
    def test_stage1_scripts_resolve_root_from_file(self) -> None:
        for rel in (
            "scripts/stage1-extprobe.py",
            "scripts/stage1-startstop5.py",
            "scripts/stage1-lifecycle-background.py",
            "scripts/accept_chatgpt_visit.py",
        ):
            text = (ROOT / rel).read_text(encoding="utf-8")
            self.assertIn("Path(__file__).resolve().parents[1]", text, rel)
            self.assertNotIn('Path("/path/to/pangolin")', text, rel)
        ext = (ROOT / "scripts/stage1-extprobe.py").read_text(encoding="utf-8")
        self.assertIn("parse_http_status_line", ext)


if __name__ == "__main__":
    unittest.main()
