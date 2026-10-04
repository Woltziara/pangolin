"""Bounded subprocess. Fail closed on timeout or nonzero."""
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Mapping, Sequence


class BoundedCmdError(RuntimeError):
    def __init__(self, cmd: Sequence[str], reason: str) -> None:
        self.cmd = list(cmd)
        super().__init__(reason)


def run_bounded(
    cmd: Sequence[str],
    *,
    cwd: str | Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            list(cmd),
            cwd=None if cwd is None else str(cwd),
            env=dict(env) if env is not None else None,
            timeout=timeout,
            capture_output=True,
            text=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise BoundedCmdError(cmd, f"timeout after {timeout}s") from exc
    if result.returncode != 0:
        tail = (result.stderr or result.stdout or "")[-400:]
        raise BoundedCmdError(cmd, f"rc={result.returncode} {tail}")
    return result
