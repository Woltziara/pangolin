"""Isolated soak run identity and final fail-closed checker."""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from lib.atomic_file import write_atomic_ohos

MIN_DURATION_SEC = 7200
MIN_ROUNDS = 8


class SoakRunFail(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def new_run_id(generation: str, uuid_hex: str) -> str:
    gen = "".join(ch for ch in generation if ch.isalnum())[:24] or "nogen"
    return f"{gen}-{uuid_hex}"


def write_progress(path: Path, doc: dict[str, Any]) -> None:
    write_atomic_ohos(path, json.dumps(doc, ensure_ascii=False, indent=2) + "\n")


def start_summary(*, run_id: str, generation: str, start_ts: int, end_ts: int, pid: int = 0) -> dict[str, Any]:
    return {
        "verdict": "IN_PROGRESS",
        "runId": run_id,
        "pid": int(pid),
        "generation": generation,
        "startTs": int(start_ts),
        "plannedEndTs": int(end_ts),
        "durationSec": 0,
        "rounds": 0,
        "okRounds": 0,
        "attemptIndex": 0,
        "failReason": "",
    }


def finalize_summary(doc: dict[str, Any], *, now: int | None = None) -> dict[str, Any]:
    now_ts = int(time.time() if now is None else now)
    start_ts = int(doc.get("startTs") or 0)
    doc["endTs"] = now_ts
    doc["durationSec"] = max(0, now_ts - start_ts)
    return doc


def check_final(doc: dict[str, Any], *, min_duration: int = MIN_DURATION_SEC, min_rounds: int = MIN_ROUNDS) -> None:
    if str(doc.get("verdict") or "") == "IN_PROGRESS":
        raise SoakRunFail("summary still IN_PROGRESS")
    if str(doc.get("runId") or "") == "":
        raise SoakRunFail("missing runId")
    duration = int(doc.get("durationSec") or 0)
    planned = int(doc.get("plannedEndTs") or 0) - int(doc.get("startTs") or 0)
    if planned < min_duration:
        raise SoakRunFail(f"planned_duration {planned} < {min_duration}")
    if duration + 5 < min_duration:
        raise SoakRunFail(f"duration {duration} < {min_duration}")
    rounds = int(doc.get("rounds") or 0)
    if rounds < 1:
        raise SoakRunFail("zero rounds")
    if rounds < min_rounds:
        raise SoakRunFail(f"rounds {rounds} < {min_rounds}")
    if str(doc.get("verdict") or "") != "OK":
        raise SoakRunFail(str(doc.get("failReason") or doc.get("verdict") or "not_ok"))
    if int(doc.get("okRounds") or 0) != rounds:
        raise SoakRunFail("okRounds != rounds")
    if int(doc.get("didWifi") or 0) != 1:
        raise SoakRunFail("DID_WIFI missing")
    if int(doc.get("didScreen") or 0) != 1:
        raise SoakRunFail("DID_SCREEN missing")
    if int(doc.get("heldSec") or 0) < 1800:
        raise SoakRunFail(f"heldSec {doc.get('heldSec')} < 1800")
