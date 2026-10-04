"""Independent acceptance phases: Wi-Fi bounce and 30-minute screen-off."""
from __future__ import annotations

import time
from typing import Callable

from lib.extprobe import HdcError

SCREEN_OFF_SEC = 1800


def parse_wifi(text: str) -> dict[str, object]:
    low = (text or "").lower()
    if not text.strip():
        raise HdcError(["wifi"], 2, "wifi status unreadable empty")
    if "fail" in low and "wlan" not in low and "wifi" not in low:
        raise HdcError(["wifi"], 2, f"wifi status unreadable {text[:200]}")
    disabled = ("disabled" in low) or ("wifi is off" in low) or ("status: down" in low)
    down_flags = ("flags=" in low and "up" not in low) or ("<down>" in low)
    running = "running" in low or "<up,broadcast,running" in low.replace(" ", "")
    associated = ("inet " in low) or ("wpa_state=completed" in low) or ("state: associated" in low)
    enabled_only = ("enabled" in low or "wifi is on" in low or "ssid" in low) and "running" not in low and "inet " not in low
    up = False
    if disabled or down_flags:
        up = False
    elif running or associated:
        up = True
    elif enabled_only:
        raise HdcError(["wifi"], 2, f"wifi enabled-text without interface/association {text[:200]}")
    else:
        raise HdcError(["wifi"], 2, f"wifi state not parsed {text[:200]}")
    return {"up": up, "raw": text}


def parse_screen(text: str) -> dict[str, object]:
    low = (text or "").lower()
    if not text.strip():
        raise HdcError(["screen"], 2, "screen state unreadable empty")
    off = (
        "isscreenon: false" in low
        or "is_screen_on=false" in low
        or "screenon=false" in low
        or "state=sleep" in low
        or "displaypower=off" in low
        or "screen state: off" in low
        or "aod" in low and "off" in low
    )
    on = (
        "isscreenon: true" in low
        or "is_screen_on=true" in low
        or "screenon=true" in low
        or "screen state: on" in low
        or "displaypower=on" in low
    )
    if off and not on:
        return {"on": False, "raw": text}
    if on and not off:
        return {"on": True, "raw": text}
    raise HdcError(["screen"], 2, f"screen state not parsed {text[:200]}")


def wifi_bounce(
    *,
    run: Callable[..., str],
    verify: Callable[[], str],
    sleep: Callable[[float], None] | None = None,
) -> dict[str, str]:
    nap = sleep or time.sleep
    before_raw = verify()
    before = parse_wifi(before_raw)
    if not before["up"]:
        raise HdcError(["wifi"], 2, f"wifi already down before bounce: {before_raw[:200]}")
    run("shell", "svc", "wifi", "disable")
    nap(3)
    down_raw = verify()
    down = parse_wifi(down_raw)
    if down["up"]:
        raise HdcError(["wifi"], 2, f"wifi still up after disable: {down_raw[:200]}")
    run("shell", "svc", "wifi", "enable")
    nap(5)
    up_raw = verify()
    up = parse_wifi(up_raw)
    if not up["up"]:
        raise HdcError(["wifi"], 2, f"wifi not restored: {up_raw[:200]}")
    return {"before": before_raw, "down": down_raw, "up": up_raw, "didWifi": "1"}


def screen_off_hold(
    *,
    run: Callable[..., str],
    now: Callable[[], float] | None = None,
    sleep: Callable[[float], None] | None = None,
    seconds: int = SCREEN_OFF_SEC,
    poll: Callable[[], None] | None = None,
    read_screen: Callable[[], str] | None = None,
    alive_fn: Callable[[], int] | None = None,
    max_stall_sec: int = 600,
) -> dict[str, int]:
    if seconds < SCREEN_OFF_SEC:
        raise HdcError(["screen"], 2, f"screen-off {seconds}s < {SCREEN_OFF_SEC}")
    if read_screen is None:
        raise HdcError(["screen"], 2, "read_screen required; wall-clock hold is not evidence")
    nap = sleep or time.sleep
    run("shell", "power-shell", "timeout")
    parsed = parse_screen(read_screen())
    if parsed["on"]:
        raise HdcError(["screen"], 2, "screen still on after timeout")
    need = max(2, int(seconds) // 30)
    reads = 1
    last_progress: int | None = None
    stall_reads = 0
    while reads < need:
        if poll is not None:
            poll()
        if alive_fn is not None:
            try:
                progress = int(alive_fn() or 0)
            except HdcError:
                raise
            except Exception as exc:
                raise HdcError(["screen"], 2, f"keepalive unreadable {exc}") from exc
            if last_progress is None or progress > last_progress:
                last_progress = progress
                stall_reads = reads
            elif (reads - stall_reads) * 30 >= max_stall_sec:
                raise HdcError(
                    ["screen"],
                    2,
                    f"keepalive progress stalled at {progress}; not waiting for silent freeze",
                )
        parsed = parse_screen(read_screen())
        reads += 1
        if parsed["on"]:
            raise HdcError(["screen"], 2, "screen woke during hold")
        nap(30.0)
    if reads < need:
        raise HdcError(["screen"], 2, "screen-off hold did not re-read screen")
    elapsed = reads * 30
    run("shell", "power-shell", "wakeup")
    return {"heldSec": elapsed, "didScreen": 1, "keepProgress": int(last_progress or 0)}
