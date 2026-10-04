"""Bounded access-log slice. Auth original values are deleted, not prefixed."""
from __future__ import annotations

import re

MAX_PUB_CHARS = 100000
MAX_FILE_CHARS = 256000

# Consume the value so the original secret cannot remain after the marker.
_AUTH = re.compile(r"(?i)(user|pass|password|token|secret)=[^\s]+")
_LOCAL_PORT = re.compile(r"127\.0\.0\.1:\d+")


def redact_line(line: str) -> str:
    out = _AUTH.sub(r"\1=", line)
    out = _LOCAL_PORT.sub("127.0.0.1:*", out)
    return out


def rotate_and_redact(raw: str, max_file: int = MAX_FILE_CHARS, max_pub: int = MAX_PUB_CHARS) -> tuple[str, str]:
    text = raw if len(raw) <= max_file else raw[-max_file:]
    if len(text) < len(raw):
        cut = text.find("\n")
        if 0 <= cut < len(text) - 1:
            text = text[cut + 1 :]
    lines = [redact_line(ln) for ln in text.splitlines()]
    bounded = "\n".join(lines)
    if bounded:
        bounded += "\n"
    pub = bounded if len(bounded) <= max_pub else bounded[-max_pub:]
    return bounded, pub
