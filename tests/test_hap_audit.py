#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HAP = ROOT / "entry/build/default/outputs/default/entry-default-signed.hap"
NOTICE = ROOT / "THIRD-PARTY-NOTICES.md"
LICENSE = ROOT / "LICENSE"


class HapAuditTest(unittest.TestCase):
    def test_license_and_notice_present(self) -> None:
        self.assertTrue(LICENSE.is_file())
        text = NOTICE.read_text(encoding="utf-8")
        self.assertIn("Xray-core", text)
        self.assertIn("hev-socks5-tunnel", text)
        self.assertIn("GPL-3.0", text)

    def test_signed_hap_has_no_secrets_or_experiment_libs(self) -> None:
        if not HAP.is_file():
            self.skipTest("signed hap not built yet")
        names: list[str] = []
        with zipfile.ZipFile(HAP) as zf:
            names = zf.namelist()
            runtime = [n for n in names if "rawfile/runtime" in n.lower() and n.endswith(".json")]
            for name in runtime:
                raw = zf.read(name).decode("utf-8", errors="replace")
                if re.search(r'"(password|passwd|token|secret|privateKey)"\s*:\s*"(?!")[^"]{4,}"', raw, re.I):
                    self.fail(f"secret field in {name}")
                if "trojan://" in raw or "vless://" in raw:
                    self.fail(f"share link in {name}")
        joined = "\n".join(names).lower()
        for banned in ("libgotest.so", "libsingbox.so", "libheytun2socks.so"):
            self.assertNotIn(banned, joined)
        self.assertTrue(any("libxray.so" in n.lower() for n in names))
        self.assertTrue(any("libhevsocks5tun.so" in n.lower() for n in names))


if __name__ == "__main__":
    unittest.main()
