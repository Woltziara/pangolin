"""Host-side VPN start/stop cycle helpers. Fail-closed waits."""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Callable

from lib.extprobe import HdcError


def find_button_center(dump: str, label: str) -> tuple[int, int]:
    blob = dump
    idx = blob.find(label)
    if idx < 0:
        raise HdcError(["uitest"], 2, f"button {label} unobserved")
    window = blob[max(0, idx - 400) : idx + 400]
    match = re.search(r'"bounds"\s*:\s*"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', window)
    if not match:
        match = re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", window)
    if not match:
        raise HdcError(["uitest"], 2, f"bounds missing for {label}")
    x1, y1, x2, y2 = (int(match.group(i)) for i in range(1, 5))
    return (x1 + x2) // 2, (y1 + y2) // 2


def wait_until(pred: Callable[[], bool], timeout: float, what: str, interval: float = 0.5) -> None:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            if pred():
                return
        except Exception as exc:  # noqa: BLE001
            last = str(exc)
        time.sleep(interval)
    raise HdcError(["wait"], 2, f"timeout waiting {what} {last}")


def wait_canary_commit(
    *,
    status_fn: Callable[[], dict],
    commit_fn: Callable[[], dict],
    old_generation: str,
    requested_generation: str = "",
    timeout: float = 40,
) -> dict:
    got: dict = {}

    def pred() -> bool:
        st = status_fn()
        commit = commit_fn()
        got["status"] = st
        got["commit"] = commit
        gen = str(st.get("generation") or "")
        if not gen or gen == old_generation:
            return False
        if requested_generation and gen != requested_generation:
            return False
        if st.get("phase") != "CANARY_OK":
            return False
        if str(commit.get("kind") or "") != "commit":
            return False
        if str(st.get("lastProvenRid") or "") != str(commit.get("rid") or ""):
            return False
        if int(st.get("evidenceAt") or 0) < 1:
            return False
        if str(commit.get("generation") or "") != gen:
            return False
        return True

    wait_until(pred, timeout, "CANARY_OK commit")
    return got


def wait_stopped(
    *,
    status_fn: Callable[[], dict],
    tun_fn: Callable[[], str],
    pid_fn: Callable[[], str],
    old_generation: str,
    old_epoch: int,
    timeout: float = 20,
    native_fn: Callable[[], dict] | None = None,
) -> dict:
    got: dict = {}
    if not old_generation:
        raise HdcError(["wait"], 2, "wait_stopped requires old_generation")
    if native_fn is None:
        raise HdcError(["wait"], 2, "wait_stopped requires native_fn")

    def pred() -> bool:
        st = status_fn()
        tun = tun_fn()
        pid = pid_fn()
        native = native_fn()
        got["status"] = st
        got["tun"] = tun
        got["pid"] = pid
        got["native"] = native
        gen = str(st.get("generation") or "")
        if not gen or gen != old_generation:
            return False
        if "[Fail]" in tun or "[fail]" in tun:
            return False
        if st.get("phase") in ("CANARY_OK", "ERROR", "POISONED"):
            return False
        if st.get("phase") != "STOPPED":
            return False
        if st.get("desiredRunning") is True:
            return False
        if "vpn-tun" in tun:
            return False
        if pid:
            return False
        if int(st.get("commandEpoch") or 0) <= old_epoch:
            return False
        if st.get("forwarderOk") is True or int(st.get("tunFd") or -1) >= 0:
            return False
        if native.get("xrayRunning") is not False:
            return False
        if native.get("tunRunning") is not False:
            return False
        if native.get("poisoned") is not False:
            return False
        return True

    wait_until(pred, timeout, "STOPPED tun/core/HEV gone")
    return got
