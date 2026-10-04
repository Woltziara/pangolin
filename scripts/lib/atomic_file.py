"""Atomic file write matching native POSIX rename + directory fsync.

ArkTS fs.renameSync refuses an existing dest. StatusStore therefore calls
native atomicReplaceFile (rename/renameat + dir fsync) so every consumer
and HDC reads the same canonical path. Leftover dest.*.tmp files are
bounded-cleaned after a successful replace.
"""
from __future__ import annotations

import json
import os
import secrets
import time
from pathlib import Path

TMP_GRACE_SEC = 60
TMP_UNLINK_MAX = 32


def _write_tmp(path: Path, text: str) -> Path:
    nonce = secrets.token_hex(8)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{nonce}.tmp")
    data = text.encode("utf-8")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    return tmp


def write_atomic(path: Path, text: str, crash_after_tmp: bool = False) -> Path:
    """POSIX os.replace. Used only where the platform can replace dest."""
    path = Path(path)
    tmp = _write_tmp(path, text)
    if crash_after_tmp:
        return tmp
    os.replace(tmp, path)
    return tmp


def _cleanup_tmp(path: Path, now: float | None = None) -> None:
    """Delete old dest.*.tmp only. Never unlink an in-flight writer's tmp."""
    parent = path.parent
    prefix = path.name + "."
    stale: list[tuple[float, Path]] = []
    now = time.time() if now is None else now
    if parent.is_dir():
        for item in parent.iterdir():
            if not (item.name.startswith(prefix) and item.name.endswith(".tmp")):
                continue
            try:
                mtime = item.stat().st_mtime
            except OSError:
                continue
            if now < mtime + TMP_GRACE_SEC:
                continue
            stale.append((mtime, item))
    stale.sort()
    for _mtime, item in stale[:TMP_UNLINK_MAX]:
        try:
            item.unlink()
        except OSError:
            pass


def write_atomic_ohos(path: Path, text: str, crash_after_tmp: bool = False) -> Path:
    """Native POSIX replace: dest is always the latest complete snapshot."""
    path = Path(path)
    tmp = _write_tmp(path, text)
    if crash_after_tmp:
        return tmp
    os.replace(tmp, path)
    _cleanup_tmp(path)
    return tmp


def recover_canonical(path: Path) -> str:
    """Read dest if valid. If dest is missing, promote the newest valid tmp."""
    path = Path(path)
    if path.is_file() and path.stat().st_size >= 2:
        try:
            raw = path.read_text(encoding="utf-8")
            json.loads(raw)
            return raw
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    parent = path.parent
    prefix = path.name + "."
    candidates: list[Path] = []
    if parent.is_dir():
        for item in parent.iterdir():
            if item.name.startswith(prefix) and item.name.endswith(".tmp"):
                candidates.append(item)
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for cand in candidates:
        try:
            raw = cand.read_text(encoding="utf-8")
            json.loads(raw)
        except (OSError, json.JSONDecodeError, ValueError):
            continue
        try:
            os.replace(cand, path)
            _cleanup_tmp(path)
            return raw
        except OSError:
            return ""
    return ""


def read_status(path: Path) -> str:
    path = Path(path)
    if path.is_file():
        return path.read_text(encoding="utf-8")
    return recover_canonical(path)
