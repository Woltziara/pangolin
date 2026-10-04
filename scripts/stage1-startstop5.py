#!/usr/bin/env python3
"""Five real VPN start/stop cycles on Mate X5. All five are the denominator."""
from __future__ import annotations

import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.extprobe import HdcError, hdc, recv_clean  # noqa: E402
from lib.vpn_cycle import find_button_center, wait_canary_commit, wait_stopped  # noqa: E402

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = "TEST_DEVICE_SERIAL"
BUNDLE = "com.oscarwoltz.tongdao"
FILES = f"/data/app/el2/100/base/{BUNDLE}/haps/entry/files"
OUT_DIR = ROOT / "evidence/20260903-r1-baseline/startstop5-attempts"


def run_hdc(*args: str, timeout: int = 40) -> str:
    cmd = [HDC, "-t", SERIAL, *args]

    def runner(full, to):
        return subprocess.run(list(full), capture_output=True, timeout=to)

    return hdc(cmd, timeout=timeout, runner=runner)


def _serial_runner(args, timeout):
    cmd = list(args)
    if cmd and str(cmd[0]).endswith("hdc") and "-t" not in cmd:
        cmd = [cmd[0], "-t", SERIAL, *cmd[1:]]
    elif not cmd or not str(cmd[0]).endswith("hdc"):
        cmd = [HDC, "-t", SERIAL, *cmd]
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


def status() -> dict:
    recv_clean(f"{FILES}/dataplane-status.json", Path("/tmp/ss-status.json"), runner=_serial_runner)
    return json.loads(Path("/tmp/ss-status.json").read_text(encoding="utf-8"))


def commit_doc() -> dict:
    try:
        raw = recv_clean(f"{FILES}/probe-commit.json", Path("/tmp/ss-commit.json"), runner=_serial_runner)
        return json.loads(raw)
    except (HdcError, json.JSONDecodeError):
        return {}


def tun() -> str:
    return run_hdc("shell", "grep vpn-tun /proc/net/dev || echo no-tun").strip()


def vpn_pid() -> str:
    out = run_hdc("shell", "ps -A")
    for line in out.splitlines():
        if "tongdao:vpn" in line and "grep" not in line:
            return line.split()[0]
    return ""


def native_stats() -> dict:
    st = status()
    rec: dict = {}
    try:
        raw = recv_clean(f"{FILES}/native-stats.json", Path("/tmp/ss-native-stats.json"), runner=_serial_runner)
        rec = json.loads(raw)
    except (HdcError, json.JSONDecodeError):
        rec = {}
    return {
        "xrayRunning": bool(rec.get("xrayRunning", st.get("xrayRunning"))),
        "tunRunning": bool(rec.get("tunRunning", st.get("forwarderOk"))),
        "poisoned": bool(rec.get("poisoned", st.get("nativePoisoned"))),
    }


def dump_layout() -> str:
    run_hdc("shell", "uitest dumpLayout -p /data/local/tmp/ss-layout.json")
    return recv_clean("/data/local/tmp/ss-layout.json", Path("/tmp/ss-layout.json"), runner=_serial_runner)


def click_label(label: str) -> tuple[int, int]:
    x, y = find_button_center(dump_layout(), label)
    run_hdc("shell", "uitest", "uiInput", "click", str(x), str(y))
    return x, y


def ensure_ui() -> None:
    run_hdc("shell", "power-shell", "wakeup")
    run_hdc("shell", "aa", "start", "-b", BUNDLE, "-a", "EntryAbility")
    time.sleep(1.5)


def start_vpn(generation: str) -> None:
    ensure_ui()
    run_hdc(
        "shell",
        "aa",
        "start",
        "-b",
        BUNDLE,
        "-a",
        "TunnelVpnAbility",
        "-C",
        "mode",
        "full",
        "-C",
        "generation",
        generation,
    )


def stop_vpn(generation: str) -> None:
    ensure_ui()
    run_hdc(
        "shell",
        "aa",
        "start",
        "-b",
        BUNDLE,
        "-a",
        "TunnelVpnAbility",
        "-C",
        "command",
        "stop",
        "-C",
        "generation",
        generation,
    )


def main() -> int:
    if __import__("os").environ.get("TONGDAO_DEVICE") != "1":
        print(json.dumps({"ok": False, "reason": "device_run_gated", "note": "真机写入未授权；只做主机检查。"}))
        return 2
    model = run_hdc("shell", "param get const.product.model").strip()
    if "ALT-AL10" not in model:
        raise SystemExit(f"not X5: {model}")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex
    results: list[dict] = []
    for i in range(1, 6):
        rec: dict = {"cycle": i, "ok": False, "fails": [], "runId": run_id}
        attempt = OUT_DIR / f"{run_id}-c{i}"
        attempt.mkdir(parents=True, exist_ok=True)
        rec["attemptDir"] = str(attempt)
        try:
            before = status()
            rec["before"] = {
                "generation": str(before.get("generation") or ""),
                "phase": str(before.get("phase") or ""),
                "commandEpoch": int(before.get("commandEpoch") or 0),
                "tun": tun(),
                "vpnPid": vpn_pid(),
            }
            new_gen = f"ss{i}-{int(time.time())}-{uuid.uuid4().hex[:6]}"
            rec["startGeneration"] = new_gen
            start_vpn(new_gen)
            rec["started"] = True
            live = wait_canary_commit(
                status_fn=status,
                commit_fn=commit_doc,
                old_generation=str(rec["before"]["generation"]),
                requested_generation=new_gen,
                timeout=45,
            )
            if str(live["status"].get("generation") or "") != new_gen:
                rec["fails"].append(f"generation {live['status'].get('generation')} != {new_gen}")
            rec["live"] = {
                "generation": live["status"].get("generation"),
                "phase": live["status"].get("phase"),
                "lastProvenRid": live["status"].get("lastProvenRid"),
                "commitRid": live["commit"].get("rid"),
            }
            ext = subprocess.run(
                [sys.executable, str(ROOT / "scripts/stage1-extprobe.py")],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                timeout=180,
            )
            rec["extprobeRc"] = ext.returncode
            if ext.returncode != 0:
                rec["fails"].append(f"extprobe_rc={ext.returncode} {(ext.stdout or '')[-300:]}")
            else:
                parsed = json.loads(ext.stdout.strip().splitlines()[-1])
                rec["extprobe"] = parsed
                if not parsed.get("ok"):
                    rec["fails"].append(str(parsed.get("reason") or "extprobe_not_ok"))
                if not parsed.get("browserGoogle") or not parsed.get("browserDirect") or not parsed.get("browserUdp"):
                    rec["fails"].append("browser_subwindows_incomplete")
            live_gen = str(live["status"].get("generation") or new_gen)
            live_epoch = int(live["status"].get("commandEpoch") or 0)
            rec["stopped"] = True
            stop_vpn(live_gen)
            gone = wait_stopped(
                status_fn=status,
                tun_fn=tun,
                pid_fn=vpn_pid,
                old_generation=live_gen,
                old_epoch=live_epoch,
                timeout=20,
                native_fn=native_stats,
            )
            rec["afterStop"] = {
                "phase": gone["status"].get("phase"),
                "tun": gone["tun"],
                "vpnPid": gone["pid"],
                "commandEpoch": gone["status"].get("commandEpoch"),
            }
            if gone["status"].get("phase") != "STOPPED":
                rec["fails"].append(f"stop_phase {gone['status'].get('phase')}")
            if int(gone["status"].get("commandEpoch") or 0) <= live_epoch:
                rec["fails"].append("stop_epoch_not_advanced")
        except (HdcError, json.JSONDecodeError, subprocess.TimeoutExpired, IndexError) as exc:
            rec["fails"].append(str(exc))
            rec["started"] = bool(rec.get("started"))
            rec["stopped"] = bool(rec.get("stopped"))
        rec["ok"] = len(rec["fails"]) == 0 and bool(rec.get("started")) and bool(rec.get("stopped"))
        (attempt / "cycle.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
        results.append(rec)
        print(
            json.dumps({"cycle": i, "ok": rec["ok"], "fails": rec["fails"], "started": rec.get("started"), "stopped": rec.get("stopped")}, ensure_ascii=False),
            flush=True,
        )
        time.sleep(2)
    summary = {
        "device": "ALT-AL10",
        "runId": run_id,
        "ok": sum(1 for r in results if r["ok"]),
        "fail": sum(1 for r in results if not r["ok"]),
        "denominator": 5,
        "cycles": results,
        "counts_as_5x": len(results) == 5 and all(r.get("ok") for r in results),
    }
    (OUT_DIR / f"{run_id}-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print("SUMMARY", summary["ok"], "ok", summary["fail"], "fail", "denom=5", flush=True)
    return 0 if summary["counts_as_5x"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
