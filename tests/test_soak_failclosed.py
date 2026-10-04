#!/usr/bin/env python3
"""Offline fixtures: soak3 must FAIL/INCONCLUSIVE, never keep CANARY_OK."""
from __future__ import annotations

import json
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.soak_round import SoakFail, evaluate_round  # noqa: E402
from lib.soak_run import SoakRunFail, check_final, start_summary  # noqa: E402

SERIAL = "TEST_DEVICE_SERIAL"
NOW = 1_788_437_800_000


def status_file(tmp: Path, name: str = "status.json", **kwargs) -> Path:
    doc = {
        "phase": "CANARY_OK",
        "generation": "gen-1",
        "at": NOW - 1000,
        "forwarderOk": True,
        "directOk": True,
        "proxyOk": True,
        "canaryOk": True,
        "sessionRevision": 1,
        "evidenceAt": NOW - 1000,
        "uploadBytes": 10,
        "downloadBytes": 20,
    }
    doc.update(kwargs)
    path = tmp / name
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def good_kwargs(tmp: Path) -> dict:
    return {
        "targets": SERIAL + "\n",
        "serial": SERIAL,
        "model": "ALT-AL10",
        "status_path": status_file(tmp),
        "tun": "vpn-tun: 100 1 0 0 0 0 0 0 50 1 0 0 0 0 0 0",
        "cb": "clashbox-absent",
        "vpn": "23653",
        "want_gen": "gen-1",
        "last_at": NOW - 5000,
        "now_ms": NOW,
    }


class SoakFailClosedTest(unittest.TestCase):
    def test_happy(self) -> None:
        tmp = Path(self.id().replace(".", "_"))
        # use tmp_path via mkdtemp in setUp
        pass

    def setUp(self) -> None:
        self.tmp = Path("/tmp") / f"soakfix-{time.time_ns()}"
        self.tmp.mkdir()

    def eval(self, **overrides):
        kw = good_kwargs(self.tmp)
        kw.update(overrides)
        return evaluate_round(**kw)

    def test_ok_round(self) -> None:
        rec = self.eval()
        self.assertTrue(rec["ok"])
        self.assertEqual(rec["generation"], "gen-1")

    def test_empty_targets(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(targets="[Empty]\n")
        self.assertIn("hdc_targets_not_unique_x5", ctx.exception.reason)

    def test_e001005_tun(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(tun="[Fail][E001005] Device not found or connected")
        self.assertIn("tun_unreadable", ctx.exception.reason)

    def test_stale_at(self) -> None:
        path = status_file(self.tmp, name="stale.json", at=NOW - 200000)
        with self.assertRaises(SoakFail) as ctx:
            self.eval(status_path=path, last_at=0, now_ms=NOW)
        self.assertIn("stale_at", ctx.exception.reason)

    def test_generation_change(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(want_gen="gen-old")
        self.assertIn("generation_changed", ctx.exception.reason)

    def test_tun_unreadable(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(tun="no-tun")
        self.assertIn("tun_unreadable", ctx.exception.reason)

    def test_vpn_pid_fail(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(vpn="[Fail]Not match target founded")
        self.assertIn("vpn_pid", ctx.exception.reason)

    def test_event_seq_gap(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(last_event_seq=10, event_seq=40)
        self.assertIn("event_seq_jump", ctx.exception.reason)

    def test_event_seq_rewind(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            self.eval(last_event_seq=10, event_seq=3)
        self.assertIn("event_seq_gap_or_rewind", ctx.exception.reason)

    def test_zero_round_summary_is_not_ok(self) -> None:
        doc = start_summary(run_id="g1-abc", generation="g1", start_ts=NOW // 1000, end_ts=NOW // 1000)
        doc["verdict"] = "OK"
        doc["durationSec"] = 0
        doc["rounds"] = 0
        with self.assertRaises(SoakRunFail) as ctx:
            check_final(doc, min_duration=7200, min_rounds=8)
        self.assertTrue("duration" in ctx.exception.reason or "round" in ctx.exception.reason)

    def test_short_plan_rejected(self) -> None:
        doc = start_summary(run_id="g1-abc", generation="g1", start_ts=100, end_ts=200)
        doc["verdict"] = "OK"
        doc["durationSec"] = 7200
        doc["rounds"] = 20
        doc["okRounds"] = 20
        with self.assertRaises(SoakRunFail):
            check_final(doc)

    def test_stale_json_cannot_keep_canary(self) -> None:
        """The soak2 bug: old CANARY_OK json + failed tun must not pass."""
        path = status_file(self.tmp, phase="CANARY_OK")
        with self.assertRaises(SoakFail):
            self.eval(status_path=path, tun="[Fail][E001005] Device not found")


if __name__ == "__main__":
    unittest.main()
