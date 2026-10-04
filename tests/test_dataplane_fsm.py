#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from lib.dataplane_fsm import (  # noqa: E402
    CORE_RESTART_LIMIT,
    PHASE_CANARY_OK,
    PHASE_ERROR,
    PHASE_STOPPED,
    Plane,
)


class FsmTest(unittest.TestCase):
    def test_stale_session_async_writeback_dropped(self) -> None:
        p = Plane()
        p.start("g1")
        p.bind_probe("rid-1")
        p.grow()
        p.cancelled = True
        p.async_stale_write("g1", "canary-ok")
        self.assertTrue(any(x.startswith("drop-stale") for x in p.writes))
        self.assertEqual(p.phase, PHASE_CANARY_OK)

    def test_old_generation_write_dropped(self) -> None:
        p = Plane()
        p.start("g2")
        p.async_stale_write("g1", "recover-end")
        self.assertIn("drop-stale:recover-end", p.writes)

    def test_stop_failure_fail_closed(self) -> None:
        p = Plane()
        p.start("g1")
        p.teardown(stop_xray_ok=False, stop_hev_ok=True, destroy_ok=True)
        self.assertEqual(p.phase, PHASE_ERROR)
        self.assertFalse(p.vpn_created)
        self.assertIn("teardown-error", p.writes)

    def test_tun_destroy_failure(self) -> None:
        p = Plane()
        p.start("g1")
        p.teardown(True, True, destroy_ok=False)
        self.assertEqual(p.phase, PHASE_ERROR)

    def test_clean_teardown_stopped(self) -> None:
        p = Plane()
        p.start("g1")
        p.teardown(True, True, True)
        self.assertEqual(p.phase, PHASE_STOPPED)

    def test_network_switch_recover(self) -> None:
        p = Plane()
        p.start("g1")
        p.net_lost()
        result = p.net_available()
        self.assertEqual(result, "ok")
        self.assertEqual(p.session_revision, 2)

    def test_recover_quota_resets_on_canary(self) -> None:
        p = Plane()
        p.start("g1")
        p.recover()
        p.recover()
        self.assertEqual(p.core_restarts, 2)
        p.bind_probe("rid-1")
        p.grow()
        self.assertEqual(p.core_restarts, 0)
        self.assertEqual(p.phase, PHASE_CANARY_OK)
        self.assertEqual(p.recover() , "ok")

    def test_recover_limit(self) -> None:
        p = Plane()
        p.start("g1")
        for _ in range(CORE_RESTART_LIMIT):
            p.recover()
        self.assertEqual(p.recover(), "limit")
        self.assertEqual(p.phase, PHASE_ERROR)

    def test_cancelled_recover_does_not_advance_revision(self) -> None:
        p = Plane()
        p.start("g1")
        p.cancelled = True
        self.assertEqual(p.recover(), "skip")
        self.assertEqual(p.session_revision, 1)


if __name__ == "__main__":
    unittest.main()
