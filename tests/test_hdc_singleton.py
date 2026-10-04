#!/usr/bin/env python3
"""Duplicate hdc-wait must exit and must not launch a second bringup."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.hdc_singleton import DuplicateWaiter, WaitHarness, acquire, release, try_acquire  # noqa: E402

WAIT_SH = ROOT / "scripts/stage1-hdc-wait.sh"
BRINGUP_SH = ROOT / "scripts/stage1-bringup-soak.sh"


class SingletonLockTest(unittest.TestCase):
    def test_second_acquire_fails_while_holder_live(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "hdc-wait.lock"
            alive = {11: True, 22: True}
            pid, token = acquire(lock, 11, alive.get)
            self.assertEqual(pid, 11)
            ok, holder, _tok = try_acquire(lock, 22, alive.get)
            self.assertFalse(ok)
            self.assertEqual(holder, 11)
            release(lock, 11, token)

    def test_stale_pid_can_be_taken_over(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "hdc-wait.lock"
            alive = {11: False, 22: True}
            _pid, token = acquire(lock, 11, alive.get)
            release(lock, 11, token)
            pid, token = acquire(lock, 22, alive.get)
            self.assertEqual(pid, 22)
            release(lock, 22, token)

    def test_duplicate_waiter_does_not_bringup(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            wait_lock = Path(raw) / "wait.lock"
            bring_lock = Path(raw) / "bring.lock"
            alive: dict[int, bool] = {}
            a = WaitHarness(wait_lock, bring_lock, 1, alive)
            b = WaitHarness(wait_lock, bring_lock, 2, alive)
            self.assertEqual(a.start(x5_visible=True), "bringup")
            self.assertEqual(b.start(x5_visible=True), "duplicate-exit:1")
            self.assertEqual(a.bringups, [1])
            self.assertEqual(b.bringups, [])

    def test_two_bringups_serialized_even_if_wait_lock_bypassed(self) -> None:
        """Old bug: two waiters both reached bringup. Lock must allow only one."""
        with tempfile.TemporaryDirectory() as raw:
            wait_lock = Path(raw) / "wait.lock"
            bring_lock = Path(raw) / "bring.lock"
            alive: dict[int, bool] = {1: True, 2: True}
            a = WaitHarness(wait_lock, bring_lock, 1, alive)
            b = WaitHarness(wait_lock, bring_lock, 2, alive)
            self.assertEqual(a.bringup(), "bringup")
            self.assertTrue(b.bringup().startswith("bringup-skipped"))
            self.assertEqual(a.bringups, [1])
            self.assertEqual(b.bringups, [])

    def test_old_pidfile_overwrite_allows_two_bringups(self) -> None:
        """The 10:04 bug: echo $$ > pidfile does not stop a second waiter."""
        with tempfile.TemporaryDirectory() as raw:
            pidf = Path(raw) / "hdc-wait.pid"
            bringups: list[int] = []

            def old_start(pid: int) -> None:
                pidf.write_text(str(pid))
                bringups.append(pid)

            old_start(1652)
            old_start(83837)
            self.assertEqual(bringups, [1652, 83837])
            self.assertEqual(pidf.read_text(), "83837")


class ScriptSourceGuardTest(unittest.TestCase):
    def test_wait_is_observe_only_and_holds_flock(self) -> None:
        text = WAIT_SH.read_text(encoding="utf-8")
        self.assertIn("hold", text)
        self.assertIn("wait-acquired", text)
        self.assertIn("HDC_WAIT_DUPLICATE", text)
        self.assertIn("exit 3", text)
        self.assertIn("no-auto-install", text)
        self.assertNotIn("stage1-bringup-soak.sh", text)
        self.assertNotIn("hdc install", text)
        self.assertNotIn("hdc_singleton.py acquire", text)

    def test_bringup_refuses_without_install_gate(self) -> None:
        text = BRINGUP_SH.read_text(encoding="utf-8")
        self.assertIn("TONGDAO_INSTALL", text)
        self.assertIn("wait-acquired", text)
        self.assertIn("BRINGUP_DUPLICATE", text)
        self.assertIn("exit 3", text)
        self.assertIn("exit 4", text)
        self.assertIn("PACKAGE_LOCK held", text)
        gate = text.find('TONGDAO_INSTALL')
        install = text.find('install -r')
        self.assertGreater(install, gate)
        self.assertNotIn("hdc_singleton.py acquire", text)

    def test_r1_build_holds_flock_and_defaults_to_skip_install(self) -> None:
        text = (ROOT / "scripts/r1-build.sh").read_text(encoding="utf-8")
        self.assertIn("wait-acquired", text)
        self.assertIn('hdc_singleton.py" hold', text)
        self.assertNotIn("hdc_singleton.py acquire", text)
        self.assertNotIn('hdc_singleton.py" acquire', text)
        self.assertIn("TONGDAO_INSTALL", text)
        force = text.find('TONGDAO_INSTALL:-0')
        skip = text.find("SKIP_INSTALL=1")
        install = text.find("install -r")
        self.assertGreater(skip, force)
        self.assertGreater(install, skip)


class SubprocessSingletonTest(unittest.TestCase):
    def test_two_processes_only_one_bringup_marker(self) -> None:
        helper = ROOT / "scripts/lib/hdc_singleton.py"
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "w.lock"
            marker = Path(raw) / "bringup.count"
            script = Path(raw) / "waiter.sh"
            script.write_text(
                "#!/bin/zsh\n"
                "set -u\n"
                f"LOCK={lock}\n"
                f"MARK={marker}\n"
                f"PY={helper}\n"
                "python3 \"$PY\" hold \"$LOCK\" $$ >\"$LOCK.out\" 2>&1 &\n"
                "HP=$!\n"
                "python3 \"$PY\" wait-acquired \"$LOCK.out\" \"$HP\" || exit 3\n"
                "print -r -- $$ >> \"$MARK\"\n"
                "sleep 2\n"
                "kill $HP 2>/dev/null\n"
            )
            env = os.environ.copy()
            p1 = subprocess.Popen(["zsh", str(script)], env=env)
            time.sleep(0.3)
            p2 = subprocess.run(["zsh", str(script)], env=env, capture_output=True, timeout=5)
            p1.wait(timeout=5)
            self.assertEqual(p2.returncode, 3)
            lines = marker.read_text().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertEqual(p1.returncode, 0)

    def test_cli_acquire_is_refused(self) -> None:
        helper = ROOT / "scripts/lib/hdc_singleton.py"
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "a.lock"
            proc = subprocess.run(
                [sys.executable, str(helper), "acquire", str(lock), "1"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(proc.returncode, 2)
            self.assertIn("use hold", proc.stderr)
            self.assertFalse(lock.exists())

    def test_wait_acquired_sees_hold_output(self) -> None:
        helper = ROOT / "scripts/lib/hdc_singleton.py"
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "w.lock"
            out = Path(raw) / "w.out"
            with out.open("w") as fh:
                hold = subprocess.Popen(
                    [sys.executable, str(helper), "hold", str(lock), "1"],
                    stdout=fh,
                    stderr=subprocess.STDOUT,
                )
                try:
                    wait = subprocess.run(
                        [sys.executable, str(helper), "wait-acquired", str(out), str(hold.pid)],
                        capture_output=True,
                        text=True,
                        timeout=8,
                    )
                    self.assertEqual(wait.returncode, 0, wait.stderr + wait.stdout + out.read_text(errors="replace"))
                finally:
                    hold.terminate()
                    hold.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
