"""Controlled ProcessLibs/DoNativeStrip replay: llvm-strip --strip-all of the raw prebuilt."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

STRIP_ARGS = ("--strip-all",)


def find_llvm_strip(root: Path | None = None) -> Path:
    env = os.environ.get("OHOS_LLVM_STRIP") or os.environ.get("LLVM_STRIP")
    if env:
        path = Path(env)
        if path.is_file():
            return path
    sdk = os.environ.get("DEVECO_SDK_HOME") or "/Applications/DevEco-Studio.app/Contents/sdk"
    native = os.environ.get("OHOS_NATIVE_HOME") or str(Path(sdk) / "default/openharmony/native")
    candidate = Path(native) / "llvm/bin/llvm-strip"
    if candidate.is_file():
        return candidate
    raise FileNotFoundError("llvm-strip not found; set OHOS_LLVM_STRIP")


def packed_bytes(raw: Path, strip_bin: Path | None = None) -> bytes:
    if not raw.is_file():
        raise FileNotFoundError(str(raw))
    tool = strip_bin or find_llvm_strip()
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / raw.name
        shutil.copy2(raw, dest)
        subprocess.check_call([str(tool), *STRIP_ARGS, str(dest)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return dest.read_bytes()


def expected_packed_sha256(raw: Path, strip_bin: Path | None = None) -> str:
    return hashlib.sha256(packed_bytes(raw, strip_bin)).hexdigest()
