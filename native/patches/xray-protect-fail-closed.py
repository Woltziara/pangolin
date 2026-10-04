#!/usr/bin/env python3
"""Make Xray system_dialer fail closed when a dialer controller returns error."""
from __future__ import annotations

import sys
from pathlib import Path

OLD = """\t\t\t\tif err := ctl(network, address, c); err != nil {
\t\t\t\t\terrors.LogInfoInner(ctx, err, "failed to apply external controller")
\t\t\t\t}"""

NEW = """\t\t\t\tif err := ctl(network, address, c); err != nil {
\t\t\t\t\treturn err
\t\t\t\t}"""


def patch_system_dialer(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(OLD)
    if count != 2:
        raise SystemExit(f"{path}: expected 2 controller log-only sites, found {count}")
    path.write_text(text.replace(OLD, NEW), encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: xray-protect-fail-closed.py <system_dialer.go>")
    patch_system_dialer(Path(sys.argv[1]))
