"""Parse VpnConstants.ets: IPv6 default route must not be isDefaultRoute=true."""
from __future__ import annotations

import re


def extract_fn(ets: str, name: str) -> str:
    marker = f"function {name}("
    start = ets.find(marker)
    if start < 0:
        raise ValueError(f"missing {name}")
    rest = ets[start:]
    end = rest.find("\nfunction ")
    if end < 0:
        end = rest.find("\nexport ")
    body = rest if end < 0 else rest[:end]
    return body


def is_default_route(fn_body: str) -> bool | None:
    match = re.search(r"isDefaultRoute:\s*(true|false)", fn_body)
    if not match:
        return None
    return match.group(1) == "true"


def ipv6_must_not_bypass(ets: str) -> tuple[bool, bool]:
    v4 = is_default_route(extract_fn(ets, "createIpv4DefaultRoute"))
    v6 = is_default_route(extract_fn(ets, "createIpv6DefaultRoute"))
    if v4 is None or v6 is None:
        raise ValueError("isDefaultRoute missing")
    return v4, v6
