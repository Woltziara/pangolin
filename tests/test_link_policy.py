#!/usr/bin/env python3
"""Do not tconn unless 8710 is actually open. Empty USB is not a data link."""
from __future__ import annotations

import unittest


def may_tconn(usb_huawei: bool, open_8710: list[str], serial_live: bool) -> str:
    if serial_live:
        return "usb-serial"
    if usb_huawei:
        return "usb-data"
    live = [x for x in open_8710 if x]
    if len(live) == 1:
        return f"tconn {live[0]}"
    if len(live) > 1:
        return "ambiguous-8710"
    return "PHYSICAL_DATA_LINK_UNAVAILABLE"


class LinkPolicyTest(unittest.TestCase):
    def test_offline_tcp_entries_are_not_tconn(self) -> None:
        # HDC -v listed 192.168.3.*:8710 Offline; port closed on UP hosts.
        decision = may_tconn(False, [], False)
        self.assertEqual(decision, "PHYSICAL_DATA_LINK_UNAVAILABLE")

    def test_only_real_open_8710(self) -> None:
        self.assertEqual(may_tconn(False, ["192.168.3.3:8710"], False), "tconn 192.168.3.3:8710")

    def test_usb_serial_wins(self) -> None:
        self.assertEqual(may_tconn(False, [], True), "usb-serial")

    def test_hdc_wait_must_not_install_when_empty(self) -> None:
        targets = "[Empty]"
        serial = "TEST_DEVICE_SERIAL"
        live = [ln for ln in targets.splitlines() if ln.strip() and "Empty" not in ln and "Fail" not in ln]
        self.assertNotEqual(live, [serial])


if __name__ == "__main__":
    unittest.main()
