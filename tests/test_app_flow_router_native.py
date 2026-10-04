#!/usr/bin/env python3
"""Compile and execute app_flow_router.cpp against a host-only N-API stub."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AppFlowRouterNativeTest(unittest.TestCase):
    def test_request_lifecycle_and_late_callback_isolation(self) -> None:
        cxx = shutil.which("clang++") or shutil.which("g++")
        if not cxx:
            self.skipTest("host C++ compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="app-flow-router-") as temp:
            executable = Path(temp) / "app-flow-router-native-test"
            subprocess.run([
                cxx, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "tests/stubs"),
                str(ROOT / "tests/app_flow_router_native_test.cpp"),
                "-o", str(executable),
            ], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
