#!/usr/bin/env python3
"""UI timer freeze vs official DATA_TRANSFER background probe."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.background_probe import BackgroundProbeModel  # noqa: E402

INDEX = ROOT / "entry/src/main/ets/pages/Index.ets"
ENTRY = ROOT / "entry/src/main/ets/entryability/EntryAbility.ets"
KEEP = ROOT / "entry/src/main/ets/services/BackgroundKeepAlive.ets"
HOST = ROOT / "entry/src/main/ets/services/BackgroundProbeHost.ets"
MODULE = ROOT / "entry/src/main/module.json5"
PROBE = ROOT / "entry/src/main/ets/services/ProbeSelfCheck.ets"


class BackgroundProbeFreezeTest(unittest.TestCase):
    def test_index_timer_frozen_does_not_ack(self) -> None:
        m = BackgroundProbeModel()
        m.index_appear()
        m.pulse("r1")
        self.assertEqual(m.owners_for("r1"), ["index"])
        m.on_background(keep_alive_ok=True)
        m.pulse("r2")
        self.assertEqual(m.owners_for("r2"), ["entry-background"])
        self.assertNotIn("index", m.owners_for("r2"))

    def test_without_continuous_task_nothing_acks(self) -> None:
        m = BackgroundProbeModel()
        m.index_appear()
        m.on_background(keep_alive_ok=False)
        m.pulse("r3")
        self.assertEqual(m.owners_for("r3"), [])
        self.assertIn("startBackgroundRunning failed", m.last_error)

    def test_index_disappear_does_not_stop_entry_loop(self) -> None:
        m = BackgroundProbeModel()
        m.on_background(keep_alive_ok=True)
        m.index_disappear()
        m.pulse("r4")
        self.assertEqual(m.owners_for("r4"), ["entry-background"])


class BackgroundProbeSourceTest(unittest.TestCase):
    def test_index_refresh_timer_does_not_drive_probe(self) -> None:
        text = INDEX.read_text(encoding="utf-8")
        self.assertNotIn("PROBE_SELF_CHECK.tick", text)
        self.assertIn("this.refresh()", text)
        self.assertNotIn("PROBE_SELF_CHECK.startLoop", text)
        self.assertIn("BACKGROUND_PROBE_HOST.stop", text)
        self.assertNotIn("BACKGROUND_PROBE_HOST.stop(this.context, 'aboutToDisappear'", text)

    def test_entry_ability_uses_official_vpn_keepalive(self) -> None:
        text = ENTRY.read_text(encoding="utf-8")
        self.assertIn("onBackground", text)
        self.assertIn("BACKGROUND_PROBE_HOST.start", text)
        self.assertIn("harmonyos-faqs/faqs-network-134", text)
        keep = KEEP.read_text(encoding="utf-8")
        self.assertIn("startBackgroundRunning", keep)
        self.assertIn("dataTransfer", keep)
        self.assertIn("KEEP_BACKGROUND_RUNNING", keep)
        self.assertIn("background-keepalive.json", keep)
        host = HOST.read_text(encoding="utf-8")
        self.assertIn("BACKGROUND_KEEP_ALIVE.ensure", host)
        self.assertNotIn("PROBE_SELF_CHECK.startLoop", host)
        self.assertNotIn("source.indexOf('onBackground')", host)
        probe = PROBE.read_text(encoding="utf-8")
        self.assertIn("startLoop", probe)
        self.assertIn("entry-background", probe)
        self.assertNotIn("ui-self", probe)

    def test_module_declares_system_grant_background_mode(self) -> None:
        text = MODULE.read_text(encoding="utf-8")
        self.assertIn("ohos.permission.KEEP_BACKGROUND_RUNNING", text)
        self.assertIn("dataTransfer", text)
        self.assertIn("EntryAbility", text)

    def test_keep_alive_records_identity_and_events(self) -> None:
        keep = KEEP.read_text(encoding="utf-8")
        self.assertIn("notificationId", keep)
        self.assertIn("getAllContinuousTasks", keep)
        self.assertIn("startTouchTimer", keep)
        self.assertIn("usual.event.SCREEN_OFF", keep)
        self.assertIn("60000", keep)
        self.assertIn("9800005", keep)
        self.assertIn("without synthetic download progress", keep)
        self.assertNotIn("progressValue: value % 100", keep)
        self.assertNotIn("downloadTemplate", keep)
        self.assertIn("DATA_TRANSFER_NOT_UPDATE", keep)
        self.assertNotIn("updateBackgroundRunning", keep)
        host = HOST.read_text(encoding="utf-8")
        self.assertNotIn("source.indexOf('onForeground')", host)
        self.assertNotIn("source.indexOf('onCreate')", host)
        self.assertIn("desiredRunning === true", host)

    def test_live_view_failure_does_not_drop_data_transfer(self) -> None:
        m = BackgroundProbeModel()
        self.assertEqual(m.start_tunnel(keep_alive_ok=True), "keep-alive-then-wait-canary")
        keep = m.keep
        self.assertTrue(keep.start(ok=True, live_view=False))
        self.assertTrue(keep.running)
        self.assertTrue(keep.system_present)
        self.assertTrue(keep.start(ok=False, already_applied=True))
        self.assertTrue(keep.running)
        probe = PROBE.read_text(encoding="utf-8")
        self.assertIn("ackOk", probe)
        self.assertIn("validateDnsResponse", probe)

    def test_taskpool_is_not_the_keep_alive(self) -> None:
        for path in (ENTRY, KEEP, HOST, PROBE, INDEX):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("taskpool", text.lower())
            self.assertNotIn("TaskPool", text)
