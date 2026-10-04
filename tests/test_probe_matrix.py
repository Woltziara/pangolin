#!/usr/bin/env python3
"""Classifier for browser-UID probes. Not a ProbeApp HAP."""
from __future__ import annotations

import unittest

GOOGLE_MARKERS = ("google", "gstatic", "142.251", "172.217", "216.58", "2607:f8b0", "2001:4860")
DIRECT_MARKERS = ("qq.com", "gtimg", "bilibili", "hdslb.com", "192.168.3.", "10.7.0.")
BAIDU_CANARY = ("baidu.com", "103.235.", "180.76.", "220.181.")


def classify(window: str) -> dict[str, bool]:
    google = unique = udp = False
    for line in window.splitlines():
        low = line.lower()
        if "tun-in -> proxy" in line:
            if any(m in low for m in GOOGLE_MARKERS):
                google = True
            if ":53 [tun-in -> proxy]" in line:
                udp = True
        if "tun-in -> dns-out" in line and ":53 [tun-in -> dns-out]" in line:
            udp = True
        if "tun-in -> direct" in line and any(m in low for m in DIRECT_MARKERS):
            unique = True
    return {"googleProxy": google, "uniqueDirect": unique, "udp53Proxy": udp}


class ProbeMatrixTest(unittest.TestCase):
    def test_not_probeapp_hap(self) -> None:
        meta = {
            "isProbeAppHap": False,
            "reason": "tongdao CBG p7b cannot sign another bundle; hdc ELF is noexec",
            "isolatedClient": "com.huawei.hmos.browser",
        }
        self.assertFalse(meta["isProbeAppHap"])
        self.assertEqual(meta["isolatedClient"], "com.huawei.hmos.browser")

    def test_direct_proxy_udp_window(self) -> None:
        window = "\n".join(
            [
                "12:07:02 tcp:www.wikipedia.org:80 [tun-in -> proxy]",
                "12:07:02 udp:1.1.1.1:53 [tun-in -> proxy]",
                "12:07:03 tcp:www.qq.com:443 [tun-in -> direct]",
                "12:07:03 tcp:[2001:4860:482b::]:443 [tun-in -> proxy]",
            ]
        )
        tags = classify(window)
        self.assertTrue(tags["googleProxy"])
        self.assertTrue(tags["uniqueDirect"])
        self.assertTrue(tags["udp53Proxy"])

    def test_dns_out_port_53_is_udp53(self) -> None:
        window = "accepted udp:192.168.3.1:53 [tun-in -> dns-out]\n"
        tags = classify(window)
        self.assertTrue(tags["udp53Proxy"])

    def test_wikipedia_canary_is_not_google_pass(self) -> None:
        window = "12:07:02 tcp:www.wikipedia.org:80 [tun-in -> proxy]\n"
        tags = classify(window)
        self.assertFalse(tags["googleProxy"])

    def test_baidu_canary_is_not_unique_direct(self) -> None:
        window = "12:07:02 tcp:www.baidu.com:80 [tun-in -> direct]\n"
        tags = classify(window)
        self.assertFalse(tags["uniqueDirect"])

    def test_page_no_error_without_tag_is_fail(self) -> None:
        tags = classify("")
        page_error = False
        ok = (not page_error) and tags["googleProxy"]
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
