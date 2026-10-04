"""Rolling freshness bound to a controlled probe RID.

CANARY_OK is Harmony-native HTTP 204 + access tags (googleProxy, direct, udp),
or the older bidirectional TUN/HEV increment bound to a RID.
TUN/HEV counters must not veto a proven 204+access window.
Unidirectional growth or background noise without a RID cannot promote.
"""
from __future__ import annotations

from dataclasses import dataclass

PHASE_CANARY_OK = "CANARY_OK"
PHASE_UNPROVEN = "UNPROVEN"
PHASE_DEGRADED_UNPROVEN = "DEGRADED_UNPROVEN"
PHASE_FORWARDER_RUNNING = "FORWARDER_RUNNING"
PHASE_DEGRADED = "DEGRADED"
PHASE_RECONNECTING = "RECONNECTING"
PHASE_ERROR = "ERROR"
PHASE_STOPPED = "STOPPED"

BROWSER_BUNDLE = "com.huawei.hmos.browser"


@dataclass
class PlaneSnapshot:
    generation: str
    session_id: str
    session_revision: int
    tun_fd_valid: bool
    xray_running: bool = True
    tun_running: bool = True
    tun_rx: int = 0
    tun_tx: int = 0
    hev_up: int = 0
    hev_down: int = 0
    last_tun_rx: int = 0
    last_tun_tx: int = 0
    last_hev_up: int = 0
    last_hev_down: int = 0
    bound_rid: str = ""
    access_offset: int = -1
    access_proxy: bool = False
    access_direct: bool = False
    access_udp: bool = False
    socks_direct_ok: bool = False
    socks_proxy_ok: bool = False
    fetch_google_http: int = 0
    fetch_direct_http: int = 0
    fetch_dns_ok: bool = False
    evidence_at: int = 0
    now_ms: int = 0
    ever_proven: bool = False
    # Compat aliases used by older fixtures.
    tun_bytes: int = -1
    hev_bytes: int = -1
    last_tun_bytes: int = -1
    last_hev_bytes: int = -1
    base_tun_bytes: int = -1
    base_hev_bytes: int = -1

    def __post_init__(self) -> None:
        if self.tun_bytes >= 0:
            self.tun_rx = max(self.tun_rx, self.tun_bytes)
        if self.hev_bytes >= 0:
            self.hev_up = max(self.hev_up, self.hev_bytes)
        if self.last_tun_bytes >= 0:
            self.last_tun_rx = self.last_tun_bytes
        if self.last_hev_bytes >= 0:
            self.last_hev_up = self.last_hev_bytes
        if self.base_tun_bytes >= 0:
            self.last_tun_rx = self.base_tun_bytes
        if self.base_hev_bytes >= 0:
            self.last_hev_up = self.base_hev_bytes


def socks_canary_ok(snap: PlaneSnapshot) -> bool:
    return snap.socks_direct_ok and snap.socks_proxy_ok


def has_fresh_plane_evidence(snap: PlaneSnapshot) -> bool:
    if not snap.generation or snap.generation != snap.session_id:
        return False
    if snap.session_revision < 1:
        return False
    if not snap.tun_fd_valid:
        return False
    if not snap.bound_rid or snap.access_offset < 0:
        return False
    tags_ok = bool(snap.access_proxy and snap.access_direct and snap.access_udp)
    fetch_ok = (
        snap.fetch_google_http == 204
        and 200 <= snap.fetch_direct_http < 400
        and snap.fetch_dns_ok
    )
    if fetch_ok and tags_ok:
        return True
    if snap.tun_rx <= snap.last_tun_rx or snap.tun_tx <= snap.last_tun_tx:
        return False
    if snap.hev_up <= snap.last_hev_up or snap.hev_down <= snap.last_hev_down:
        return False
    if not tags_ok:
        return False
    return True


def phase_from_evidence(snap: PlaneSnapshot, current_phase: str) -> str:
    if current_phase in (PHASE_RECONNECTING, PHASE_ERROR, PHASE_STOPPED):
        return current_phase
    if has_fresh_plane_evidence(snap):
        return PHASE_CANARY_OK
    if snap.ever_proven or current_phase in (PHASE_CANARY_OK, PHASE_DEGRADED_UNPROVEN):
        return PHASE_DEGRADED_UNPROVEN
    if current_phase in (PHASE_FORWARDER_RUNNING, PHASE_UNPROVEN, PHASE_DEGRADED, ""):
        return PHASE_UNPROVEN
    return current_phase


def advance_sample(snap: PlaneSnapshot, now_ms: int | None = None) -> None:
    snap.last_tun_rx = snap.tun_rx
    snap.last_tun_tx = snap.tun_tx
    snap.last_hev_up = snap.hev_up
    snap.last_hev_down = snap.hev_down
    snap.ever_proven = True
    snap.evidence_at = int(now_ms if now_ms is not None else snap.now_ms)
