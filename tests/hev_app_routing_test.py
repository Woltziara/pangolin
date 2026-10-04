"""Exercise the actual HEV app-routing resolver patched into 2.17.1."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HevAppRoutingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = os.environ.get("HEV_WORK_DIR")
        source = os.environ.get("HEV_SOURCE_DIR")
        cls.source = Path(source) if source else Path(work or "") / "src"
        if not (cls.source / "src/hev-socks5-session.c").is_file():
            raise unittest.SkipTest(
                "set HEV_WORK_DIR to a checkout prepared by build_hev_ohos.sh "
                "or HEV_SOURCE_DIR to an actually patched HEV checkout"
            )

    def test_production_resolver_with_async_fd_replies(self):
        session_source = (
            self.source / "src/hev-socks5-session.c"
        ).read_text()
        io_source = (
            self.source
            / "third-part/hev-task-system/src/lib/io/basic/hev-task-io.c"
        ).read_text()
        route = re.search(
            r"#define APP_ROUTE_TIMEOUT_MS[\s\S]*?(?=\nvoid\n"
            r"hev_socks5_session_run)",
            session_source,
        )
        io_read = re.search(
            r"EXPORT_SYMBOL ssize_t\nhev_task_io_read \([\s\S]*?"
            r"(?=\nEXPORT_SYMBOL ssize_t\nhev_task_io_readv)",
            io_source,
        )
        self.assertIsNotNone(route)
        self.assertIsNotNone(io_read)

        fixture = (ROOT / "tests/hev_app_routing_fixture.c").read_text()
        fixture = fixture.replace("/* HEV_TASK_IO_READ */", io_read.group(0))
        fixture = fixture.replace("/* HEV_ROUTE_CODE */", route.group(0))
        compiler = shutil.which("clang") or shutil.which("cc")
        if not compiler:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="hev-app-route-test-") as tmp:
            source = Path(tmp) / "fixture.c"
            executable = Path(tmp) / "fixture"
            source.write_text(fixture)
            subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-pthread",
                    "-I",
                    str(ROOT / "native/patches"),
                    str(source),
                    "-o",
                    str(executable),
                ],
                check=True,
            )
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_tuple_capture_and_session_local_port_wiring(self):
        tunnel = (self.source / "src/hev-socks5-tunnel.c").read_text()
        session = (self.source / "src/hev-socks5-session.c").read_text()
        self.assertRegex(
            tunnel,
            r"app_flow_tuple_init \(&tuple, 6, &pcb->remote_ip, "
            r"pcb->remote_port,\s*&pcb->local_ip, pcb->local_port\)",
        )
        self.assertRegex(
            tunnel,
            r"app_flow_tuple_init \(&tuple, 17, &pcb->remote_ip,\s*"
            r"pcb->remote_port, addr, port\)",
        )
        self.assertIn("memcpy (output, &ip_2_ip4 (address)->addr, 4)", tunnel)
        self.assertIn("memcpy (output, ip_2_ip6 (address)->addr, 16)", tunnel)
        self.assertRegex(
            session,
            r"hev_socks5_client_connect [\s\S]*?"
            r"hev_socks5_session_get_socks_port "
            r"\(\s*self, srv->port\)",
        )
        self.assertIn(
            "hev_socks5_tunnel_set_app_route_callbacks (NULL, NULL, NULL)",
            (self.source / "src/hev-main.c").read_text(),
        )


if __name__ == "__main__":
    unittest.main()
