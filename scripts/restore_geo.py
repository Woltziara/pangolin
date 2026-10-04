#!/usr/bin/env python3
"""Restore gitignored geoip/geosite from cache or pinned download, then verify hash."""
from __future__ import annotations

import hashlib
import json
import shutil
import ssl
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "native/GEO_LOCK.json"
CACHE = ROOT / ".runtime/geo-cache"


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _ok(path: Path, want_sha: str, want_bytes: int) -> bool:
    if not path.is_file():
        return False
    if path.stat().st_size != want_bytes:
        return False
    return _sha(path) == want_sha


def _download(url: str, dest: Path, want_sha: str, want_bytes: int) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".dl")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(url, context=ctx, timeout=120) as resp:
            data = resp.read()
    except Exception:
        return False
    tmp.write_bytes(data)
    if tmp.stat().st_size != want_bytes or hashlib.sha256(data).hexdigest() != want_sha:
        tmp.unlink(missing_ok=True)
        return False
    tmp.replace(dest)
    return True


def restore(root: Path = ROOT) -> dict[str, str]:
    lock = json.loads((root / "native/GEO_LOCK.json").read_text())
    cache = root / ".runtime/geo-cache"
    cache.mkdir(parents=True, exist_ok=True)
    out: dict[str, str] = {}
    for key in ("geoip", "geosite"):
        item = lock[key]
        dest = root / item["path"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        cached = cache / Path(item["path"]).name
        want_sha = item["sha256"]
        want_bytes = int(item["bytes"])
        if not item.get("version"):
            raise SystemExit(f"geo {key} missing immutable version")
        for url in item.get("urls") or []:
            if "/latest/" in str(url) or "@release" in str(url):
                raise SystemExit(f"geo {key} url is not immutable: {url}")
        if _ok(dest, want_sha, want_bytes):
            if not _ok(cached, want_sha, want_bytes):
                shutil.copy2(dest, cached)
            out[key] = "present"
            continue
        if _ok(cached, want_sha, want_bytes):
            shutil.copy2(cached, dest)
            out[key] = "restored-from-cache"
            continue
        downloaded = False
        for url in item.get("urls") or []:
            if "/latest/" in str(url) or "@release" in str(url) or "/latest" in str(url):
                raise SystemExit(f"geo {key} url is not immutable: {url}")
            if _download(str(url), cached, want_sha, want_bytes):
                shutil.copy2(cached, dest)
                out[key] = f"downloaded:{url}"
                downloaded = True
                break
        if not downloaded:
            raise SystemExit(
                f"missing geo {key}: hash {want_sha} not in cache and pinned urls failed. "
                f"Place matching files in {cache} or {dest.parent}"
            )
        if not _ok(dest, want_sha, want_bytes):
            raise SystemExit(f"geo {key} hash mismatch after restore")
    return out


def main() -> int:
    print(json.dumps(restore(), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
