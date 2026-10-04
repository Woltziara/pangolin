"""HUKS wrap lifecycle as consumed by start/apply. Host model of HuksSecretStore."""
from __future__ import annotations

import json
from dataclasses import dataclass


class HuksError(Exception):
    pass


@dataclass
class Files:
    outbound: str = ""
    envelope: str = ""
    prev_envelope: str = ""
    meta: str = ""
    staging_meta: str = ""
    commit: str = ""


def protect(files: Files, available: bool, cipher_ok: bool = True) -> None:
    if len(files.outbound) < 20:
        return
    new_plain = files.outbound
    new_meta = files.staging_meta or files.meta
    previous_plain = ""
    if len(files.envelope) > 20:
        previous_plain = json.loads(files.envelope).get("ct", "")[::-1]
    if not available:
        files.outbound = ""
        files.staging_meta = ""
        raise HuksError("节点加密不可用，新配置未应用")
    if available and not cipher_ok:
        files.outbound = ""
        files.staging_meta = ""
        raise HuksError("新配置未应用，上一版仍可恢复")
    if available:
        files.prev_envelope = files.envelope
        files.envelope = json.dumps({"v": 1, "nonce": "n", "ct": new_plain[::-1]})
        files.outbound = ""
    files.meta = new_meta
    files.staging_meta = ""
    files.commit = json.dumps({"v": 1, "payloadDigest": new_plain, "metaDigest": new_meta, "status": "applied"})


def read_outbound(files: Files, available: bool = True) -> str:
    if len(files.envelope) > 20:
        if not available:
            raise HuksError("节点密文无法解开")
        parsed = json.loads(files.envelope)
        ct = parsed.get("ct", "")
        if not isinstance(ct, str) or len(ct) < 20:
            raise HuksError("节点密文无法解开")
        return ct[::-1]
    return files.outbound
