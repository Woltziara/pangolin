"""Offline allocation lifecycle test against the pinned real lwIP library.
No sockets, incoming packets, network devices, or network traffic are used.
The baseline must fail before a second pool initialization can reuse live owners.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HevTcpRestartTest(unittest.TestCase):
    def test_offline_owners_are_released_before_restart(self):
        source = os.environ.get("HEV_SOURCE_DIR")
        work = os.environ.get("HEV_WORK_DIR")
        hev = Path(source) if source else Path(work or "") / "src"
        if not (hev / "third-part/lwip/src/core/tcp.c").is_file():
            self.skipTest("set HEV_SOURCE_DIR to the actual HEV checkout")
        compiler = shutil.which("clang") or shutil.which("cc")
        if not compiler:
            self.skipTest("host C compiler unavailable")
        tunnel = (hev / "src/hev-socks5-tunnel.c").read_text()
        shutdown = re.search(
            r"static void\ngateway_fini \(void\)[\s\S]*?(?=\nstatic int\nevent_task_init)",
            tunnel,
        )
        self.assertIsNotNone(shutdown)
        fixture = (ROOT / "tests/hev_tcp_restart_fixture.c").read_text().replace(
            "/* PRODUCTION_GATEWAY_FINI */", shutdown.group(0)
        )
        with tempfile.TemporaryDirectory(prefix="hev-tcp-restart-") as path:
            tmp = Path(path)
            lwip = tmp / "lwip"
            tasks = tmp / "hev-task-system"
            shutil.copytree(hev / "third-part/lwip", lwip)
            shutil.copytree(hev / "third-part/hev-task-system", tasks)
            for dependency in (lwip, tasks):
                subprocess.run(["make", "-C", str(dependency), "clean"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["make", "-C", str(dependency),
                                f"-j{min(os.cpu_count() or 2, 8)}", "static"],
                               stdout=subprocess.DEVNULL, check=True)
            code = tmp / "fixture.c"
            binary = tmp / "fixture"
            code.write_text(fixture)
            subprocess.run([
                compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                f"-I{lwip / 'src/include'}", f"-I{lwip / 'src/ports/include'}",
                f"-I{tasks / 'include'}", str(code),
                str(lwip / "bin/liblwip.a"),
                str(tasks / "bin/libhev-task-system.a"), "-lpthread", "-o", str(binary),
            ], check=True)
            for family in ("4", "6"):
                for state in ("syn-received", "time-wait", "bound"):
                    with self.subTest(family=family, state=state):
                        result = subprocess.run([str(binary), family, state],
                                                capture_output=True, text=True, timeout=5)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("32 offline TCP", result.stdout)


if __name__ == "__main__":
    unittest.main()
