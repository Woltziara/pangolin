#!/usr/bin/env python3
"""Second-best failover: JSON contract + source locks. No periodic retune."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "entry/src/main/ets/services/NodeCatalog.ets"
SPLIT = ROOT / "entry/src/main/ets/services/SplitRouter.ets"
STORE = ROOT / "entry/src/main/ets/services/StatusStore.ets"
TUNNEL = ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets"


def _payload(yt: str, us: str, yt2: str | None = None, us2: str | None = None) -> dict:
    rec = {
        "v": 3,
        "yt": {"tag": "proxy-yt", "name": yt},
        "us": {"tag": "proxy", "name": us},
        "ytName": yt,
        "usName": us,
        "ytRegion": "日本",
        "usRegion": "美国",
        "ytFailedOver": False,
        "usFailedOver": False,
    }
    if yt2:
        rec["yt2"] = {"tag": "proxy-yt", "name": yt2}
        rec["yt2Name"] = yt2
        rec["yt2Region"] = "新加坡"
    if us2:
        rec["us2"] = {"tag": "proxy", "name": us2}
        rec["us2Name"] = us2
        rec["us2Region"] = "美国"
    return rec


def failover_split_payload(payload: str, swap_yt: bool, swap_us: bool) -> str:
    rec = json.loads(payload)
    if rec.get("v") != 3:
        return payload
    changed = False
    if swap_yt and rec.get("ytFailedOver") is not True and rec.get("yt2") is not None:
        rec["yt"], rec["yt2"] = rec["yt2"], rec["yt"]
        rec["ytName"], rec["yt2Name"] = rec.get("yt2Name", ""), rec.get("ytName", "")
        rec["ytRegion"], rec["yt2Region"] = rec.get("yt2Region", ""), rec.get("ytRegion", "")
        rec["ytFailedOver"] = True
        changed = True
    if swap_us and rec.get("usFailedOver") is not True and rec.get("us2") is not None:
        rec["us"], rec["us2"] = rec["us2"], rec["us"]
        rec["usName"], rec["us2Name"] = rec.get("us2Name", ""), rec.get("usName", "")
        rec["usRegion"], rec["us2Region"] = rec.get("us2Region", ""), rec.get("usRegion", "")
        rec["usFailedOver"] = True
        changed = True
    if not changed:
        return payload
    return json.dumps(rec, ensure_ascii=False)


class SplitFailoverContract(unittest.TestCase):
    def test_swap_youtube_once_to_second_best(self) -> None:
        raw = json.dumps(_payload("jp2", "us1", yt2="jp1", us2="us2"), ensure_ascii=False)
        once = json.loads(failover_split_payload(raw, True, False))
        self.assertEqual(once["ytName"], "jp1")
        self.assertEqual(once["yt"]["name"], "jp1")
        self.assertEqual(once["yt2Name"], "jp2")
        self.assertTrue(once["ytFailedOver"])
        self.assertEqual(once["usName"], "us1")
        self.assertFalse(once["usFailedOver"])
        twice = failover_split_payload(json.dumps(once), True, False)
        self.assertEqual(twice, json.dumps(once))

    def test_swap_us_once_to_second_best(self) -> None:
        raw = json.dumps(_payload("jp2", "us1", yt2="jp1", us2="us2"), ensure_ascii=False)
        once = json.loads(failover_split_payload(raw, False, True))
        self.assertEqual(once["usName"], "us2")
        self.assertEqual(once["us"]["name"], "us2")
        self.assertTrue(once["usFailedOver"])
        self.assertEqual(once["ytName"], "jp2")

    def test_no_backup_is_noop(self) -> None:
        raw = json.dumps(_payload("jp2", "us1"), ensure_ascii=False)
        self.assertEqual(failover_split_payload(raw, True, True), raw)

    def test_v2_payload_is_noop(self) -> None:
        raw = json.dumps({"v": 2, "us": {"name": "us1"}}, ensure_ascii=False)
        self.assertEqual(failover_split_payload(raw, True, True), raw)


class SplitFailoverSource(unittest.TestCase):
    def test_open_ranks_second_best_and_fail_promotes_via_recover(self) -> None:
        catalog = CATALOG.read_text(encoding="utf-8")
        split = SPLIT.read_text(encoding="utf-8")
        store = STORE.read_text(encoding="utf-8")
        tun = TUNNEL.read_text(encoding="utf-8")
        self.assertIn("pickSecondBest", catalog)
        self.assertIn("failoverSplitPayload", catalog)
        self.assertIn("failoverSplitMeta", catalog)
        self.assertIn("ytFailedOver", catalog)
        self.assertIn("usFailedOver", catalog)
        self.assertIn("rec['yt2']", catalog)
        self.assertIn("pickSecondBest", split)
        self.assertIn("buildSplitOutboundPayload(yt, us, yt2, us2", split)
        self.assertNotIn("StatusStore.applyNode(context, us)", split)
        self.assertIn("buildSplitOutboundPayload(yt, us, yt2, us2)", store)
        self.assertIn("NODE_FAIL_LIMIT", tun)
        self.assertIn("promoteSecondBest", tun)
        self.assertIn("node-failover", tun)
        self.assertIn("www.youtube.com", tun)
        self.assertIn("'/generate_204'", tun)
        self.assertIn("requestRecover('node-failover')", tun)
        self.assertNotIn("maybeRetuneYouTube", tun)
        self.assertNotIn("YT_RETUNE_MS", tun)
        self.assertLess(tun.index("polling = false"), tun.index("requestRecover('node-failover')"))
        native = (ROOT / "entry/src/main/cpp/napi_init.cpp").read_text(encoding="utf-8")
        self.assertIn("waiter->token == token", native)
        self.assertIn("abandoned", native)
        self.assertIn("argc < 3", native)


if __name__ == "__main__":
    unittest.main()
