#!/usr/bin/env python3
"""Phase C contracts: settings.json defaults (absent file = today's behavior),
routeMode generation (rule chain untouched), v=4 single-node payload mapping,
failover user gating. Source-level locks in the test_import_layer style plus a
Python mirror round-trip for the v=4 payload mapping."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry/src/main/ets"
XRAY = ETS / "core/XrayRuntime.ets"
CATALOG = ETS / "services/NodeCatalog.ets"
SETTINGS_STORE = ETS / "services/SettingsStore.ets"
SPLIT = ETS / "services/SplitRouter.ets"
CONN = ETS / "services/ConnectionController.ets"
TUNNEL = ETS / "vpn/TunnelVpnAbility.ets"
SETTINGS_PAGE = ETS / "pages/Settings.ets"
INDEX = ETS / "pages/Index.ets"
MAIN_PAGES = ROOT / "entry/src/main/resources/base/profile/main_pages.json"

RULE_CHAIN = ("dnsHijack, dummyV6, privateRule, quicRule, youtubeRule, "
              "proxyProbeRule, cnDomainRule, cnIpRule, proxyRule")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_settings(doc: dict | None) -> dict:
    """Python mirror of SettingsStore.load: absent/corrupt file = defaults."""
    out = {
        "routeMode": "rule",
        "selectionMode": "auto",
        "manualNodeId": "",
        "failoverEnabled": True,
        "failoverGroup": "",
        "lastGoodNodeId": "",
        "autoConnectOnLaunch": False,
        "autoUpdateSubscriptions": True,
    }
    if not doc:
        return out
    if doc.get("routeMode") in ("global", "direct"):
        out["routeMode"] = doc["routeMode"]
    if doc.get("selectionMode") == "manual":
        out["selectionMode"] = "manual"
    for key in ("manualNodeId", "failoverGroup", "lastGoodNodeId"):
        if isinstance(doc.get(key), str) and doc[key]:
            out[key] = doc[key]
    for key in ("failoverEnabled", "autoConnectOnLaunch", "autoUpdateSubscriptions"):
        if isinstance(doc.get(key), bool):
            out[key] = doc[key]
    return out


def build_single_payload(node: dict, route_mode: str) -> dict:
    """Python mirror of NodeCatalog.buildSingleOutboundPayload."""
    rec = {
        "v": 4,
        "single": json.loads(node["outboundJson"]),
        "singleName": node["name"],
        "singleRegion": node["region"],
    }
    if route_mode:
        rec["routeMode"] = route_mode
    return rec


def map_payload_to_proxy_tags(payload: dict) -> tuple[dict, dict, bool]:
    """Python mirror of the version branch in buildRuntimeXrayConfig:
    returns (proxy_outbound, proxy_yt_outbound, has_yt)."""
    version = payload.get("v", 0)
    if version == 4:
        single = json.loads(json.dumps(payload["single"]))
        return single, json.loads(json.dumps(payload["single"])), True
    if version == 3:
        return payload["us"], payload["yt"], True
    if version == 2:
        return payload["us"], payload, False
    return payload, payload, False


class SettingsDefaultsContract(unittest.TestCase):
    def test_absent_file_means_todays_behavior(self) -> None:
        s = load_settings(None)
        self.assertEqual(s["routeMode"], "rule")
        self.assertEqual(s["selectionMode"], "auto")
        self.assertEqual(s["manualNodeId"], "")
        self.assertTrue(s["failoverEnabled"])
        self.assertEqual(s["failoverGroup"], "")
        self.assertFalse(s["autoConnectOnLaunch"])
        self.assertTrue(s["autoUpdateSubscriptions"])

    def test_corrupt_values_fall_back_to_defaults(self) -> None:
        s = load_settings({"routeMode": "bogus", "selectionMode": 42,
                           "failoverEnabled": "yes"})
        self.assertEqual(s["routeMode"], "rule")
        self.assertEqual(s["selectionMode"], "auto")
        self.assertTrue(s["failoverEnabled"])

    def test_store_source_locks(self) -> None:
        src = read(SETTINGS_STORE)
        self.assertIn("settings.json", src)
        self.assertIn("routeMode: string = ROUTE_RULE", src)
        self.assertIn("selectionMode: string = SELECT_AUTO", src)
        self.assertIn("failoverEnabled: boolean = true", src)
        self.assertIn("autoUpdateSubscriptions: boolean = true", src)
        self.assertIn("StatusStore.readJsonFile", src)
        self.assertIn("StatusStore.writeJsonAtomic", src)
        self.assertIn("requiresReconnect", src)


class RouteModeContract(unittest.TestCase):
    def test_rule_chain_unchanged(self) -> None:
        src = read(XRAY)
        self.assertIn(RULE_CHAIN, src, "rule mode chain must stay byte-identical")
        # default param keeps old call sites source-compatible
        self.assertIn("routeMode: string = ''", src)
        self.assertIn("resolveRouteMode(routeMode, parsed['routeMode'])", src)

    def test_global_mode_drops_cn_rules_keeps_safety_rules(self) -> None:
        src = read(XRAY)
        global_line = "dnsHijack, dummyV6, privateRule, quicRule, youtubeRule, proxyProbeRule, proxyRule"
        self.assertIn(global_line, src)
        self.assertIn("mode === 'global'", src)
        # private-net direct must stay (LAN loop prevention)
        self.assertLess(src.index("privateRule"), src.index(global_line))

    def test_direct_mode_all_direct_with_ipv6_blackhole(self) -> None:
        src = read(XRAY)
        self.assertIn("mode === 'direct'", src)
        self.assertIn("dnsHijack, dummyV6, privateRule, directRule", src)
        self.assertIn("directRule['outboundTag'] = 'direct'", src)


class SingleNodePayloadContract(unittest.TestCase):
    def _fixture_node(self) -> dict:
        outbound = {
            "protocol": "trojan",
            "settings": {"servers": [{"address": "us1.example.com", "port": 443}]},
            "streamSettings": {"security": "tls",
                               "tlsSettings": {"serverName": "us1.example.com"}},
        }
        return {"name": "美国-PRO-US1", "region": "美国",
                "outboundJson": json.dumps(outbound)}

    def test_v4_maps_both_proxy_tags_to_single_node(self) -> None:
        node = self._fixture_node()
        payload = build_single_payload(node, "rule")
        self.assertEqual(payload["v"], 4)
        proxy, proxy_yt, has_yt = map_payload_to_proxy_tags(payload)
        self.assertTrue(has_yt)
        self.assertEqual(proxy, proxy_yt)
        self.assertEqual(proxy["settings"]["servers"][0]["address"], "us1.example.com")
        # tags are assigned by the caller; both clones must be independent objects
        self.assertIsNot(proxy, proxy_yt)

    def test_v4_source_locks(self) -> None:
        xray = read(XRAY)
        self.assertIn("version === 4", xray)
        self.assertEqual(xray.count("cloneOutbound(parsed['single']"), 2)
        catalog = read(CATALOG)
        self.assertIn("buildSingleOutboundPayload", catalog)
        self.assertIn("rec['v'] = 4", catalog)
        self.assertIn("singleMetaJson", catalog)

    def test_split_payload_carries_route_mode(self) -> None:
        catalog = read(CATALOG)
        self.assertIn("routeMode: string = ''", catalog)
        self.assertIn("rec['routeMode'] = routeMode", catalog)


class ManualSelectionContract(unittest.TestCase):
    def test_split_router_manual_path_locks(self) -> None:
        src = read(SPLIT)
        self.assertIn("prepareManualPlan", src)
        self.assertIn("buildSingleOutboundPayload", src)
        # manual path must not ping the whole catalog
        manual = src.split("export function prepareManualPlan")[1].split("export function")[0]
        self.assertNotIn("pingAll", manual)
        self.assertNotIn("tcpConnectCanary", manual)
        self.assertIn("PREPARE_HINT_FILE", src)

    def test_connection_controller_branches_on_selection_mode(self) -> None:
        src = read(CONN)
        self.assertIn("SettingsStore.load(context)", src)
        self.assertIn("settings.selectionMode === SELECT_MANUAL", src)
        self.assertIn("prepareManualPlan(context, settings.manualNodeId)", src)
        self.assertIn("选定节点不存在或暂不支持连接，请重新选择节点。", src)
        self.assertNotIn("固定节点已失效，本次按自动选择", src)
        self.assertIn("prepareSingleProxy", src)
        # remember-last on CANARY_OK
        self.assertIn("rememberLastGood", src)
        self.assertIn("lastGoodNodeId", src)

    def test_failover_group_filters_second_best(self) -> None:
        src = read(SPLIT)
        self.assertIn("settings.failoverGroup.length > 0", src)
        self.assertIn("filterByGroup", src)
        self.assertIn("组内无备用节点", src)


class FailoverGateContract(unittest.TestCase):
    def test_tunnel_reads_failover_toggle_once_at_start(self) -> None:
        src = read(TUNNEL)
        self.assertIn("private failoverEnabled: boolean = true", src)
        self.assertIn("userSettings = SettingsStore.load(this.context)", src)
        self.assertIn("autoFailoverEnabled", src)
        self.assertIn("legShouldPromote", src)
        self.assertIn("组内无备用节点", src)

    def test_failover_flags_reach_node_meta(self) -> None:
        catalog = read(CATALOG)
        self.assertIn("meta['ytFailedOver'] = rec['ytFailedOver'] === true", catalog)
        self.assertIn("meta['usFailedOver'] = rec['usFailedOver'] === true", catalog)


class SettingsPageContract(unittest.TestCase):
    def test_route_registered(self) -> None:
        doc = json.loads(read(MAIN_PAGES))
        self.assertIn("pages/Settings", doc["src"])

    def test_page_sections_and_strings(self) -> None:
        src = read(SETTINGS_PAGE)
        for anchor in (
            "@Entry",
            "节点选择",
            "固定节点",
            "清除固定，回到自动选择",
            "故障切换",
            "自动切换备用节点",
            "限定分组",
            "所有分组",
            "启动即连接",
            "自动更新订阅",
            "需要重新连接才能生效",
            "立即重连",
            "SettingsStore.requiresReconnect",
            "CONNECTION_CONTROLLER.stop",
            "CONNECTION_CONTROLLER.start",
        ):
            self.assertIn(anchor, src, f"Settings page missing {anchor}")
        # Connection modes now belong to the Rules tab; preserve the choices and write path.
        rules_src = read(SETTINGS_PAGE.with_name("Rules.ets"))
        for anchor in ("连接模式", "按规则连接", "全局代理", "全部直连", "SettingsStore.update", "this.afterRuleChange()"):
            self.assertIn(anchor, rules_src, f"Rules page missing moved setting {anchor}")

    def test_index_entry_and_status_lines(self) -> None:
        src = read(INDEX)
        self.assertIn("Settings({ embedded: true })", src)
        self.assertIn(".tabBar('设置')", src)
        self.assertIn("SettingsStore.load", src)
        self.assertIn("makeModeLine", src)
        self.assertIn("已切换到备用节点", src)
        self.assertIn("（原线路持续无法连接）", src)
        self.assertIn("PREPARE_HINT_FILE", src)


if __name__ == "__main__":
    unittest.main()
