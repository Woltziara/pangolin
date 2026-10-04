#!/usr/bin/env python3
"""Retired overlapping oracle. The narrow loop is stage1-loop.py."""
from __future__ import annotations

import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.extprobe import (  # noqa: E402
    BROWSER_BUNDLE,
    HdcError,
    WindowEvidence,
    classify_window,
    evaluate_window,
    hdc,
    lan_direct_line_set,
    lan_proxy_line_set,
    new_access_text,
    parse_foreground_bundle,
    parse_tun,
    parse_wlan_gateway,
    recv_clean,
    slice_raw_window,
    udp53_line_set,
)
from lib.hdc_singleton import DuplicateWaiter, acquire, release  # noqa: E402
from lib.stage1_loop import parse_http_status_line  # noqa: E402

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = "TEST_DEVICE_SERIAL"
FILES = "/data/app/el2/100/base/com.oscarwoltz.tongdao/haps/entry/files"
EVID = ROOT / "evidence/20260903-r1-baseline"
ATTEMPTS = EVID / "extprobe-attempts"
LOCK = EVID / "extprobe-attempt.lock"
BUNDLE = "com.oscarwoltz.tongdao"


def run_hdc(*args: str, timeout: int = 40) -> str:
    cmd = [HDC, "-t", SERIAL, *args]

    def runner(full, to):
        import subprocess

        return subprocess.run(list(full), capture_output=True, timeout=to)

    return hdc(cmd, timeout=timeout, runner=runner)


def tun_line() -> str:
    return run_hdc("shell", "grep vpn-tun /proc/net/dev || echo no-tun").strip()


def _serial_runner(args, timeout):
    import subprocess

    cmd = list(args)
    if cmd and cmd[0].endswith("hdc"):
        full = cmd
        if "-t" not in full:
            full = [full[0], "-t", SERIAL, *full[1:]]
    else:
        full = [HDC, "-t", SERIAL, *cmd]
    return subprocess.run(full, capture_output=True, timeout=timeout)


def pull_status(dest: Path) -> dict:
    recv_clean(f"{FILES}/dataplane-status.json", dest, runner=_serial_runner)
    try:
        return json.loads(dest.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise HdcError(["status"], 1, f"parse {exc}") from exc


def snapshot(dest: Path) -> dict:
    st = pull_status(dest)
    line = tun_line()
    counters = parse_tun(line)
    return {
        "tun": line,
        "tunCounters": counters,
        "generation": st.get("generation"),
        "sessionRevision": int(st.get("sessionRevision") or 0),
        "phase": st.get("phase"),
        "uploadBytes": st.get("uploadBytes"),
        "downloadBytes": st.get("downloadBytes"),
        "tunRxBytes": st.get("tunRxBytes"),
        "tunTxBytes": st.get("tunTxBytes"),
        "at": st.get("at"),
        "evidenceRid": str(st.get("evidenceRid") or ""),
        "probeRevision": int(st.get("probeRevision") or 0),
        "accessOffset": int(st.get("accessOffset") or -1),
        "evidenceAt": int(st.get("evidenceAt") or 0),
        "probeEpoch": int(st.get("probeEpoch") or 0),
        "lastProvenRid": str(st.get("lastProvenRid") or ""),
        "commandEpoch": int(st.get("commandEpoch") or 0),
        "raw": st,
    }


def pull_access(dest: Path) -> str:
    try:
        return recv_clean(f"{FILES}/xray-access-pub.log", dest, runner=_serial_runner)
    except HdcError:
        return recv_clean(f"{FILES}/xray-access.log", dest, runner=_serial_runner)


def dump_texts() -> list[str]:
    run_hdc("shell", "uitest dumpLayout -p /data/local/tmp/ext.json")
    dest = Path("/tmp/ext.json")
    recv_clean("/data/local/tmp/ext.json", dest, runner=_serial_runner)
    raw = dest.read_text(encoding="utf-8", errors="replace")
    texts: list[str] = []
    for t in re.findall(r'"text":"([^"]*)"', raw):
        if t and t not in texts and len(t) < 120:
            texts.append(t)
    return texts


def proc_uid(pid: str) -> str:
    if not pid or pid == "0":
        raise HdcError(["uid"], 2, "pid missing")
    out = run_hdc("shell", f"cat /proc/{pid}/status 2>/dev/null | grep -i '^Uid:'")
    nums = re.findall(r"\d+", out)
    if not nums:
        raise HdcError(["uid"], 2, f"uid unobserved pid={pid}")
    return nums[0]


def foreground_bundle() -> str:
    out = run_hdc("shell", "aa dump -a")
    got = parse_foreground_bundle(out)
    if got != BROWSER_BUNDLE:
        raise HdcError(["foreground"], 2, f"focused bundle {got} not browser")
    return got


def recv_json(remote: str, dest: Path) -> dict:
    raw = recv_clean(remote, dest, runner=_serial_runner)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HdcError(["json"], 1, f"parse {exc}") from exc


_LOCK_PID = 0
_LOCK_TOKEN = ""


def acquire_attempt_lock(token: str) -> None:
    global _LOCK_PID, _LOCK_TOKEN
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    try:
        holder, got = acquire(LOCK, os.getpid())
    except DuplicateWaiter as exc:
        raise HdcError(["attempt-lock"], 3, f"extprobe already running {exc.holder}") from exc
    _LOCK_PID = holder
    _LOCK_TOKEN = got
    if token and got:
        (LOCK.parent / "extprobe-attempt.token").write_text(f"{token}\n{got}\n")


def release_attempt_lock(token: str) -> None:
    global _LOCK_PID, _LOCK_TOKEN
    if _LOCK_TOKEN:
        release(LOCK, _LOCK_PID, _LOCK_TOKEN)
    _LOCK_PID = 0
    _LOCK_TOKEN = ""


def seal(attempt_dir: Path, rec: dict) -> None:
    attempt_dir.mkdir(parents=True, exist_ok=True)
    (attempt_dir / "extprobe.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
    ATTEMPTS.mkdir(parents=True, exist_ok=True)
    (EVID / "extprobe.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")


def open_browser(url: str) -> None:
    last = "unobserved"
    run_hdc("shell", "power-shell wakeup")
    for _ in range(6):
        run_hdc(
            "shell",
            "aa",
            "start",
            "-b",
            BROWSER_BUNDLE,
            "-A",
            "ohos.want.action.viewData",
            "-U",
            url,
        )
        time.sleep(2)
        dump = run_hdc("shell", "aa dump -a")
        try:
            got = parse_foreground_bundle(dump)
        except HdcError as exc:
            last = str(exc)
            continue
        if got == BROWSER_BUNDLE:
            return
        last = got
    raise HdcError(["foreground"], 2, f"focused bundle {last} not browser")


def subwindow(attempt_dir: Path, name: str) -> tuple[dict, str]:
    snap = snapshot(attempt_dir / f"{name}-before.json")
    access = pull_access(attempt_dir / f"{name}-access-before.log")
    return snap, access


def wait_tagged_window(
    attempt_dir: Path,
    name: str,
    before_snap: dict,
    before_access: str,
    tag_ok,
    timeout: float = 25,
) -> dict:
    deadline = time.time() + timeout
    win: dict = {}
    while time.time() < deadline:
        win = finish_subwindow(attempt_dir, name, before_snap, before_access)
        after_access = (attempt_dir / f"{name}-access-after.log").read_text(
            encoding="utf-8", errors="replace"
        )
        delta = new_access_text(before_access, after_access)
        if delta.strip():
            win["window"] = delta
            win["tags"] = classify_window(delta, "")
        if tag_ok(win.get("tags") or {}):
            return win
        time.sleep(2)
    return win


def finish_subwindow(attempt_dir: Path, name: str, before_snap: dict, before_access: str) -> dict:
    after_access = pull_access(attempt_dir / f"{name}-access-after.log")
    after_snap = snapshot(attempt_dir / f"{name}-after.json")
    offset = len(before_access)
    window = slice_raw_window(before_access, after_access, offset)
    if not window.strip():
        window = new_access_text(before_access, after_access)
    tb = before_snap.get("tunCounters") or {}
    ta = after_snap.get("tunCounters") or {}
    return {
        "before": before_snap,
        "after": after_snap,
        "window": window,
        "tags": classify_window(window, ""),
        "tun_rx_before": int(tb.get("rxBytes") or 0),
        "tun_rx_after": int(ta.get("rxBytes") or 0),
        "tun_tx_before": int(tb.get("txBytes") or 0),
        "tun_tx_after": int(ta.get("txBytes") or 0),
        "hev_up_before": int(before_snap.get("uploadBytes") or 0),
        "hev_up_after": int(after_snap.get("uploadBytes") or 0),
        "hev_down_before": int(before_snap.get("downloadBytes") or 0),
        "hev_down_after": int(after_snap.get("downloadBytes") or 0),
        "generation": str(after_snap.get("generation") or ""),
        "revision": int(after_snap.get("sessionRevision") or 0),
        "generation_before": str(before_snap.get("generation") or ""),
        "generation_after": str(after_snap.get("generation") or ""),
        "revision_before": int(before_snap.get("sessionRevision") or 0),
        "revision_after": int(after_snap.get("sessionRevision") or 0),
        "access_offset": offset,
    }


def main() -> int:
    if os.environ.get("TONGDAO_DEVICE") != "1":
        print(json.dumps({"ok": False, "reason": "device_run_gated", "note": "真机写入未授权；只做主机检查。"}))
        return 2
    rid = f"p{int(time.time())}-{uuid.uuid4().hex[:10]}"
    token = rid
    attempt_dir = ATTEMPTS / rid
    attempt_dir.mkdir(parents=True, exist_ok=True)
    rec: dict = {
        "rid": rid,
        "attemptId": rid,
        "attemptDir": str(attempt_dir),
        "googleRid": f"{rid}-g",
        "directRid": f"{rid}-d",
        "udpRid": f"{rid}-u",
        "lanRid": f"{rid}-lan",
        "googleUrl": f"https://www.google.com/generate_204?rid={rid}-g",
        "directUrl": f"https://www.qq.com/?rid={rid}-d",
        "udpQname": f"{rid}-u.google.com",
        "browserBundle": BROWSER_BUNDLE,
        "role": "oracle",
        "note": "Does not write probe-request.json. Production commit is required; browser subwindows are separate.",
    }
    try:
        acquire_attempt_lock(token)
        run_hdc("shell", "power-shell wakeup")
        run_hdc("shell", f"rm -f {FILES}/oracle-hold.json")
        rec["device"] = run_hdc("shell", "param get const.product.model").strip()
        rec["before"] = snapshot(attempt_dir / "status-before.json")
        rec["beforeAccess"] = pull_access(attempt_dir / "access-before.log")
        rec["utcStart"] = time.strftime("%Y/%m/%d %H:%M:%S", time.gmtime())
        commit: dict = {}
        issued: dict = {}
        after = rec["before"]
        for _ in range(40):
            try:
                issued = recv_json(f"{FILES}/probe-issued.json", attempt_dir / "probe-issued.json")
            except HdcError:
                issued = {}
            try:
                commit = recv_json(f"{FILES}/probe-commit.json", attempt_dir / "probe-commit.json")
            except HdcError:
                commit = {}
            after = snapshot(attempt_dir / "status-pending.json")
            if (
                str(commit.get("kind") or "") == "commit"
                and commit.get("rid")
                and commit.get("rid") == after.get("lastProvenRid")
                and after.get("phase") == "CANARY_OK"
                and int(after.get("evidenceAt") or 0) > int(rec["before"].get("evidenceAt") or 0)
                and str(issued.get("kind") or "") == "issued"
                and issued.get("rid") == commit.get("rid")
            ):
                break
            time.sleep(1)
        rec["issuedDoc"] = issued
        rec["commitDoc"] = commit
        rec["afterProduction"] = after
        if str(commit.get("kind") or "") != "commit":
            raise HdcError(["probe-commit"], 2, "production commit missing")
        prod_rid = str(commit.get("rid") or "")
        rec["productionRid"] = prod_rid
        if prod_rid == rid:
            raise HdcError(["isolation"], 2, "browser rid reused production rid")
        rec["clashbox"] = run_hdc("shell", "pidof org.xbgroup.clashboxLTS || echo clashbox-absent").strip()
        try:
            rec["fetchDoc"] = recv_json(f"{FILES}/probe-fetch.json", attempt_dir / "probe-fetch.json")
        except HdcError as exc:
            raise HdcError(["probe-fetch"], 2, "production fetch ack missing") from exc
        prod = evaluate_window(
            WindowEvidence(
                rid=prod_rid,
                generation_before=str(rec["before"].get("generation") or ""),
                generation_after=str(after.get("generation") or ""),
                revision_before=int(rec["before"].get("sessionRevision") or 0),
                revision_after=int(after.get("sessionRevision") or 0),
                tun_rx_before=int((rec["before"].get("tunCounters") or {}).get("rxBytes") or 0),
                tun_rx_after=int(commit.get("tunRxBytes") or 0),
                tun_tx_before=int((rec["before"].get("tunCounters") or {}).get("txBytes") or 0),
                tun_tx_after=int(commit.get("tunTxBytes") or 0),
                hev_up_before=int(rec["before"].get("uploadBytes") or 0),
                hev_up_after=int(commit.get("hevUp") or 0),
                hev_down_before=int(rec["before"].get("downloadBytes") or 0),
                hev_down_after=int(commit.get("hevDown") or 0),
                tags=classify_window(
                    pull_access(attempt_dir / "access-at-commit.log"),
                    prod_rid,
                ),
                access_offset=int(commit.get("rawCursor") or -1),
                probe_revision=int(commit.get("revision") or 0),
                consumed=True,
                evidence_rid=str(after.get("evidenceRid") or ""),
                consumed_rid=prod_rid,
                google_http_status=int(commit.get("fetchGoogleHttp") or 0),
                direct_http_status=int(commit.get("fetchDirectHttp") or 0),
                dns_helper=bool(commit.get("fetchDnsOk")),
                consumed_generation=str(commit.get("generation") or ""),
                consumed_revision=int(commit.get("revision") or 0),
                consumed_access_offset=int(commit.get("accessOffset") or -1),
                consumed_epoch=int(commit.get("epoch") or -1),
                consumed_at=int(commit.get("at") or 0),
                consumed_raw_cursor=int(commit.get("rawCursor") or -1),
                purpose="production",
                commit_kind=str(commit.get("kind") or ""),
                status_phase=str(after.get("phase") or ""),
                last_proven_rid=str(after.get("lastProvenRid") or ""),
            )
        )
        rec["production"] = prod
        if not prod.get("ok"):
            raise HdcError(["production"], 2, str(prod.get("reason")))
        run_hdc("shell", f"echo '{{\"hold\":true,\"rid\":\"{rid}\"}}' > {FILES}/oracle-hold.json")

        g_rid = rec["googleRid"]
        g_before, g_access = subwindow(attempt_dir, "browser-google")
        open_browser(rec["googleUrl"])
        time.sleep(6)
        rec["observedBrowserBundle"] = foreground_bundle()
        rec["browserPid"] = run_hdc("shell", "pidof com.huawei.hmos.browser").strip().split()[0]
        rec["tongdaoPid"] = run_hdc("shell", "pidof com.oscarwoltz.tongdao").strip().split()[0]
        if not rec["browserPid"] or rec["browserPid"] == rec["tongdaoPid"]:
            raise HdcError(["browser-pid"], 2, "browser pid not independent")
        rec["browserUid"] = proc_uid(str(rec["browserPid"]))
        rec["tongdaoUid"] = proc_uid(str(rec["tongdaoPid"]))
        g_texts = dump_texts()
        g_blob = json.dumps(g_texts, ensure_ascii=False)
        http_code, http_src = parse_http_status_line("\n".join(g_texts))
        rec["google"] = {
            "texts": g_texts[:12],
            "error": any("无法打开" in x or "暂无响应" in x for x in g_texts),
            "dumpHasRid": g_rid in g_blob,
            "contentOk": False,
            "httpStatus": http_code,
            "httpSource": http_src,
            "httpRaw": "",
            "bundle": rec["observedBrowserBundle"],
            "dumpObservationalOnly": http_src != "http-status-line",
        }
        rec["googleWindow"] = wait_tagged_window(
            attempt_dir,
            "browser-google",
            g_before,
            g_access,
            lambda tags: bool(tags.get("googleProxy")),
        )
        g_verdict = evaluate_window(
            WindowEvidence(
                rid=g_rid,
                generation_before=rec["googleWindow"]["generation_before"],
                generation_after=rec["googleWindow"]["generation_after"],
                revision_before=rec["googleWindow"]["revision_before"],
                revision_after=rec["googleWindow"]["revision_after"],
                tun_rx_before=rec["googleWindow"]["tun_rx_before"],
                tun_rx_after=rec["googleWindow"]["tun_rx_after"],
                tun_tx_before=rec["googleWindow"]["tun_tx_before"],
                tun_tx_after=rec["googleWindow"]["tun_tx_after"],
                hev_up_before=rec["googleWindow"]["hev_up_before"],
                hev_up_after=rec["googleWindow"]["hev_up_after"],
                hev_down_before=rec["googleWindow"]["hev_down_before"],
                hev_down_after=rec["googleWindow"]["hev_down_after"],
                tags=rec["googleWindow"]["tags"],
                page_error=bool(rec["google"]["error"]),
                google_page_ok=bool(rec["google"]["contentOk"]),
                page_content_ok=bool(rec["google"]["contentOk"]),
                dump_has_rid=bool(rec["google"]["dumpHasRid"]),
                access_offset=rec["googleWindow"]["access_offset"],
                probe_revision=rec["googleWindow"]["revision"],
                consumed=True,
                evidence_rid=g_rid,
                consumed_rid=g_rid,
                google_http_status=int(rec["google"].get("httpStatus") or 0),
                production_rid=prod_rid,
                browser_http_source=str(rec["google"].get("httpSource") or "uitest-dump"),
                browser_pid=str(rec["browserPid"]),
                tongdao_pid=str(rec["tongdaoPid"]),
                browser_uid=str(rec["browserUid"]),
                tongdao_uid=str(rec["tongdaoUid"]),
                browser_bundle=BROWSER_BUNDLE,
                observed_browser_bundle=str(rec["observedBrowserBundle"]),
                consumed_generation=rec["googleWindow"]["generation"],
                consumed_revision=rec["googleWindow"]["revision"],
                consumed_access_offset=rec["googleWindow"]["access_offset"],
                consumed_raw_cursor=rec["googleWindow"]["access_offset"],
                consumed_epoch=int(after.get("probeEpoch") or 1),
                consumed_at=int(time.time() * 1000),
                purpose="browser_google",
            )
        )
        rec["googleVerdict"] = g_verdict
        if not g_verdict.get("ok"):
            raise HdcError(["browser-google"], 2, str(g_verdict.get("reason")))

        d_before, d_access = subwindow(attempt_dir, "browser-direct")
        open_browser(rec["directUrl"])
        time.sleep(6)
        rec["observedBrowserBundle"] = foreground_bundle()
        qq_texts = dump_texts()
        qq_blob = "".join(qq_texts)
        rec["qq"] = {
            "texts": qq_texts[:12],
            "error": any("无法打开" in x or "暂无响应" in x for x in qq_texts),
            "contentOk": any(x in qq_blob for x in ("腾讯", "新闻")) and "qq.com" in qq_blob.lower(),
            "dumpHasRid": rec["directRid"] in json.dumps(qq_texts, ensure_ascii=False),
        }
        rec["directWindow"] = wait_tagged_window(
            attempt_dir,
            "browser-direct",
            d_before,
            d_access,
            lambda tags: bool(tags.get("uniqueDirect")),
        )
        d_verdict = evaluate_window(
            WindowEvidence(
                rid=rec["directRid"],
                generation_before=rec["directWindow"]["generation_before"],
                generation_after=rec["directWindow"]["generation_after"],
                revision_before=rec["directWindow"]["revision_before"],
                revision_after=rec["directWindow"]["revision_after"],
                tun_rx_before=rec["directWindow"]["tun_rx_before"],
                tun_rx_after=rec["directWindow"]["tun_rx_after"],
                tun_tx_before=rec["directWindow"]["tun_tx_before"],
                tun_tx_after=rec["directWindow"]["tun_tx_after"],
                hev_up_before=rec["directWindow"]["hev_up_before"],
                hev_up_after=rec["directWindow"]["hev_up_after"],
                hev_down_before=rec["directWindow"]["hev_down_before"],
                hev_down_after=rec["directWindow"]["hev_down_after"],
                tags=rec["directWindow"]["tags"],
                page_error=bool(rec["qq"]["error"]),
                direct_page_ok=bool(rec["qq"]["contentOk"]),
                page_content_ok=bool(rec["qq"]["contentOk"]),
                dump_has_rid=bool(rec["qq"].get("dumpHasRid")),
                access_offset=rec["directWindow"]["access_offset"],
                probe_revision=rec["directWindow"]["revision"],
                consumed=True,
                evidence_rid=rec["directRid"],
                consumed_rid=rec["directRid"],
                production_rid=prod_rid,
                browser_pid=str(rec["browserPid"]),
                tongdao_pid=str(rec["tongdaoPid"]),
                browser_uid=str(rec["browserUid"]),
                tongdao_uid=str(rec["tongdaoUid"]),
                browser_bundle=BROWSER_BUNDLE,
                observed_browser_bundle=str(rec["observedBrowserBundle"]),
                consumed_generation=rec["directWindow"]["generation"],
                consumed_revision=rec["directWindow"]["revision"],
                consumed_access_offset=rec["directWindow"]["access_offset"],
                consumed_raw_cursor=rec["directWindow"]["access_offset"],
                consumed_epoch=int(after.get("probeEpoch") or 1),
                consumed_at=int(time.time() * 1000),
                purpose="browser_direct",
            )
        )
        rec["directVerdict"] = d_verdict
        if not d_verdict.get("ok"):
            raise HdcError(["browser-direct"], 2, str(d_verdict.get("reason")))

        u_before, u_access = subwindow(attempt_dir, "browser-udp")
        rec["udpUrl"] = f"https://{rec['udpQname']}/"
        open_browser(rec["udpUrl"])
        time.sleep(4)
        rec["observedBrowserBundle"] = foreground_bundle()
        rec["udpWindow"] = wait_tagged_window(
            attempt_dir,
            "browser-udp",
            u_before,
            u_access,
            lambda tags: bool(tags.get("udp53Proxy")),
        )
        u_after_access = (attempt_dir / "browser-udp-access-after.log").read_text(
            encoding="utf-8", errors="replace"
        )
        udp_delta = udp53_line_set(u_after_access) - udp53_line_set(u_access)
        rec["udpSent"] = f"new-udp53 {len(udp_delta)}"
        rec["udpDelta"] = sorted(udp_delta)[:8]
        udp_ok = bool(udp_delta)
        if udp_delta:
            rec["udpWindow"]["tags"] = classify_window("\n".join(sorted(udp_delta)), rec["udpRid"])
        u_verdict = evaluate_window(
            WindowEvidence(
                rid=rec["udpRid"],
                generation_before=rec["udpWindow"]["generation_before"],
                generation_after=rec["udpWindow"]["generation_after"],
                revision_before=rec["udpWindow"]["revision_before"],
                revision_after=rec["udpWindow"]["revision_after"],
                tun_rx_before=rec["udpWindow"]["tun_rx_before"],
                tun_rx_after=rec["udpWindow"]["tun_rx_after"],
                tun_tx_before=rec["udpWindow"]["tun_tx_before"],
                tun_tx_after=rec["udpWindow"]["tun_tx_after"],
                hev_up_before=rec["udpWindow"]["hev_up_before"],
                hev_up_after=rec["udpWindow"]["hev_up_after"],
                hev_down_before=rec["udpWindow"]["hev_down_before"],
                hev_down_after=rec["udpWindow"]["hev_down_after"],
                tags=rec["udpWindow"]["tags"],
                access_offset=rec["udpWindow"]["access_offset"],
                probe_revision=rec["udpWindow"]["revision"],
                consumed=True,
                evidence_rid=rec["udpRid"],
                consumed_rid=rec["udpRid"],
                consumed_generation=rec["udpWindow"]["generation_after"],
                consumed_revision=rec["udpWindow"]["revision_after"],
                consumed_access_offset=rec["udpWindow"]["access_offset"],
                consumed_raw_cursor=rec["udpWindow"]["access_offset"],
                consumed_epoch=int(after.get("probeEpoch") or 1),
                consumed_at=int(time.time() * 1000),
                purpose="browser_udp",
                production_rid=prod_rid,
                dns_query_sent=udp_ok,
                browser_pid=str(rec["browserPid"]),
                tongdao_pid=str(rec["tongdaoPid"]),
                browser_uid=str(rec["browserUid"]),
                tongdao_uid=str(rec["tongdaoUid"]),
                browser_bundle=BROWSER_BUNDLE,
                observed_browser_bundle=str(rec["observedBrowserBundle"]),
            )
        )
        rec["udpVerdict"] = u_verdict
        if not u_verdict.get("ok"):
            raise HdcError(["browser-udp"], 2, str(u_verdict.get("reason")))

        lan_before, lan_access = subwindow(attempt_dir, "lan")
        rec["ifconfig"] = run_hdc("shell", "ifconfig")
        gw = parse_wlan_gateway(str(rec["ifconfig"] or ""))
        rec["lanGateway"] = gw
        if not gw:
            raise HdcError(["lan"], 2, "lan gateway unobserved")
        rec["lanUrl"] = f"http://{gw}/?rid={rec['lanRid']}"
        open_browser(rec["lanUrl"])
        time.sleep(4)
        rec["observedBrowserBundle"] = foreground_bundle()
        rec["lanDump"] = dump_texts()
        lan_delta: set[str] = set()
        rec["lanWindow"] = {}
        lan_deadline = time.time() + 25
        while time.time() < lan_deadline:
            rec["lanWindow"] = finish_subwindow(attempt_dir, "lan", lan_before, lan_access)
            lan_after_access = (attempt_dir / "lan-access-after.log").read_text(
                encoding="utf-8", errors="replace"
            )
            lan_delta = lan_direct_line_set(lan_after_access, gw) - lan_direct_line_set(lan_access, gw)
            if lan_delta:
                break
            time.sleep(2)
        rec["lanDelta"] = sorted(lan_delta)[:8]
        lan_leak = lan_proxy_line_set(lan_after_access, gw)
        rec["lanLeak"] = sorted(lan_leak)[:8]
        # HarmonyOS keeps 192.168/16 on wlan0 (connected route), so LAN often
        # never enters vpn-tun. Pass if it DIRECT'd through TUN, or if it did
        # not leak to proxy while the Wi-Fi subnet is still there.
        rec["lanOk"] = bool(lan_delta) or (bool(gw) and not lan_leak)
        if not rec["lanOk"]:
            raise HdcError(["lan"], 2, "LAN gateway leaked to proxy")
        run_hdc("shell", f"rm -f {FILES}/oracle-hold.json")
    except HdcError as exc:
        rec["ok"] = False
        rec["hdcError"] = str(exc)
        rec["reason"] = "hdc_fail_closed"
        seal(attempt_dir, rec)
        print(json.dumps({"rid": rid, "ok": False, "hdcError": str(exc)}, ensure_ascii=False))
        release_attempt_lock(token)
        return 1
    finally:
        try:
            run_hdc("shell", f"rm -f {FILES}/oracle-hold.json")
        except Exception:
            pass
        release_attempt_lock(token)

    rec["ok"] = (
        rec["device"].startswith("ALT-AL10")
        and "clashbox-absent" in rec["clashbox"]
        and bool(rec["production"].get("ok"))
        and bool(rec["googleVerdict"].get("ok"))
        and bool(rec["directVerdict"].get("ok"))
        and bool(rec["udpVerdict"].get("ok"))
        and bool(rec.get("lanOk"))
    )
    rec["reason"] = "" if rec["ok"] else "oracle_incomplete"
    seal(attempt_dir, rec)
    print(
        json.dumps(
            {
                "rid": rid,
                "productionRid": rec.get("productionRid"),
                "ok": rec["ok"],
                "reason": rec.get("reason"),
                "attemptDir": str(attempt_dir),
                "production": rec["production"].get("ok"),
                "browserGoogle": rec["googleVerdict"].get("ok"),
                "browserDirect": rec["directVerdict"].get("ok"),
                "browserUdp": rec["udpVerdict"].get("ok"),
            },
            ensure_ascii=False,
        )
    )
    return 0 if rec["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
