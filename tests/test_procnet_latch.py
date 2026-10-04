"""ProcNet /proc/net/dev EACCES latch contracts (HarmonyOS 7 sandbox).

On HarmonyOS 7 the app sandbox denies file_api reads of /proc/net/dev
(EACCES, file_api ret -13). The first permission failure must latch for the
process lifetime so the 15s supervisor loop stops logging EACCES twice per
cycle; counters keep flowing through the native getNativeStats fallback in
TunnelVpnAbility.mergeTunCounters.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROCNET = ROOT / "entry/src/main/ets/net/ProcNet.ets"
VPN = ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_latch_flag_declared():
    src = read(PROCNET)
    assert "procNetDenied" in src
    assert re.search(r"let procNetDenied: boolean = false", src)


def test_latch_short_circuits_before_read():
    src = read(PROCNET)
    fn = src[src.index("readVpnTunCounters(): TunCounters"):]
    early = fn.index("if (procNetDenied)")
    read_idx = fn.index("fs.readTextSync")
    assert early < read_idx, "latch must return before touching /proc/net/dev"


def test_latch_only_on_permission_error():
    src = read(PROCNET)
    assert "13900001" in src and "13900012" in src
    assert "isPermissionDenied(error)" in src


def test_latch_logs_once_with_reason():
    src = read(PROCNET)
    assert "hilog.info" in src
    assert "HarmonyOS 7" in src


def test_native_fallback_still_wired():
    src = read(VPN)
    assert "readVpnTunCounters()" in src
    assert "getNativeStats()" in src
