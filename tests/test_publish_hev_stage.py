#!/usr/bin/env python3
"""Host-only identity and rollback tests for the staged HEV publisher."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("publish_hev_stage", ROOT / "scripts" / "publish_hev_stage.py")
assert spec and spec.loader
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PublishHevStageTest(unittest.TestCase):
    def make_fixture(self) -> tuple[Path, Path, Path, Path]:
        root = Path(tempfile.mkdtemp(prefix="publish-hev-root-"))
        work = root / "work"
        staged = work / "stage" / "libhevsocks5tun.so"
        staged.parent.mkdir(parents=True)
        staged.write_bytes(b"new-measured-hev")
        destination = root / "entry/src/main/cpp/prebuilt/arm64-v8a/libhevsocks5tun.so"
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b"old-locked-hev")
        patch_dir = root / "native/patches"
        patch_dir.mkdir(parents=True)
        (patch_dir / "hev-app-routing.patch").write_text("routing patch\n")
        (patch_dir / "app-flow-route.h").write_text("abi header\n")
        (patch_dir / "hev-required.patch").write_text("required patch\n")
        lock = {
            "note": "old note",
            "hev": {"commit": "abc123", "artifact": str(destination.relative_to(root)), "sha256": "old", "packedSha256": "old-packed", "diagnostic": "diag-v1"},
            "patches": ["native/patches/hev-required.patch"],
        }
        lock_path = root / "native/CORE_LOCK.json"
        lock_path.write_text(json.dumps(lock, indent=2) + "\n")
        receipts = {
            "measured-hev-commit.txt": "abc123ffffffff\n",
            "measured-hev-diagnostic-kind.txt": "diag-v1\n",
            "measured-hev-app-routing-patch-sha256.txt": digest(patch_dir / "hev-app-routing.patch") + "\n",
            "measured-hev-app-flow-header-sha256.txt": digest(patch_dir / "app-flow-route.h") + "\n",
            "measured-hev-staged-so-sha256.txt": digest(staged) + "\n",
            "measured-hev-patches.json": json.dumps({
                "native/patches/hev-required.patch": digest(patch_dir / "hev-required.patch"),
                "native/patches/hev-app-routing.patch": digest(patch_dir / "hev-app-routing.patch"),
                "native/patches/app-flow-route.h": digest(patch_dir / "app-flow-route.h"),
            }),
        }
        for name, value in receipts.items():
            (work / name).write_text(value)
        return root, work, destination, lock_path

    def run_publish(self, root: Path, work: Path, *, exports: str | None = None, packed=None) -> None:
        good_exports = "\n".join(f"0000 T {name}" for name in (
            "hev_socks5_tunnel_main_from_str", "hev_socks5_tunnel_quit",
            "hev_socks5_tunnel_stats", "hev_socks5_tunnel_set_app_route_callbacks",
        ))
        with patch.dict(os.environ, {"TONGDAO_R1_PUBLISH": "1"}, clear=False), \
             patch.object(publisher.subprocess, "check_output", return_value=exports if exports is not None else good_exports), \
             patch.object(publisher, "expected_packed_sha256", packed or (lambda path, _strip: digest(path))):
            publisher.publish(root, work)

    def assert_unchanged(self, dest: Path, lock_path: Path, old_dest: bytes, old_lock: str) -> None:
        self.assertEqual(dest.read_bytes(), old_dest)
        self.assertEqual(lock_path.read_text(), old_lock)

    def test_publishes_only_matching_stage_and_records_identity(self) -> None:
        root, work, dest, lock_path = self.make_fixture()
        self.run_publish(root, work)
        lock = json.loads(lock_path.read_text())
        self.assertEqual(dest.read_bytes(), (work / "stage/libhevsocks5tun.so").read_bytes())
        self.assertEqual(lock["hev"]["sha256"], digest(dest))
        self.assertEqual(lock["hev"]["packedSha256"], digest(dest))
        self.assertEqual(lock["hev"]["appRouting"], "per-session-uid-v1")
        self.assertTrue((root / ".runtime/r1-manifests/hev-identity.json").is_file())

    def test_wrong_identity_receipts_and_abi_are_rejected_before_publish(self) -> None:
        cases = {
            "commit": ("measured-hev-commit.txt", "wrong-commit\n"),
            "patch": ("measured-hev-app-routing-patch-sha256.txt", "00\n"),
            "header": ("measured-hev-app-flow-header-sha256.txt", "00\n"),
            "stage-sha": ("measured-hev-staged-so-sha256.txt", "00\n"),
            "patch-map": ("measured-hev-patches.json", "{}"),
        }
        for name, (receipt, value) in cases.items():
            with self.subTest(name=name):
                root, work, dest, lock_path = self.make_fixture()
                old_dest, old_lock = dest.read_bytes(), lock_path.read_text()
                (work / receipt).write_text(value)
                with self.assertRaises(RuntimeError):
                    self.run_publish(root, work)
                self.assert_unchanged(dest, lock_path, old_dest, old_lock)
        root, work, dest, lock_path = self.make_fixture()
        old_dest, old_lock = dest.read_bytes(), lock_path.read_text()
        with self.assertRaises(RuntimeError):
            self.run_publish(root, work, exports="0000 T hev_socks5_tunnel_quit")
        self.assert_unchanged(dest, lock_path, old_dest, old_lock)

    def test_post_copy_verification_failure_rolls_back_raw_and_lock(self) -> None:
        root, work, dest, lock_path = self.make_fixture()
        old_dest, old_lock = dest.read_bytes(), lock_path.read_text()
        staged = work / "stage/libhevsocks5tun.so"

        def mismatched_on_destination(path: Path, _strip: Path) -> str:
            return digest(path) if path == staged else "not-the-published-packed-hash"

        with self.assertRaises(RuntimeError):
            self.run_publish(root, work, packed=mismatched_on_destination)
        self.assert_unchanged(dest, lock_path, old_dest, old_lock)


if __name__ == "__main__":
    unittest.main()
