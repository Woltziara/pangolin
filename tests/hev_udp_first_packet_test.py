"""Black-box the real PRETEND_UDP first-packet/goto-again contract."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HevUdpFirstPacketTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = os.environ.get("HEV_SOURCE_DIR")
        work = os.environ.get("HEV_WORK_DIR")
        cls.hev = Path(source) if source else Path(work or "") / "src"
        if not (cls.hev / "third-part/lwip/src/core/udp.c").is_file():
            raise unittest.SkipTest(
                "set HEV_SOURCE_DIR or HEV_WORK_DIR to the actually patched "
                "HEV checkout"
            )

    def test_real_lwip_first_packet_contract(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if not compiler:
            self.skipTest("host C compiler unavailable")
        tunnel_source = (self.hev / "src/hev-socks5-tunnel.c").read_text()
        helpers = re.search(
            r"static int\napp_flow_copy_address[\s\S]*?"
            r"(?=\nstatic int\ntask_io_yielder)",
            tunnel_source,
        )
        drop_helpers = re.search(
            r"static void\nudp_drop_handler[\s\S]*?"
            r"(?=\nstatic void\nudp_recv_handler)",
            tunnel_source,
        )
        self.assertIsNotNone(helpers)
        self.assertIsNotNone(drop_helpers)

        fixture = (
            ROOT / "tests/hev_udp_first_packet_fixture.c"
        ).read_text()
        fixture = fixture.replace("/* APP_FLOW_HELPERS */", helpers.group(0))
        fixture = fixture.replace(
            "/* UDP_DROP_HELPERS */", drop_helpers.group(0)
        )
        with tempfile.TemporaryDirectory(prefix="hev-udp-first-") as tmp:
            tmp = Path(tmp)
            lwip = tmp / "lwip"
            tasks = tmp / "hev-task-system"
            shutil.copytree(self.hev / "third-part/lwip", lwip)
            shutil.copytree(self.hev / "third-part/hev-task-system", tasks)
            subprocess.run(
                ["make", "-C", str(lwip), "clean"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            subprocess.run(
                ["make", "-C", str(tasks), "clean"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            jobs = str(min(os.cpu_count() or 2, 8))
            subprocess.run(
                ["make", "-C", str(lwip), f"-j{jobs}", "static"],
                stdout=subprocess.DEVNULL,
                check=True,
            )
            subprocess.run(
                ["make", "-C", str(tasks), f"-j{jobs}", "static"],
                stdout=subprocess.DEVNULL,
                check=True,
            )
            source = tmp / "fixture.c"
            executable = tmp / "fixture"
            source.write_text(fixture)
            subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    f"-I{lwip / 'src/include'}",
                    f"-I{lwip / 'src/ports/include'}",
                    f"-I{tasks / 'include'}",
                    f"-I{ROOT / 'native/patches'}",
                    str(source),
                    str(lwip / "bin/liblwip.a"),
                    str(tasks / "bin/libhev-task-system.a"),
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                check=True,
            )

            for family in ("4", "6"):
                for mode in ("new", "disabled", "drop"):
                    subprocess.run(
                        [str(executable), family, mode],
                        check=True,
                        timeout=5,
                    )
                old = subprocess.run(
                    [str(executable), family, "old"],
                    timeout=5,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(old.returncode, 42, old.stderr)
                self.assertIn("recreated the PCB three times", old.stdout)

    def test_production_udp_handler_uses_first_callback_fields(self):
        source = (self.hev / "src/hev-socks5-tunnel.c").read_text()
        handler = re.search(
            r"static void\nudp_recv_handler \(void \*arg,[\s\S]*?"
            r"(?=\nstatic void\nevent_task_entry)",
            source,
        )
        self.assertIsNotNone(handler)
        self.assertRegex(
            handler.group(0),
            r"app_flow_tuple_init \(&tuple, 17, &pcb->remote_ip,"
            r"\s*pcb->remote_port, addr, port\)",
        )
        self.assertNotIn("hev_object_unref (HEV_OBJECT (udp))", handler.group(0))
        self.assertLess(
            handler.group(0).index("task = hev_task_new"),
            handler.group(0).index("udp = hev_socks5_session_udp_new"),
        )
        tcp = re.search(
            r"static err_t\ntcp_accept_handler[\s\S]*?"
            r"(?=\nstatic void\ndns_recv_handler)",
            source,
        )
        self.assertIsNotNone(tcp)
        self.assertNotIn("hev_object_unref (HEV_OBJECT (tcp))", tcp.group(0))
        self.assertLess(
            tcp.group(0).index("task = hev_task_new"),
            tcp.group(0).index("tcp = hev_socks5_session_tcp_new"),
        )


if __name__ == "__main__":
    unittest.main()
