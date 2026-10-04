#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from lib.access_redact import redact_line, rotate_and_redact  # noqa: E402
from lib.atomic_file import read_status, write_atomic  # noqa: E402
from lib.soak_round import SoakFail, check_status_file  # noqa: E402


class AtomicTest(unittest.TestCase):
    def test_half_write_does_not_replace(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic(path, json.dumps({"phase": "CANARY_OK", "at": 1}))
            tmp = write_atomic(path, json.dumps({"phase": "CORRUPT"}), crash_after_tmp=True)
            self.assertIn("CANARY_OK", path.read_text())
            self.assertTrue(path.exists())
            self.assertTrue(tmp.exists())
            self.assertIn("CORRUPT", tmp.read_text())
            self.assertNotEqual(tmp.name, "dataplane-status.json.tmp")

    def test_half_write_status_rejected_as_stale_or_parse(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "status.json"
            path.write_text("{", encoding="utf-8")
            with self.assertRaises(SoakFail):
                check_status_file(path, "", 0, now_ms=10_000)


class AccessRedactTest(unittest.TestCase):
    def test_redact_local_port_and_bound(self) -> None:
        line = "from tcp:127.0.0.1:43050 accepted tcp:2001:4860::1:443 [tun-in -> proxy] user=abc pass=secret"
        out = redact_line(line)
        self.assertIn("127.0.0.1:*", out)
        self.assertNotIn("secret", out)
        self.assertNotIn("abc", out)
        self.assertNotIn("***abc", out)
        self.assertIn("2001:4860", out)

    def test_rotate_keeps_tail(self) -> None:
        raw = "a\n" * 1000
        bounded, pub = rotate_and_redact(raw, max_file=50, max_pub=20)
        self.assertLessEqual(len(bounded), 50)
        self.assertLessEqual(len(pub), 20)

    def test_producer_handle_survives_past_256k_without_path_replace(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "xray-access.log"
            with open(path, "ab", buffering=0) as producer:
                producer.write(b"A" * 256000 + b"\n")
                producer.flush()
                inode = path.stat().st_ino
                producer.write(b"accepted udp:8.8.8.8:53 [tun-in -> proxy]\n")
                producer.flush()
            text = path.read_text(encoding="utf-8", errors="replace")
            self.assertGreater(path.stat().st_size, 256000)
            self.assertEqual(path.stat().st_ino, inode)
            self.assertIn("udp:8.8.8.8:53 [tun-in -> proxy]", text)


if __name__ == "__main__":
    unittest.main()
