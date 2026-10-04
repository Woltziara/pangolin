#!/usr/bin/env python3
"""Import layer contracts: NodeStore v2 stays parseable by NodeCatalog rules,
attribution headers exist for borrowed Hey files, node-runner harness covers the
required fixture set. Source-level locks + JSON round-trip via a Python mirror
of parseNodeCatalog's extraction rules."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "entry/src/main/ets/core"
SERVICES = ROOT / "entry/src/main/ets/services"
FIXTURES = ROOT / "tests/fixtures/import"
NODE_RUNNER = ROOT / "tests/node-runner"

CATALOG_KEYS = ("name", "region", "server", "port", "protocol", "outbound")
V2_EXTRA_KEYS = (
    "id", "rawLink", "sourceId", "favorite", "group", "customName",
    "addedAt", "updatedAt", "latencyMs", "latencyText", "latencyAt",
)

BORROWED_FILES = (
    CORE / "ShareLinkParser.ets",
    CORE / "Encoding.ets",
    CORE / "IdnUrl.ets",
    CORE / "NodeDedupe.ets",
)

REQUIRED_FIXTURES = (
    "vmess.txt",
    "vless_reality.txt",
    "trojan.txt",
    "ss_sip002.txt",
    "ss_legacy.txt",
    "hy2.txt",
    "mixed_batch.txt",
    "subscription_base64.txt",
    "clash_min.yaml",
    "garbage.txt",
    "nodes_v2_sample.json",
)


def parse_node_catalog(raw: str) -> list[dict]:
    """Python mirror of NodeCatalog.parseNodeCatalog extraction rules:
    reads only known keys, ignores extras, drops records with empty name or
    short outbound."""
    nodes = json.loads(raw).get("nodes")
    if not isinstance(nodes, list):
        return []
    out = []
    for item in nodes:
        if not isinstance(item, dict):
            continue
        name = item.get("name") if isinstance(item.get("name"), str) else ""
        outbound = item.get("outbound")
        if not name or outbound is None:
            continue
        outbound_json = json.dumps(outbound, ensure_ascii=False)
        if len(outbound_json) < 20:
            continue
        out.append(
            {
                "name": name,
                "region": item.get("region") or "其他",
                "server": item.get("server") or "",
                "port": item.get("port") if isinstance(item.get("port"), (int, float)) else 0,
                "protocol": item.get("protocol") or "trojan",
                "outboundJson": outbound_json,
            }
        )
    return out


class NodeStoreV2Contract(unittest.TestCase):
    """NodeStore writes must remain readable by the production dataplane reader
    (NodeCatalog.parseNodeCatalog), including latency evidence fields."""

    def test_v2_fixture_round_trips_through_catalog_rules(self) -> None:
        raw = (FIXTURES / "nodes_v2_sample.json").read_text(encoding="utf-8")
        records = parse_node_catalog(raw)
        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["name"], "日本 trojan")
        self.assertEqual(rec["region"], "日本")
        self.assertEqual(rec["server"], "jp1.example.com")
        self.assertEqual(rec["port"], 8443)
        self.assertEqual(rec["protocol"], "trojan")
        outbound = json.loads(rec["outboundJson"])
        self.assertEqual(outbound["protocol"], "trojan")
        self.assertEqual(
            outbound["settings"]["servers"][0]["address"], "jp1.example.com"
        )

    def test_v2_fixture_carries_all_schema_keys(self) -> None:
        doc = json.loads((FIXTURES / "nodes_v2_sample.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["v"], 2)
        for node in doc["nodes"]:
            for key in CATALOG_KEYS + V2_EXTRA_KEYS:
                self.assertIn(key, node, f"v2 record missing key {key}")

    def test_nodestore_writer_emits_catalog_keys(self) -> None:
        """Source lock: recordToJson must populate every NodeCatalog key plus v."""
        src = (SERVICES / "NodeStore.ets").read_text(encoding="utf-8")
        body = re.search(
            r"private static recordToJson.*?\n  \}\n", src, re.DOTALL
        )
        self.assertIsNotNone(body, "recordToJson not found in NodeStore.ets")
        text = body.group(0)
        for key in CATALOG_KEYS + V2_EXTRA_KEYS:
            self.assertIn(f"record['{key}']", text, f"recordToJson drops {key}")
        self.assertIn("doc['v'] = NODES_SCHEMA_VERSION", src)
        self.assertIn("doc['nodes']", src)

    def test_nodestore_migrates_v1_records(self) -> None:
        src = (SERVICES / "NodeStore.ets").read_text(encoding="utf-8")
        self.assertIn("SOURCE_IMPORT", src)
        self.assertRegex(src, r"version\s*>=\s*NODES_SCHEMA_VERSION")
        # v1 files (no 'v' field) must still parse: version defaults to 1.
        self.assertRegex(src, r"typeof parsed\['v'\] === 'number' \? .*: 1")

    def test_v1_catalog_file_still_parseable(self) -> None:
        """A legacy v1 nodes.json (no 'v', only catalog keys) parses identically."""
        v1 = {
            "nodes": [
                {
                    "name": "legacy trojan",
                    "region": "美国",
                    "server": "us1.example.com",
                    "port": 443,
                    "protocol": "trojan",
                    "outbound": {
                        "protocol": "trojan",
                        "tag": "proxy",
                        "settings": {
                            "servers": [
                                {
                                    "address": "us1.example.com",
                                    "port": 443,
                                    "password": "fake",
                                }
                            ]
                        },
                    },
                }
            ]
        }
        records = parse_node_catalog(json.dumps(v1, ensure_ascii=False))
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["server"], "us1.example.com")

    def test_nodestore_uses_atomic_status_store_io(self) -> None:
        src = (SERVICES / "NodeStore.ets").read_text(encoding="utf-8")
        self.assertIn("StatusStore.readJsonFile", src)
        self.assertIn("StatusStore.writeJsonAtomic", src)
        store_src = (SERVICES / "StatusStore.ets").read_text(encoding="utf-8")
        self.assertIn("static readJsonFile", store_src)
        self.assertIn("static writeJsonAtomic", store_src)
        self.assertIn("recoverCanonical", store_src)


class SubscriptionLayerContracts(unittest.TestCase):
    def test_userinfo_header_parsed(self) -> None:
        src = (SERVICES / "SubscriptionManager.ets").read_text(encoding="utf-8")
        self.assertIn("subscription-userinfo", src)
        for field in ("upload", "download", "total", "expire"):
            self.assertRegex(src, rf"key === '{field}'")

    def test_fetch_constraints(self) -> None:
        src = (SERVICES / "SubscriptionManager.ets").read_text(encoding="utf-8")
        self.assertIn("MAX_REDIRECTS: number = 5", src)
        self.assertIn("HTTP_TIMEOUT_MS: number = 30000", src)
        self.assertIn("'Accept-Encoding': 'identity'", src)
        self.assertIn("穿山/0.1", src)

    def test_chinese_error_messages(self) -> None:
        src = (SERVICES / "SubscriptionManager.ets").read_text(encoding="utf-8")
        for phrase in ("网络不通", "订阅地址无效", "内容无法识别", "没有可用节点"):
            self.assertIn(phrase, src)

    def test_pure_core_files_have_no_kit_imports(self) -> None:
        for name in (
            "ShareLinkParser.ets",
            "SubscriptionParser.ets",
            "RegionGuess.ets",
            "Encoding.ets",
            "IdnUrl.ets",
            "NodeDedupe.ets",
        ):
            src = (CORE / name).read_text(encoding="utf-8")
            self.assertNotIn("@kit.", src, f"{name} must stay kit-free")
            self.assertNotIn("@ohos.", src, f"{name} must stay ohos-free")


class AttributionAndFixtures(unittest.TestCase):
    def test_borrowed_files_carry_hey_attribution(self) -> None:
        for path in BORROWED_FILES:
            head = path.read_text(encoding="utf-8")[:600]
            self.assertIn("Hey", head, f"{path.name} missing Hey attribution")
            self.assertIn("GPL-3.0", head, f"{path.name} missing GPL-3.0 note")
            self.assertIn("移植日期", head, f"{path.name} missing port date")

    def test_third_party_notices_list_borrowed_files(self) -> None:
        notices = (ROOT / "THIRD-PARTY-NOTICES.md").read_text(encoding="utf-8")
        for name in ("ShareLinkParser", "NodeDedupe", "Encoding", "IdnUrl"):
            self.assertIn(name, notices, f"THIRD-PARTY-NOTICES.md missing {name}")

    def test_fixture_set_complete_and_synthetic(self) -> None:
        for name in REQUIRED_FIXTURES:
            path = FIXTURES / name
            self.assertTrue(path.is_file(), f"missing fixture {name}")
            content = path.read_text(encoding="utf-8")
            self.assertNotIn("token=", content.replace("token=fake", ""))
        # 不得出现真实域名痕迹：fixtures 只允许 example.com / 127.0.0.1 与脱敏占位符。
        blob = "\n".join(
            (FIXTURES / name).read_text(encoding="utf-8")
            for name in REQUIRED_FIXTURES
            if name != "nodes_v2_sample.json"
        )
        self.assertNotIn("microsoft.com", blob.lower().replace("www.microsoft.com", ""))

    def test_node_runner_covers_pure_files(self) -> None:
        build = (NODE_RUNNER / "build.mjs").read_text(encoding="utf-8")
        for name in (
            "Encoding.ets",
            "IdnUrl.ets",
            "RegionGuess.ets",
            "ShareLinkParser.ets",
            "NodeDedupe.ets",
            "SubscriptionParser.ets",
        ):
            self.assertIn(name, build, f"node-runner build.mjs missing {name}")


if __name__ == "__main__":
    unittest.main()
