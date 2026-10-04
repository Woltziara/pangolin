#!/usr/bin/env python3
"""Narrow Stage-1 closed loop. Host consumers only; does not install or touch VPN."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.extprobe import HdcError  # noqa: E402
from lib.stage1_loop import one_request, parse_http_status_line, unique_x5  # noqa: E402

BROWSER = "com.huawei.hmos.browser"


def _google_kwargs(**extra: object) -> dict:
    base: dict = dict(
        rid="g1",
        purpose="browser_google",
        generation_before="g",
        generation_after="g",
        revision_before=1,
        revision_after=1,
        tun_rx_before=0,
        tun_rx_after=10,
        tun_tx_before=0,
        tun_tx_after=10,
        hev_up_before=0,
        hev_up_after=10,
        hev_down_before=0,
        hev_down_after=10,
        access_window="accepted tcp:www.google.com:443 [tun-in -> proxy]\n",
        dump_has_rid=False,
        page_ok=False,
        browser_pid="2",
        tongdao_pid="3",
        browser_uid="2",
        tongdao_uid="3",
        observed_browser_bundle=BROWSER,
        production_rid="prod",
        access_offset=0,
    )
    base.update(extra)
    return base


def host_check() -> dict:
    unique_x5("TEST_DEVICE_SERIAL\n", serial="TEST_DEVICE_SERIAL", model="ALT-AL10")
    code, src = parse_http_status_line("HTTP/1.1 204 No Content\n")
    if code != 204 or src != "http-status-line":
        raise HdcError(["host"], 2, "http status line parser failed")
    dump = one_request(**_google_kwargs(http_status=204, http_source="uitest-dump"))
    if dump.get("ok"):
        raise HdcError(["host"], 2, "dump text must not pass as HTTP")
    ok = one_request(
        **_google_kwargs(http_status=204, http_source="http-status-line", dump_has_rid=False, page_ok=False)
    )
    if not ok.get("ok"):
        raise HdcError(["host"], 2, f"http-status-line google rejected {ok}")
    not_http = one_request(
        **_google_kwargs(http_status=0, http_source="not-http", dump_has_rid=False, page_ok=False)
    )
    if not_http.get("ok") or not_http.get("reason") != "google_http_not_from_http":
        raise HdcError(["host"], 2, f"not-http google must not pass {not_http}")
    cn_ip = one_request(
        rid="d1",
        purpose="browser_direct",
        generation_before="g",
        generation_after="g",
        revision_before=1,
        revision_after=1,
        tun_rx_before=0,
        tun_rx_after=10,
        tun_tx_before=0,
        tun_tx_after=10,
        hev_up_before=0,
        hev_up_after=10,
        hev_down_before=0,
        hev_down_after=10,
        access_window="accepted tcp:101.91.22.57:443 [tun-in -> direct]\n",
        browser_pid="2",
        tongdao_pid="3",
        browser_uid="2",
        tongdao_uid="3",
        observed_browser_bundle=BROWSER,
        production_rid="prod",
        access_offset=0,
    )
    if not cn_ip.get("ok"):
        raise HdcError(["host"], 2, f"cn-ip direct rejected {cn_ip}")
    udp = one_request(
        rid="u1",
        purpose="browser_udp",
        generation_before="g",
        generation_after="g",
        revision_before=1,
        revision_after=1,
        tun_rx_before=0,
        tun_rx_after=10,
        tun_tx_before=0,
        tun_tx_after=10,
        hev_up_before=0,
        hev_up_after=10,
        hev_down_before=0,
        hev_down_after=10,
        access_window="accepted udp:1.1.1.1:53 [tun-in -> dns-out]\n",
        browser_pid="2",
        tongdao_pid="3",
        browser_uid="2",
        tongdao_uid="3",
        observed_browser_bundle=BROWSER,
        production_rid="prod",
        dns_query_sent=True,
        udp_recv=True,
        udp_txid_ok=True,
        access_offset=0,
    )
    if not udp.get("ok"):
        raise HdcError(["host"], 2, f"browser udp rejected {udp}")
    switched = one_request(
        **_google_kwargs(
            generation_before="old",
            generation_after="new",
            http_status=204,
            http_source="http-status-line",
        )
    )
    if switched.get("ok") or switched.get("reason") != "generation_mismatch":
        raise HdcError(["host"], 2, f"generation change not rejected {switched}")
    return {
        "ok": True,
        "role": "narrow-loop-host",
        "dumpRejected": dump.get("reason"),
        "googleOk": True,
        "genChangeRejected": switched.get("reason"),
        "note": "Host consumers only. Does not install or touch a phone.",
    }


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("--device", "--phone"):
        print(
            json.dumps(
                {
                    "ok": False,
                    "reason": "device_run_gated",
                    "note": "真机写入未授权；只做主机检查。",
                }
            )
        )
        return 2
    try:
        rec = host_check()
    except HdcError as exc:
        print(json.dumps({"ok": False, "reason": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(rec, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
