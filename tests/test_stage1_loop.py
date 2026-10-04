#!/usr/bin/env python3
"""Actual consumers of the narrow Stage-1 loop. Not ArkTS string search."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.extprobe import HdcError  # noqa: E402
from lib.provenance import SOURCE_INPUTS  # noqa: E402
from lib.stage1_loop import one_request, parse_http_status_line, unique_x5  # noqa: E402


class UniqueX5Test(unittest.TestCase):
    def test_two_targets_rejected(self) -> None:
        with self.assertRaises(HdcError):
            unique_x5("TEST_DEVICE_SERIAL\nABCDEF\n", serial="TEST_DEVICE_SERIAL")

    def test_wrong_model_rejected(self) -> None:
        with self.assertRaises(HdcError):
            unique_x5("TEST_DEVICE_SERIAL\n", serial="TEST_DEVICE_SERIAL", model="NOT-X5")

    def test_unique_x5_ok(self) -> None:
        unique_x5("TEST_DEVICE_SERIAL\n", serial="TEST_DEVICE_SERIAL", model="ALT-AL10")


class OneRequestTest(unittest.TestCase):
    def test_google_dump_text_is_not_http(self) -> None:
        rec = one_request(
            rid="g1",
            purpose="browser_google",
            generation_before="g",
            generation_after="g",
            revision_before=1,
            revision_after=1,
            tun_rx_before=0,
            tun_rx_after=10,
            tun_tx_before=0,
            tun_tx_after=10,
            hev_up_before=0,
            hev_up_after=10,
            hev_down_before=0,
            hev_down_after=10,
            access_window="accepted tcp:www.google.com:443 [tun-in -> proxy]\n",
            http_status=204,
            http_source="uitest-dump",
            dump_has_rid=True,
            page_ok=True,
            browser_pid="2",
            tongdao_pid="3",
            browser_uid="2",
            tongdao_uid="3",
            observed_browser_bundle="com.huawei.hmos.browser",
            production_rid="prod",
            access_offset=0,
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "google_http_not_from_http")

    def test_google_http_status_line_and_rule(self) -> None:
        rec = one_request(
            rid="g1",
            purpose="browser_google",
            generation_before="g",
            generation_after="g",
            revision_before=1,
            revision_after=1,
            tun_rx_before=0,
            tun_rx_after=10,
            tun_tx_before=0,
            tun_tx_after=10,
            hev_up_before=0,
            hev_up_after=10,
            hev_down_before=0,
            hev_down_after=10,
            access_window="accepted tcp:www.google.com:443 [tun-in -> proxy]\n",
            http_status=204,
            http_source="http-status-line",
            dump_has_rid=False,
            page_ok=False,
            browser_pid="2",
            tongdao_pid="3",
            browser_uid="2",
            tongdao_uid="3",
            observed_browser_bundle="com.huawei.hmos.browser",
            production_rid="prod",
            access_offset=0,
        )
        self.assertTrue(rec["ok"], rec)

    def test_gen_change_during_window_rejected(self) -> None:
        rec = one_request(
            rid="g1",
            purpose="browser_google",
            generation_before="old",
            generation_after="new",
            revision_before=1,
            revision_after=1,
            tun_rx_before=0,
            tun_rx_after=10,
            tun_tx_before=0,
            tun_tx_after=10,
            hev_up_before=0,
            hev_up_after=10,
            hev_down_before=0,
            hev_down_after=10,
            access_window="accepted tcp:www.google.com:443 [tun-in -> proxy]\n",
            http_status=204,
            http_source="http-status-line",
            dump_has_rid=True,
            page_ok=True,
            browser_pid="2",
            tongdao_pid="3",
            browser_uid="2",
            tongdao_uid="3",
            observed_browser_bundle="com.huawei.hmos.browser",
            production_rid="prod",
            access_offset=0,
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "generation_mismatch")

    def test_http_status_parser(self) -> None:
        code, src = parse_http_status_line("HTTP/1.1 204 No Content\n")
        self.assertEqual(code, 204)
        self.assertEqual(src, "http-status-line")
        code, src = parse_http_status_line("204 in dump text")
        self.assertEqual(code, 0)
        self.assertEqual(src, "not-http")


class HostCheckCliTest(unittest.TestCase):
    def test_source_inputs_include_loop(self) -> None:
        self.assertIn("scripts/lib/stage1_loop.py", SOURCE_INPUTS)
        self.assertIn("scripts/stage1-loop.py", SOURCE_INPUTS)

    def test_host_check_cli_runs_real_consumers(self) -> None:
        env = os.environ.copy()
        env["PYTHONPATH"] = str(ROOT / "scripts")
        proc = subprocess.run(
            [sys.executable, str(ROOT / "scripts/stage1-loop.py")],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        rec = json.loads(proc.stdout)
        self.assertTrue(rec["ok"])
        self.assertEqual(rec["role"], "narrow-loop-host")
        self.assertEqual(rec["dumpRejected"], "google_http_not_from_http")
        self.assertEqual(rec["genChangeRejected"], "generation_mismatch")
        loop = (ROOT / "scripts/stage1-loop.py").read_text(encoding="utf-8")
        self.assertIn("Path(__file__).resolve().parents[1]", loop)
        self.assertNotIn('Path("/path/to/pangolin")', loop)

    def test_device_flag_is_gated(self) -> None:
        env = os.environ.copy()
        env["PYTHONPATH"] = str(ROOT / "scripts")
        proc = subprocess.run(
            [sys.executable, str(ROOT / "scripts/stage1-loop.py"), "--device"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr + proc.stdout)
        rec = json.loads(proc.stdout)
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "device_run_gated")

    def test_device_oracles_refuse_without_authorization(self) -> None:
        env = os.environ.copy()
        env.pop("TONGDAO_DEVICE", None)
        env["PYTHONPATH"] = str(ROOT / "scripts")
        scripts = (
            "scripts/stage1-extprobe.py",
            "scripts/stage1-startstop5.py",
            "scripts/stage1-lifecycle-background.py",
        )
        for rel in scripts:
            proc = subprocess.run(
                [sys.executable, str(ROOT / rel)],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                env=env,
                timeout=10,
            )
            self.assertEqual(proc.returncode, 2, rel + proc.stderr + proc.stdout)
            rec = json.loads(proc.stdout)
            self.assertEqual(rec["reason"], "device_run_gated", rel)


if __name__ == "__main__":
    unittest.main()
