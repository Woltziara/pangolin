"""Process-held exclusive lock using OS flock.

The lock lives as long as the holding file descriptor. A one-shot process
cannot "acquire and exit"; use hold() / the `hold` CLI for long waiters.
"""
from __future__ import annotations

import fcntl
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Callable


class DuplicateWaiter(Exception):
    def __init__(self, holder: int) -> None:
        self.holder = holder
        super().__init__(f"duplicate waiter holder={holder}")


# path -> (fd, pid, token)
_HOLD: dict[str, tuple[int, int, str]] = {}


def _key(path: Path) -> str:
    return str(Path(path).resolve()) if Path(path).exists() else str(Path(path))


def migrate_legacy_dir(path: Path) -> None:
    if not path.is_dir():
        return
    pid_path = path / "pid"
    try:
        pid_path.unlink()
    except FileNotFoundError:
        pass
    try:
        path.rmdir()
    except OSError as exc:
        raise DuplicateWaiter(0) from exc


def acquire(
    lock_path: Path | str,
    pid: int,
    alive: Callable[[int], bool] | None = None,
    pause_after_excl: Callable[[], None] | None = None,
    starttime_of: Callable[[int], str] | None = None,
) -> tuple[int, str]:
    del alive, starttime_of
    path = Path(lock_path)
    migrate_legacy_dir(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    key = str(path)
    if key in _HOLD:
        raise DuplicateWaiter(_HOLD[key][1])
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(fd)
        raise DuplicateWaiter(0) from exc
    if pause_after_excl is not None:
        pause_after_excl()
        # Another waiter may have run during pause; flock still held by fd.
    token = f"{pid}-{secrets.token_hex(8)}"
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, f"{pid}\n{token}\nflock\n".encode("utf-8"))
    os.fsync(fd)
    _HOLD[key] = (fd, pid, token)
    return pid, token


def release(lock_path: Path | str, pid: int, token: str = "") -> None:
    if not token:
        return
    path = Path(lock_path)
    key = str(path)
    held = _HOLD.get(key)
    if held is None:
        return
    fd, holder, existing = held
    if existing != token or holder != pid:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    _HOLD.pop(key, None)


def try_acquire(
    lock_path: Path | str,
    pid: int,
    alive: Callable[[int], bool] | None = None,
    pause_after_excl: Callable[[], None] | None = None,
    starttime_of: Callable[[int], str] | None = None,
) -> tuple[bool, int, str]:
    try:
        holder, token = acquire(
            lock_path,
            pid,
            alive=alive,
            pause_after_excl=pause_after_excl,
            starttime_of=starttime_of,
        )
        return True, holder, token
    except DuplicateWaiter as exc:
        return False, exc.holder, ""


def read_holder(lock_path: Path) -> tuple[int | None, str, str]:
    key = str(Path(lock_path))
    held = _HOLD.get(key)
    if held is not None:
        _fd, pid, token = held
        return pid, token, "flock"
    try:
        raw = Path(lock_path).read_text(encoding="utf-8")
    except OSError:
        return None, "", ""
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    if len(lines) < 2 or not lines[0].isdigit():
        return None, "", ""
    start = lines[2] if len(lines) > 2 else ""
    return int(lines[0]), lines[1], start


class WaitHarness:
    def __init__(self, lock_dir: Path, bringup_lock: Path, pid: int, alive_map: dict[int, bool]) -> None:
        self.lock_dir = lock_dir
        self.bringup_lock = bringup_lock
        self.pid = pid
        self.alive_map = alive_map
        self.bringups: list[int] = []
        self.held = False
        self.token = ""
        self.bringup_token = ""

    def start(self, x5_visible: bool) -> str:
        ok, holder, token = try_acquire(self.lock_dir, self.pid)
        if not ok:
            return f"duplicate-exit:{holder}"
        self.held = True
        self.token = token
        self.alive_map[self.pid] = True
        if not x5_visible:
            return "wait"
        return self.bringup()

    def bringup(self) -> str:
        ok, holder, token = try_acquire(self.bringup_lock, self.pid)
        if not ok:
            return f"bringup-skipped:{holder}"
        self.bringup_token = token
        self.bringups.append(self.pid)
        return "bringup"

    def stop(self) -> None:
        if self.held:
            release(self.lock_dir, self.pid, self.token)
            release(self.bringup_lock, self.pid, self.bringup_token)
            self.held = False
        self.alive_map[self.pid] = False


def hold_until_signal(lock_path: Path, pid: int) -> int:
    ok, holder, token = try_acquire(lock_path, pid)
    if not ok:
        print(f"DUPLICATE holder={holder}", flush=True)
        return 3
    print(f"ACQUIRED pid={pid} token={token}", flush=True)
    try:
        while True:
            time.sleep(3600)
    except (KeyboardInterrupt, SystemExit):
        release(lock_path, pid, token)
        return 0


def wait_acquired(out_path: Path | str, holder_pid: int, timeout_s: float = 8.0) -> int:
    """Wait until a hold child prints ACQUIRED. Does not take the lock."""
    path = Path(out_path)
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        if "ACQUIRED" in text:
            return 0
        if "DUPLICATE" in text:
            return 3
        if holder_pid > 0:
            try:
                os.kill(holder_pid, 0)
            except OSError:
                return 1
        time.sleep(0.05)
    return 1


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: hdc_singleton.py hold|wait-acquired|release|check LOCK [PID [TOKEN]]", file=sys.stderr)
        return 2
    cmd, lock = argv[0], argv[1]
    lock_path = Path(lock)
    pid = int(argv[2]) if len(argv) > 2 and str(argv[2]).isdigit() else 0
    token = argv[3] if len(argv) > 3 else ""
    if cmd == "acquire":
        print("CLI acquire exits and drops flock; use hold", file=sys.stderr)
        return 2
    if cmd == "wait-acquired":
        if pid <= 0:
            print("usage: hdc_singleton.py wait-acquired OUT PID", file=sys.stderr)
            return 2
        return wait_acquired(lock_path, pid)
    if cmd == "hold":
        return hold_until_signal(lock_path, pid)
    if cmd == "release":
        if not token:
            print("REFUSE empty token", file=sys.stderr)
            return 2
        release(lock_path, pid, token)
        print(f"RELEASED pid={pid}")
        return 0
    if cmd == "check":
        holder, existing, started = read_holder(lock_path)
        if holder is not None:
            print(f"HELD holder={holder} token={existing} via={started}")
            return 0
        print("FREE")
        return 1
    print(f"unknown cmd {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
