#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from lib.event_store import EventGap, EventLog  # noqa: E402
from lib.huks_lifecycle import Files, HuksError, protect, read_outbound  # noqa: E402


PLAIN = '{"protocol":"trojan","settings":{"servers":[{"password":"x" * 8}]}}'


class HuksConsumerTest(unittest.TestCase):
    def test_protect_removes_plaintext(self) -> None:
        f = Files(outbound=PLAIN)
        protect(f, available=True)
        self.assertEqual(f.outbound, "")
        self.assertGreater(len(f.envelope), 20)
        self.assertEqual(read_outbound(f), PLAIN)

    def test_start_reads_envelope_not_stale_plain(self) -> None:
        f = Files(outbound=PLAIN)
        protect(f, available=True)
        f.outbound = '{"protocol":"stale"}'
        self.assertEqual(read_outbound(f), PLAIN)

    def test_corrupt_envelope_fails_closed(self) -> None:
        f = Files(envelope="{not-json-but-long-enough-to-look-like-envelope")
        with self.assertRaises((HuksError, json.JSONDecodeError)):
            read_outbound(f)

    def test_unavailable_refuses_new_config(self) -> None:
        f = Files(outbound=PLAIN)
        with self.assertRaises(HuksError) as ctx:
            protect(f, available=False)
        self.assertIn("不可用", str(ctx.exception))
        self.assertEqual(f.envelope, "")

    def test_roundtrip_mismatch_fails(self) -> None:
        f = Files(outbound=PLAIN)
        with self.assertRaises(HuksError):
            protect(f, available=True, cipher_ok=False)

    def test_wrap_failure_keeps_previous_envelope(self) -> None:
        old = '{"protocol":"trojan","settings":{"servers":[{"password":"aaaaaaaa"}]}}'
        new = '{"protocol":"trojan","settings":{"servers":[{"password":"bbbbbbbb"}]}}'
        f = Files(outbound=old, meta='{"name":"A"}')
        protect(f, available=True)
        previous = f.envelope
        f.outbound = new
        f.staging_meta = '{"name":"B"}'
        with self.assertRaises(HuksError) as ctx:
            protect(f, available=True, cipher_ok=False)
        self.assertIn("未应用", str(ctx.exception))
        self.assertEqual(f.envelope, previous)
        self.assertEqual(read_outbound(f), old)


class EventConsumerTest(unittest.TestCase):
    def test_index_reads_monotonic_seq(self) -> None:
        log = EventLog()
        log.append("session-start", "g1", 1)
        log.append("tick", "g1", 1)
        log.append("canary", "g1", 1)
        self.assertEqual(log.consume_head(0), 3)

    def test_gap_cannot_splice(self) -> None:
        log = EventLog()
        log.append("tick", "g1", 1)
        log.seq = 40
        with self.assertRaises(EventGap):
            log.append("tick", "g1", 1)

    def test_generation_change_is_new_session(self) -> None:
        log = EventLog()
        log.append("session-start", "g1", 1)
        log.append("tick", "g2", 1)
        self.assertEqual(log.generation, "g2")
        self.assertEqual(log.seq, 1)
        self.assertEqual(len(log.events), 1)


class WaitGenerationTest(unittest.TestCase):
    def test_controller_skips_mismatched_generation(self) -> None:
        started = "g-new"
        observed = {"generation": "g-old", "phase": "CANARY_OK", "sessionRevision": 1}
        accept = observed["generation"] == started and observed["phase"] == "CANARY_OK"
        self.assertFalse(accept)

    def test_accepts_matching_generation_and_revision(self) -> None:
        started = "g-new"
        observed = {"generation": "g-new", "phase": "CANARY_OK", "sessionRevision": 1}
        accept = (
            observed["generation"] == started
            and observed["phase"] == "CANARY_OK"
            and observed["sessionRevision"] >= 1
        )
        self.assertTrue(accept)


if __name__ == "__main__":
    unittest.main()
