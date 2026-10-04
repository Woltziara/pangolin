"""Narrow Stage-1 closed loop consumers: one request, one rule, one new response."""
from __future__ import annotations

import re
import time
import uuid

from lib.extprobe import HdcError, WindowEvidence, classify_window, evaluate_window

SERIAL = "TEST_DEVICE_SERIAL"
EXPECT_MODEL = "ALT-AL10"


def unique_x5(targets: str, serial: str = SERIAL, model: str = "") -> None:
    live = [
        ln.strip()
        for ln in targets.replace("\r", "").splitlines()
        if ln.strip() and "Empty" not in ln and "Fail" not in ln
    ]
    if len(live) != 1 or live[0] != serial:
        raise HdcError(["x5"], 2, f"hdc_targets_not_unique_x5 [{targets.strip()}]")
    if model and model.replace(" ", "") != EXPECT_MODEL:
        raise HdcError(["x5"], 2, f"not_x5 model={model}")


def parse_http_status_line(raw: str) -> tuple[int, str]:
    for line in (raw or "").splitlines():
        match = re.match(r"HTTP/[0-9.]+ (\d{3})\b", line.strip())
        if match:
            return int(match.group(1)), "http-status-line"
    return 0, "not-http"


def new_rid(kind: str) -> str:
    return f"{kind}{int(time.time())}-{uuid.uuid4().hex[:8]}"


def one_request(
    *,
    rid: str,
    purpose: str,
    generation_before: str,
    generation_after: str,
    revision_before: int,
    revision_after: int,
    tun_rx_before: int,
    tun_rx_after: int,
    tun_tx_before: int,
    tun_tx_after: int,
    hev_up_before: int,
    hev_up_after: int,
    hev_down_before: int,
    hev_down_after: int,
    access_window: str,
    http_status: int = 0,
    http_source: str = "",
    dump_has_rid: bool = False,
    page_ok: bool = False,
    browser_pid: str = "",
    tongdao_pid: str = "",
    browser_uid: str = "",
    tongdao_uid: str = "",
    observed_browser_bundle: str = "",
    production_rid: str = "",
    dns_query_sent: bool = False,
    udp_transport: str = "",
    probe_actor: str = "",
    udp_recv: bool = False,
    udp_txid_ok: bool = False,
    commit_kind: str = "",
    status_phase: str = "",
    last_proven_rid: str = "",
    consumed: bool = False,
    evidence_rid: str = "",
    consumed_rid: str = "",
    consumed_generation: str = "",
    consumed_revision: int = 0,
    consumed_access_offset: int = 0,
    consumed_raw_cursor: int = 0,
    consumed_epoch: int = 0,
    consumed_at: int = 0,
    access_offset: int = 0,
    probe_revision: int = 0,
    dns_helper: bool = False,
    direct_http_status: int = 0,
) -> dict:
    if not rid:
        raise HdcError(["rid"], 2, "missing unique rid")
    tags = classify_window(access_window, rid)
    return evaluate_window(
        WindowEvidence(
            rid=rid,
            generation_before=generation_before,
            generation_after=generation_after,
            revision_before=revision_before,
            revision_after=revision_after,
            tun_rx_before=tun_rx_before,
            tun_rx_after=tun_rx_after,
            tun_tx_before=tun_tx_before,
            tun_tx_after=tun_tx_after,
            hev_up_before=hev_up_before,
            hev_up_after=hev_up_after,
            hev_down_before=hev_down_before,
            hev_down_after=hev_down_after,
            tags=tags,
            google_http_status=http_status,
            browser_http_source=http_source,
            dump_has_rid=dump_has_rid,
            google_page_ok=page_ok,
            page_content_ok=page_ok,
            direct_page_ok=page_ok,
            browser_pid=browser_pid,
            tongdao_pid=tongdao_pid,
            browser_uid=browser_uid,
            tongdao_uid=tongdao_uid,
            observed_browser_bundle=observed_browser_bundle,
            production_rid=production_rid,
            dns_query_sent=dns_query_sent,
            udp_transport=udp_transport,
            probe_actor=probe_actor,
            udp_recv=udp_recv,
            udp_txid_ok=udp_txid_ok,
            purpose=purpose,
            commit_kind=commit_kind,
            status_phase=status_phase,
            last_proven_rid=last_proven_rid,
            consumed=consumed,
            evidence_rid=evidence_rid or rid,
            consumed_rid=consumed_rid or rid,
            consumed_generation=consumed_generation or generation_after,
            consumed_revision=consumed_revision or revision_after,
            consumed_access_offset=consumed_access_offset,
            consumed_raw_cursor=consumed_raw_cursor,
            consumed_epoch=consumed_epoch,
            consumed_at=consumed_at,
            access_offset=access_offset,
            probe_revision=probe_revision or revision_after,
            dns_helper=dns_helper,
            direct_http_status=direct_http_status,
        )
    )
