"""Fail-closed external probe: unique RID, clean dest, hdc rc, same-window deltas."""
from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

BROWSER_BUNDLE = "com.huawei.hmos.browser"

GOOGLE_MARKERS = (
    "google",
    "gstatic",
    "youtube",
    "142.251",
    "172.217",
    "216.58",
    "2607:f8b0",
    "2001:4860",
)
# DIRECT must not be the periodic baidu SOCKS canary (www.baidu.com:80).
QQ_MARKERS = ("qq.com", "gtimg", "183.3.", "123.151.")
BILI_MARKERS = ("bilibili", "hdslb.com", "bilivideo")
BAIDU_CANARY_MARKERS = ("baidu.com", "wikipedia.org", "wikimedia")
LAN_MARKERS = ("192.168.3.", "10.7.0.", "192.168.", "10.", "172.16.", "172.17.", "172.18.")


class HdcError(RuntimeError):
    def __init__(self, args: Sequence[str], rc: int, output: str) -> None:
        self.args = list(args)
        self.rc = rc
        self.output = output
        super().__init__(f"hdc_rc={rc} args={args} out={output[:200]}")


Runner = Callable[[Sequence[str], int], subprocess.CompletedProcess[bytes]]


def default_runner(args: Sequence[str], timeout: int) -> subprocess.CompletedProcess[bytes]:
    hdc = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    return subprocess.run(list(args) if args and args[0].endswith("hdc") else [hdc, *args],
                          capture_output=True, timeout=timeout)


def hdc(args: Sequence[str], timeout: int = 40, runner: Runner | None = None) -> str:
    run = runner or default_runner
    result = run(args, timeout)
    text = ((result.stdout or b"") + (result.stderr or b"")).decode("utf-8", errors="replace")
    if result.returncode != 0:
        raise HdcError(args, result.returncode, text)
    return text


def recv_clean(remote: str, dest: Path, timeout: int = 40, runner: Runner | None = None) -> str:
    dest = Path(dest)
    if dest.exists():
        dest.unlink()
    hdc(["file", "recv", remote, str(dest)], timeout=timeout, runner=runner)
    if not dest.is_file() or dest.stat().st_size < 1:
        raise HdcError(["file", "recv", remote, str(dest)], 1, "empty dest after recv")
    return dest.read_text(encoding="utf-8", errors="replace")


def parse_tun(line: str) -> dict[str, int]:
    nums = [int(x) for x in re.findall(r"\d+", line)]
    if len(nums) >= 10:
        return {
            "rxBytes": nums[0],
            "rxPackets": nums[1],
            "txBytes": nums[8],
            "txPackets": nums[9],
        }
    return {"rxBytes": 0, "rxPackets": 0, "txBytes": 0, "txPackets": 0}


UNIQUE_PROXY_HOST = "td-proxy.probe"
UNIQUE_DIRECT_HOST = "td-direct.probe"

_ACCESS_LINE = re.compile(
    r"(?:accepted\s+)?(udp|tcp):(\S+)\s+\[tun-in -> (proxy|direct|dns-out)\]",
    re.I,
)


def parse_access_line(line: str) -> tuple[str, str, str] | None:
    if "tun-in" not in line:
        return None
    match = _ACCESS_LINE.search(line)
    if not match:
        return None
    return match.group(1).lower(), match.group(2), match.group(3).lower()


def _dest_port(dest: str) -> int:
    if dest.endswith("]"):
        return -1
    idx = dest.rfind(":")
    if idx < 0:
        return -1
    try:
        return int(dest[idx + 1 :])
    except ValueError:
        return -1


def _dest_host(dest: str) -> str:
    raw = dest or ""
    if raw.startswith("["):
        end = raw.find("]")
        return raw[1:end] if end > 0 else raw
    idx = raw.rfind(":")
    if idx < 0:
        return raw
    return raw[:idx]


def new_access_text(before: str, after: str) -> str:
    """Lines that appeared in after but not before. Avoids leftover 64k snapshots."""
    before_set = set((before or "").splitlines())
    added = [ln for ln in (after or "").splitlines() if ln not in before_set]
    return "\n".join(added)


def classify_window(text: str, rid: str) -> dict[str, object]:
    google_proxy = False
    unique_direct = False
    baidu_canary = False
    udp_proxy = False
    rid_seen = False
    unique_proxy_host = False
    unique_direct_host = False
    tags: list[str] = []
    sample: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if rid and rid in line:
            rid_seen = True
        parsed = parse_access_line(line)
        if parsed is None:
            continue
        proto, dest, tag = parsed
        low = dest.lower()
        if UNIQUE_PROXY_HOST in low:
            unique_proxy_host = True
        if UNIQUE_DIRECT_HOST in low:
            unique_direct_host = True
        tagged = False
        if tag in ("proxy", "proxy-us", "dns-out"):
            if tag in ("proxy", "proxy-us") and (any(x in low for x in GOOGLE_MARKERS) or UNIQUE_PROXY_HOST in low):
                google_proxy = True
                tagged = True
                tags.append("proxy")
            if proto == "udp" and _dest_port(dest) == 53:
                udp_proxy = True
                tagged = True
                tags.append("udp")
            if any(x in low for x in BAIDU_CANARY_MARKERS):
                baidu_canary = True
        if tag == "direct":
            baidu_hit = any(x in low for x in BAIDU_CANARY_MARKERS) or any(
                x in low for x in ("baidu.com", "103.235.", "180.76.", "220.181.")
            )
            google_hit = any(x in low for x in GOOGLE_MARKERS)
            named_mainland = (
                any(x in low for x in QQ_MARKERS)
                or any(x in low for x in BILI_MARKERS)
                or any(x in low for x in LAN_MARKERS)
                or UNIQUE_DIRECT_HOST in low
            )
            if named_mainland:
                unique_direct = True
                tagged = True
                tags.append("direct")
            elif proto == "tcp" and not baidu_hit and not google_hit:
                # System DNS resolves first; Harmony browser TLS often leaves
                # the access dest as the CN IP, not qq.com.
                unique_direct = True
                tagged = True
                tags.append("direct")
            if baidu_hit:
                baidu_canary = True
        if tagged and len(sample) < 16:
            sample.append(line[-240:])
    return {
        "googleProxy": google_proxy,
        "uniqueDirect": unique_direct,
        "baiduCanarySeen": baidu_canary,
        "udp53Proxy": udp_proxy,
        "ridSeen": rid_seen,
        "uniqueProxyHost": unique_proxy_host,
        "uniqueDirectHost": unique_direct_host,
        "outboundTags": sorted(set(tags)),
        "sample": sample,
    }


def udp53_line_set(text: str) -> set[str]:
    """tun-in UDP/53 lines that Xray sent to proxy or dns-out."""
    lines: set[str] = set()
    for raw in (text or "").splitlines():
        parsed = parse_access_line(raw)
        if parsed is None:
            continue
        proto, dest, tag = parsed
        if proto == "udp" and _dest_port(dest) == 53 and tag in ("proxy", "dns-out"):
            lines.add(raw.strip())
    return lines


def lan_direct_line_set(text: str, gateway: str) -> set[str]:
    """tun-in DIRECT lines whose dest host is the LAN gateway (not DNS hijack)."""
    lines: set[str] = set()
    gw = (gateway or "").strip()
    if not gw:
        return lines
    for raw in (text or "").splitlines():
        parsed = parse_access_line(raw)
        if parsed is None:
            continue
        _proto, dest, tag = parsed
        if tag == "direct" and _dest_host(dest) == gw:
            lines.add(raw.strip())
    return lines


def lan_proxy_line_set(text: str, gateway: str) -> set[str]:
    """tun-in PROXY lines to the LAN gateway — that would be a leak."""
    lines: set[str] = set()
    gw = (gateway or "").strip()
    if not gw:
        return lines
    for raw in (text or "").splitlines():
        parsed = parse_access_line(raw)
        if parsed is None:
            continue
        _proto, dest, tag = parsed
        if tag == "proxy" and _dest_host(dest) == gw:
            lines.add(raw.strip())
    return lines


def parse_wlan_gateway(ifconfig_out: str) -> str:
    """wlan0/wlan1 IPv4 -> typical .1 gateway. Ignore vpn-tun and 卓易通 ancowlan."""
    blocks = re.split(r"\n(?=\S)", ifconfig_out or "")
    for name in ("wlan0", "wlan1"):
        for block in blocks:
            first = block.split(None, 1)
            if not first or first[0] != name:
                continue
            match = re.search(r"inet addr:(\d+\.\d+\.\d+\.\d+)", block)
            if not match:
                continue
            parts = match.group(1).split(".")
            if len(parts) != 4:
                continue
            gw = f"{parts[0]}.{parts[1]}.{parts[2]}.1"
            if re.match(r"^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)", gw):
                return gw
    return ""


@dataclass
class WindowEvidence:
    rid: str
    generation_before: str
    generation_after: str
    revision_before: int
    revision_after: int
    tun_rx_before: int = 0
    tun_rx_after: int = 0
    tun_tx_before: int = 0
    tun_tx_after: int = 0
    hev_up_before: int = 0
    hev_up_after: int = 0
    hev_down_before: int = 0
    hev_down_after: int = 0
    tags: dict[str, object] | None = None
    page_error: bool = False
    google_page_ok: bool = False
    direct_page_ok: bool = False
    rid_in_page: bool = False
    browser_pid: str = ""
    tongdao_pid: str = ""
    browser_bundle: str = BROWSER_BUNDLE
    on_device_marker: bool = False
    http_ok: bool = False
    access_offset: int = 0
    probe_revision: int = 0
    consumed: bool = False
    evidence_rid: str = ""
    consumed_rid: str = ""
    google_http_helper: bool = False
    dns_helper: bool = False
    browser_uid: str = ""
    tongdao_uid: str = ""
    observed_browser_bundle: str = ""
    google_http_status: int = 0
    direct_http_status: int = 0
    host_offset_hint: int = -1
    consumed_generation: str = ""
    consumed_revision: int = 0
    consumed_access_offset: int = -1
    consumed_epoch: int = -1
    consumed_at: int = 0
    consumed_raw_cursor: int = -1
    purpose: str = ""
    commit_kind: str = ""
    status_phase: str = ""
    last_proven_rid: str = ""
    page_content_ok: bool = False
    dump_has_rid: bool = False
    production_rid: str = ""
    dns_query_sent: bool = False
    udp_transport: str = ""
    browser_http_source: str = ""
    probe_actor: str = ""
    udp_txid_ok: bool = False
    udp_recv: bool = False
    # Deprecated total-counter fields still accepted as fail-closed aliases.
    tun_before: int = 0
    tun_after: int = 0
    hev_before: int = 0
    hev_after: int = 0


def evaluate_window(ev: WindowEvidence) -> dict[str, object]:
    if not ev.rid:
        raise HdcError(["rid"], 2, "missing unique rid")
    tags = ev.tags or {}
    if ev.access_offset < 0:
        return {"ok": False, "reason": "missing_access_offset"}
    if ev.purpose in ("browser_google", "browser_direct", "browser_udp"):
        if ev.generation_before != ev.generation_after or not ev.generation_after:
            return {"ok": False, "reason": "generation_mismatch"}
        if ev.revision_before != ev.revision_after or ev.revision_after < 1:
            return {"ok": False, "reason": "revision_mismatch"}
        if not ev.browser_uid or not ev.tongdao_uid or ev.browser_uid == ev.tongdao_uid:
            return {"ok": False, "reason": "browser_uid_not_independent"}
        if not ev.browser_pid or not ev.tongdao_pid or ev.browser_pid == ev.tongdao_pid:
            return {"ok": False, "reason": "browser_pid_not_independent"}
        return evaluate_browser_subwindow(ev)
    if not ev.consumed:
        return {"ok": False, "reason": "probe_not_consumed"}
    if ev.evidence_rid != ev.rid or ev.consumed_rid != ev.rid:
        return {"ok": False, "reason": "marker_status_rid_mismatch"}
    if ev.probe_revision != ev.revision_after or ev.probe_revision < 1:
        return {"ok": False, "reason": "probe_revision_mismatch"}
    # HTTPS query RID does not appear in Xray access logs. RID is bound by the
    # consumed marker matching status.evidenceRid, not by log substring.
    if ev.purpose != "production":
        if ev.browser_bundle != BROWSER_BUNDLE:
            return {"ok": False, "reason": "wrong_browser_bundle"}
        if not ev.observed_browser_bundle:
            return {"ok": False, "reason": "browser_bundle_unobserved"}
        if ev.observed_browser_bundle != BROWSER_BUNDLE:
            return {"ok": False, "reason": "observed_browser_bundle_mismatch"}
        if not ev.browser_uid or not ev.tongdao_uid or ev.browser_uid == ev.tongdao_uid:
            return {"ok": False, "reason": "browser_uid_not_independent"}
        if not ev.browser_pid or not ev.tongdao_pid or ev.browser_pid == ev.tongdao_pid:
            return {"ok": False, "reason": "browser_pid_not_independent"}
    if ev.consumed_generation and ev.consumed_generation != ev.generation_after:
        return {"ok": False, "reason": "consumed_generation_mismatch"}
    if ev.consumed_revision and ev.consumed_revision != ev.revision_after:
        return {"ok": False, "reason": "consumed_revision_mismatch"}
    if ev.consumed_access_offset < 0 or ev.consumed_raw_cursor < 0 or ev.consumed_epoch < 0 or ev.consumed_at < 1:
        return {"ok": False, "reason": "consumed_fields_incomplete"}
    if ev.host_offset_hint >= 0 and ev.consumed_access_offset != ev.consumed_raw_cursor:
        # Host offset is a consistency hint only. Runtime cursor is consume-instant rawCursor.
        if ev.access_offset != ev.consumed_raw_cursor and ev.access_offset != ev.consumed_access_offset:
            return {"ok": False, "reason": "runtime_cursor_not_rawCursor"}
    if ev.generation_before != ev.generation_after or not ev.generation_after:
        return {"ok": False, "reason": "generation_mismatch"}
    if ev.revision_before != ev.revision_after or ev.revision_after < 1:
        return {"ok": False, "reason": "revision_mismatch"}
    tun_rx_delta = ev.tun_rx_after - ev.tun_rx_before
    tun_tx_delta = ev.tun_tx_after - ev.tun_tx_before
    hev_up_delta = ev.hev_up_after - ev.hev_up_before
    hev_down_delta = ev.hev_down_after - ev.hev_down_before
    fetch_ok = (
        ev.google_http_status == 204
        and 200 <= int(ev.direct_http_status or 0) < 400
        and bool(ev.dns_helper)
    )
    if ev.purpose == "production" and fetch_ok:
        return evaluate_production_commit(ev)
    if tun_rx_delta <= 0 or tun_tx_delta <= 0:
        return {"ok": False, "reason": "missing_bidirectional_tun"}
    if hev_up_delta <= 0 or hev_down_delta <= 0:
        return {"ok": False, "reason": "missing_bidirectional_hev"}
    if ev.purpose == "production":
        return evaluate_production_commit(ev)
    google = bool(tags.get("googleProxy"))
    unique_direct = bool(tags.get("uniqueDirect"))
    udp = bool(tags.get("udp53Proxy"))
    outbound = tags.get("outboundTags") or []
    if unique_direct is False and tags.get("baiduCanarySeen"):
        return {"ok": False, "reason": "baidu_canary_not_attributable"}
    if "proxy" not in outbound:
        return {"ok": False, "reason": "missing_proxy_tag"}
    if "direct" not in outbound:
        return {"ok": False, "reason": "missing_direct_tag"}
    if "udp" not in outbound and not udp:
        return {"ok": False, "reason": "missing_udp_tag"}
    if not ev.google_page_ok:
        return {"ok": False, "reason": "google_page_fail"}
    if ev.page_error:
        return {"ok": False, "reason": "google_page_fail"}
    if not ev.direct_page_ok:
        return {"ok": False, "reason": "direct_page_fail"}
    if ev.google_http_status and ev.google_http_status != 204:
        return {"ok": False, "reason": "google_http_status_fail"}
    if ev.direct_http_status and (ev.direct_http_status < 200 or ev.direct_http_status >= 400):
        return {"ok": False, "reason": "direct_http_status_fail"}
    if not ev.dns_helper:
        return {"ok": False, "reason": "dns_helper_fail"}
    ok = google and unique_direct and udp
    reason = ""
    if not google:
        reason = "googleProxy=false"
    elif not unique_direct:
        reason = "uniqueDirect=false"
    elif not udp:
        reason = "udp53Proxy=false"
    return {
        "ok": ok,
        "reason": reason,
        "tunRxDelta": tun_rx_delta,
        "tunTxDelta": tun_tx_delta,
        "hevUpDelta": hev_up_delta,
        "hevDownDelta": hev_down_delta,
        "googleProxy": google,
        "uniqueDirect": unique_direct,
        "udp53Proxy": udp,
        "baiduCanarySeen": bool(tags.get("baiduCanarySeen")),
    }


def evaluate_production_commit(ev: WindowEvidence) -> dict[str, object]:
    if ev.commit_kind != "commit":
        return {"ok": False, "reason": "issued_is_not_commit"}
    if ev.status_phase != "CANARY_OK":
        return {"ok": False, "reason": "status_not_canary_ok"}
    if ev.last_proven_rid != ev.rid or ev.evidence_rid != ev.rid:
        return {"ok": False, "reason": "lastProvenRid_mismatch"}
    if ev.consumed_at < 1:
        return {"ok": False, "reason": "commit_at_missing"}
    tags = ev.tags or {}
    mainland = bool(tags.get("uniqueDirect") or tags.get("baiduCanarySeen"))
    if not tags.get("googleProxy") or not mainland or not tags.get("udp53Proxy"):
        return {"ok": False, "reason": "production_tags_incomplete"}
    if ev.google_http_status != 204:
        return {"ok": False, "reason": "production_google_http_fail"}
    if ev.direct_http_status < 200 or ev.direct_http_status >= 400:
        return {"ok": False, "reason": "production_direct_http_fail"}
    if not ev.dns_helper:
        return {"ok": False, "reason": "production_dns_fail"}
    return {"ok": True, "reason": "", "purpose": "production"}


def evaluate_browser_subwindow(ev: WindowEvidence) -> dict[str, object]:
    if ev.purpose == "browser_udp":
        tags = ev.tags or {}
        # Isolated client is the browser. hdc-shell (uid 2000) bypasses
        # VpnExtensionAbility; the device has no python/nc/nslookup.
        if not ev.observed_browser_bundle:
            return {"ok": False, "reason": "browser_bundle_unobserved"}
        if ev.observed_browser_bundle != BROWSER_BUNDLE:
            return {"ok": False, "reason": "observed_browser_bundle_mismatch"}
        if ev.production_rid and ev.production_rid == ev.rid:
            return {"ok": False, "reason": "browser_rid_not_isolated"}
        if not ev.dns_query_sent:
            return {"ok": False, "reason": "udp_not_sent"}
        if not ev.udp_recv:
            return {"ok": False, "reason": "udp_no_recv"}
        if not ev.udp_txid_ok:
            return {"ok": False, "reason": "udp_txid_mismatch"}
        if not tags.get("udp53Proxy"):
            return {"ok": False, "reason": "udp53Proxy=false"}
        return {"ok": True, "reason": "", "purpose": "browser_udp", "udp53Proxy": True}
    if not ev.observed_browser_bundle:
        return {"ok": False, "reason": "browser_bundle_unobserved"}
    if ev.observed_browser_bundle != BROWSER_BUNDLE:
        return {"ok": False, "reason": "observed_browser_bundle_mismatch"}
    if ev.page_error:
        return {"ok": False, "reason": "browser_page_error"}
    tags = ev.tags or {}
    if ev.production_rid and ev.production_rid == ev.rid:
        return {"ok": False, "reason": "browser_rid_not_isolated"}
    if ev.browser_http_source == "probe-fetch.json":
        return {"ok": False, "reason": "browser_used_production_fetch"}
    if ev.purpose == "browser_google":
        # generate_204 has an empty body. Page dump is not HTTP evidence.
        # Routing tags without an independent HTTP status are observation only.
        if ev.browser_http_source != "http-status-line" or ev.google_http_status != 204:
            return {"ok": False, "reason": "google_http_not_from_http"}
        if not tags.get("googleProxy"):
            return {"ok": False, "reason": "googleProxy=false"}
        return {"ok": True, "reason": "", "purpose": "browser_google", "googleProxy": True}
    if ev.purpose == "browser_direct":
        if not tags.get("uniqueDirect"):
            return {"ok": False, "reason": "uniqueDirect=false"}
        return {"ok": True, "reason": "", "purpose": "browser_direct", "uniqueDirect": True}
    return {"ok": False, "reason": "unknown_browser_purpose"}


def _suffix_prefix_overlap(before: str, after: str) -> int:
    """Longest suffix of before that is a prefix of after (KMP)."""
    if not before or not after:
        return 0
    s = after + "\0" + before
    lps = [0] * len(s)
    for i in range(1, len(s)):
        j = lps[i - 1]
        while j > 0 and s[i] != s[j]:
            j = lps[j - 1]
        if s[i] == s[j]:
            j += 1
        if j > len(after):
            j = 0
        lps[i] = j
    return lps[-1]


def slice_raw_window(before: str, after: str, offset: int) -> str:
    """Slice raw xray-access.log after a byte offset. Remap if the file rotated."""
    if offset < 0:
        return ""
    if after.startswith(before):
        return after[offset:] if offset <= len(after) else ""
    overlap = _suffix_prefix_overlap(before, after)
    cut = len(before) - overlap
    new_off = offset - cut
    if new_off < 0:
        return after
    if new_off <= len(after):
        return after[new_off:]
    return ""


def _first_json_object(text: str) -> dict | None:
    raw = (text or "").strip()
    if not raw:
        return None
    try:
        doc = json.loads(raw)
        return doc if isinstance(doc, dict) else None
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", raw, re.S)
    if not match:
        return None
    try:
        doc = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    return doc if isinstance(doc, dict) else None


def parse_google_http_helper(curl_out: str = "", tunprobe_out: str = "", rid: str = "") -> bool:
    """Strict HTTP 204 from curl status or the same JSON object's google fields."""
    curl = (curl_out or "").strip()
    if curl == "204" or re.search(r"^HTTP/[0-9.]+ 204\b", curl, re.M):
        return True
    doc = _first_json_object(tunprobe_out or "")
    if not doc:
        return False
    if rid and str(doc.get("rid") or "") not in ("", rid):
        return False
    if "googleHttp" in doc:
        google_http = doc.get("googleHttp")
        if google_http in (204, "204"):
            return True
        return False
    line = str(doc.get("googleLine") or "")
    if re.search(r"^HTTP/[0-9.]+ 204\b", line.strip()):
        return True
    return False


def assert_windows_no_overlap(windows: list[tuple[str, int, int]]) -> None:
    ordered = sorted(windows, key=lambda item: (item[1], item[2], item[0]))
    for i in range(1, len(ordered)):
        prev_name, prev_start, prev_end = ordered[i - 1]
        name, start, end = ordered[i]
        if start < prev_end:
            raise HdcError(
                ["overlap"],
                2,
                f"log overlap {prev_name}[{prev_start}:{prev_end}] {name}[{start}:{end}]",
            )


def parse_foreground_bundle(dump: str) -> str:
    text = dump or ""
    if not text.strip():
        raise HdcError(["foreground"], 2, "foreground dump empty")
    if "or BROWSER_BUNDLE" in text:
        raise HdcError(["foreground"], 2, "defaulted foreground bundle")
    focused = None
    for match in re.finditer(
        r'(?:focused["\s:=]+true.{0,400}?bundleName[:\s"=]+([a-zA-Z0-9_.]+)|bundleName[:\s"=]+([a-zA-Z0-9_.]+).{0,400}?focused["\s:=]+true)',
        text,
        re.I | re.S,
    ):
        focused = match.group(1) or match.group(2)
    if not focused:
        page_fg = re.findall(
            r"bundle name \[([a-zA-Z0-9_.]+)\]\s+ability type \[PAGE\]\s+state #FOREGROUND",
            text,
            re.I | re.S,
        )
        if BROWSER_BUNDLE in page_fg:
            focused = BROWSER_BUNDLE
        elif page_fg:
            focused = page_fg[-1]
    if not focused:
        raise HdcError(["foreground"], 2, "focused bundle unobserved")
    return focused


def parse_dns_helper(tunprobe_out: str = "", rid: str = "") -> bool:
    doc = _first_json_object(tunprobe_out or "")
    if not doc:
        return False
    if rid and str(doc.get("rid") or "") not in ("", rid):
        return False
    if doc.get("dnsOk") is True or doc.get("udp53") is True:
        return True
    dns_http = doc.get("dnsHttp")
    if dns_http in (0, "0") and "204" in json.dumps(doc):
        return False
    line = str(doc.get("dnsLine") or "")
    if re.search(r"^HTTP/[0-9.]+ 204\b", line.strip()):
        return True
    return bool(doc.get("dnsOk"))


def load_status(path: Path) -> dict:
    if not path.is_file():
        raise HdcError(["status"], 1, "status missing")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise HdcError(["status"], 1, f"status parse {exc}") from exc
