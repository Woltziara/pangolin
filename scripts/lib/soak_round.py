"""Fail-closed soak round checker. Host must not reuse stale JSON as CANARY_OK."""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any


class SoakFail(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def parse_targets(text: str, serial: str) -> None:
    live = [
        ln.strip()
        for ln in text.replace("\r", "").splitlines()
        if ln.strip() and "Empty" not in ln and "Fail" not in ln
    ]
    if len(live) != 1 or live[0] != serial:
        raise SoakFail(f"hdc_targets_not_unique_x5 [{text.strip()}]")


def check_model(model: str) -> None:
    if model.replace(" ", "") != "ALT-AL10":
        raise SoakFail(f"not_x5 model={model}")


def check_status_file(
    path: Path,
    want_gen: str,
    last_at: int,
    now_ms: int | None = None,
    max_age_ms: int = 120000,
) -> dict[str, Any]:
    if not path.is_file() or path.stat().st_size < 8:
        raise SoakFail("status_file_empty")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SoakFail(f"parse {exc}") from exc
    at = data.get("at") or 0
    if not isinstance(at, (int, float)) or at < 1:
        raise SoakFail("missing_at")
    now = int(time.time() * 1000) if now_ms is None else int(now_ms)
    age = now - int(at)
    if age > max_age_ms:
        raise SoakFail(f"stale_at age_ms {age} at {at}")
    gen = str(data.get("generation") or "")
    if want_gen and gen != want_gen:
        raise SoakFail(f"generation_changed {gen} want {want_gen}")
    if last_at and int(at) < int(last_at):
        raise SoakFail(f"at_went_backwards {at} {last_at}")
    if data.get("phase") != "CANARY_OK":
        raise SoakFail(f"phase {data.get('phase')}")
    if not data.get("canaryOk") or not data.get("forwarderOk"):
        raise SoakFail(f"plane canaryOk {data.get('canaryOk')} fwd {data.get('forwarderOk')}")
    rev = int(data.get("sessionRevision") or 0)
    if rev < 1:
        raise SoakFail(f"sessionRevision {rev}")
    evidence_at = int(data.get("evidenceAt") or 0)
    if evidence_at < 1:
        raise SoakFail("missing_evidence_at")
    if now - evidence_at > max_age_ms:
        raise SoakFail(f"stale_evidence_at age_ms {now - evidence_at}")
    return data


def check_tun(tun: str) -> tuple[int, int]:
    if "vpn-tun" not in tun or re.search(r"\[Fail\]", tun):
        raise SoakFail(f"tun_unreadable {tun[:120]}")
    nums = [int(x) for x in re.findall(r"\d+", tun)]
    if len(nums) < 10:
        raise SoakFail(f"tun_counters {tun[:120]}")
    return nums[0], nums[8]


def check_clashbox(cb: str) -> None:
    if "clashbox-absent" not in cb or re.search(r"\[Fail\]", cb):
        raise SoakFail(f"clashbox {cb[:80]}")


def check_vpn_pid(vpn: str) -> None:
    if not vpn or re.search(r"\[Fail\]", vpn):
        raise SoakFail(f"vpn_pid {vpn[:80]}")


def check_event_seq(last_seq: int, seq: int) -> None:
    """Without JSONL, only exact +1 is continuous. Jumps cannot fake a pass."""
    if last_seq > 0 and seq <= last_seq:
        raise SoakFail(f"event_seq_gap_or_rewind last={last_seq} now={seq}")
    if last_seq > 0 and seq != last_seq + 1:
        raise SoakFail(
            f"event_seq_jump last={last_seq} now={seq} (jsonl required to prove continuity)"
        )
    if last_seq == 0 and seq < 1:
        raise SoakFail(f"event_seq_missing now={seq}")


def check_event_snapshot(
    *,
    snapshot_path: Path,
    last_seq: int,
    want_gen: str,
    want_rev: int | None,
    recv_rc: int,
) -> int:
    if recv_rc != 0:
        raise SoakFail(f"event_snapshot_recv_rc {recv_rc}")
    if not snapshot_path.is_file() or snapshot_path.stat().st_size < 8:
        raise SoakFail("event_snapshot_empty")
    from lib.event_store import EventGap, EventSnapshot

    try:
        snap = EventSnapshot.from_json(snapshot_path.read_text(encoding="utf-8"))
    except EventGap as exc:
        raise SoakFail(str(exc)) from exc
    if want_gen and snap.generation != want_gen:
        raise SoakFail(f"event_snapshot_generation {snap.generation} want {want_gen}")
    if want_rev is not None and snap.session_revision != int(want_rev):
        raise SoakFail(f"event_snapshot_revision {snap.session_revision} want {want_rev}")
    if last_seq > 0 and snap.seq <= last_seq:
        raise SoakFail(f"event_seq_not_advanced last={last_seq} now={snap.seq}")
    if snap.seq < 1:
        raise SoakFail("event_seq_missing")
    if last_seq > 0 and last_seq + 1 < snap.window_start_seq:
        raise SoakFail(
            f"event_window_gap last={last_seq} windowStartSeq={snap.window_start_seq}"
        )
    if snap.window_start_seq and snap.events:
        first = int(snap.events[0].get("seq") or 0)
        if first != snap.window_start_seq:
            raise SoakFail(f"event_windowStartSeq {snap.window_start_seq} != first {first}")
        prev = first - 1
        for rec in snap.events:
            seq = int(rec.get("seq") or 0)
            if seq != prev + 1:
                raise SoakFail(f"event_window_seq_gap {prev} -> {seq}")
            prev = seq
            rec_gen = str(rec.get("generation") or "")
            if want_gen and rec_gen and rec_gen != want_gen:
                raise SoakFail(f"event_window_generation {rec_gen} want {want_gen}")
            rec_rev = int(rec.get("sessionRevision") or 0)
            if rec_rev < 1:
                raise SoakFail("event_window_revision_missing")
            if int(rec.get("at") or 0) < 1 or not str(rec.get("phase") or ""):
                raise SoakFail("event_window_missing_at_or_phase")
        last_rev = int(snap.events[-1].get("sessionRevision") or 0)
        if want_rev is not None and last_rev != int(want_rev):
            raise SoakFail(f"event_window_last_revision {last_rev} want {want_rev}")
    return snap.seq


def check_event_chain(
    *,
    head_path: Path,
    jsonl_path: Path,
    last_seq: int,
    want_gen: str,
    want_rev: int | None,
    head_rc: int,
    jsonl_rc: int,
) -> int:
    if head_rc != 0:
        raise SoakFail(f"event_head_recv_rc {head_rc}")
    if jsonl_rc != 0:
        raise SoakFail(f"event_jsonl_recv_rc {jsonl_rc}")
    if not head_path.is_file() or head_path.stat().st_size < 8:
        raise SoakFail("event_head_empty")
    if not jsonl_path.is_file() or jsonl_path.stat().st_size < 2:
        raise SoakFail("event_jsonl_empty")
    try:
        head = json.loads(head_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SoakFail(f"event_head_parse {exc}") from exc
    gen = str(head.get("generation") or "")
    if want_gen and gen != want_gen:
        raise SoakFail(f"event_head_generation {gen} want {want_gen}")
    rev = int(head.get("sessionRevision") or 0)
    if want_rev is not None and rev != int(want_rev):
        raise SoakFail(f"event_head_revision {rev} want {want_rev}")
    seqs: list[int] = []
    for i, line in enumerate(jsonl_path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SoakFail(f"event_jsonl_parse line {i} {exc}") from exc
        if "seq" not in rec:
            raise SoakFail(f"event_jsonl_missing_seq line {i}")
        seqs.append(int(rec["seq"]))
        rec_gen = str(rec.get("generation") or "")
        if want_gen and rec_gen and rec_gen != want_gen:
            raise SoakFail(f"event_jsonl_generation {rec_gen} want {want_gen}")
    if not seqs:
        raise SoakFail("event_jsonl_empty_seq")
    for i in range(1, len(seqs)):
        if seqs[i] != seqs[i - 1] + 1:
            raise SoakFail(f"event_seq_jump_or_gap {seqs[i - 1]} -> {seqs[i]}")
    head_seq = int(head.get("seq") or 0)
    if head_seq != seqs[-1]:
        raise SoakFail(f"event_head_seq_mismatch head={head_seq} jsonl={seqs[-1]}")
    if last_seq > 0:
        if head_seq <= last_seq:
            raise SoakFail(f"event_seq_not_advanced last={last_seq} now={head_seq}")
        if last_seq in seqs:
            pass
        elif seqs[0] == last_seq + 1:
            pass
        else:
            raise SoakFail(f"event_seq_jump last={last_seq} now={head_seq} jsonl_start={seqs[0]}")
    elif head_seq < 1:
        raise SoakFail("event_seq_missing")
    return head_seq


def evaluate_round(
    *,
    targets: str,
    serial: str,
    model: str,
    status_path: Path,
    tun: str,
    cb: str,
    vpn: str,
    want_gen: str,
    last_at: int,
    last_event_seq: int = 0,
    event_seq: int | None = None,
    now_ms: int | None = None,
    status_rc: int = 0,
    head_path: Path | None = None,
    jsonl_path: Path | None = None,
    head_rc: int | None = None,
    jsonl_rc: int | None = None,
    want_rev: int | None = None,
    round_index: int = 0,
    last_wall: int = 0,
    wall_now: int = 0,
    max_gap_sec: int = 180,
    did_wifi: int = 0,
    did_screen: int = 0,
    held_sec: int = 0,
    require_phases: bool = False,
    lan_ok: bool = False,
    require_lan: bool = False,
    last_tun_rx: int = 0,
    last_tun_tx: int = 0,
    screen_round: bool = False,
) -> dict[str, Any]:
    if status_rc != 0:
        raise SoakFail(f"status_recv_rc {status_rc}")
    parse_targets(targets, serial)
    check_model(model)
    data = check_status_file(status_path, want_gen, last_at, now_ms=now_ms)
    rx, tx = check_tun(tun)
    check_clashbox(cb)
    check_vpn_pid(vpn)
    status_rev = int(data.get("sessionRevision") or 0)
    if want_rev is None:
        want_rev = status_rev
    elif want_rev != status_rev:
        raise SoakFail(f"status_revision {status_rev} want {want_rev}")
    seq_now: int | None = event_seq
    if head_path is not None or jsonl_path is not None or head_rc is not None or jsonl_rc is not None:
        if head_path is None or jsonl_path is None:
            raise SoakFail("event_chain_paths_missing")
        seq_now = check_event_chain(
            head_path=head_path,
            jsonl_path=jsonl_path,
            last_seq=last_event_seq,
            want_gen=str(data.get("generation") or want_gen),
            want_rev=status_rev,
            head_rc=0 if head_rc is None else int(head_rc),
            jsonl_rc=0 if jsonl_rc is None else int(jsonl_rc),
        )
    elif event_seq is not None:
        check_event_seq(last_event_seq, event_seq)
        seq_now = event_seq
    if wall_now and last_wall and wall_now < last_wall:
        raise SoakFail(f"wall_went_backwards {wall_now} {last_wall}")
    allow_screen_gap = bool(screen_round)
    if wall_now and last_wall and wall_now - last_wall > max_gap_sec and not allow_screen_gap:
        raise SoakFail(f"round_gap {wall_now - last_wall}s > {max_gap_sec}")
    if last_tun_rx and rx < last_tun_rx:
        raise SoakFail(f"tun_rx_went_backwards {rx} {last_tun_rx}")
    if last_tun_tx and tx < last_tun_tx:
        raise SoakFail(f"tun_tx_went_backwards {tx} {last_tun_tx}")
    if require_phases:
        if int(did_wifi) != 1:
            raise SoakFail("DID_WIFI missing")
        if int(did_screen) != 1:
            raise SoakFail("DID_SCREEN missing")
        if int(held_sec) < 1800:
            raise SoakFail(f"heldSec {held_sec} < 1800")
    if require_lan and not lan_ok:
        raise SoakFail("lan_request_missing")
    return {
        "ok": True,
        "generation": str(data.get("generation") or ""),
        "at": int(data.get("at") or 0),
        "tun_rx": rx,
        "tun_tx": tx,
        "up": data.get("uploadBytes"),
        "down": data.get("downloadBytes"),
        "vpn": vpn,
        "event_seq": seq_now,
        "sessionRevision": status_rev,
        "didWifi": int(did_wifi),
        "didScreen": int(did_screen),
        "heldSec": int(held_sec),
        "roundIndex": int(round_index),
        "lanOk": bool(lan_ok),
    }
