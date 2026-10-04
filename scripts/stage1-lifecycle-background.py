#!/usr/bin/env python3
"""Lifecycle oracle: home / Huawei browser / 30min screen-off must not freeze probes.

Does not start VPN. Requires an already-running session. Does not keep Index
in the foreground. HDC is the oracle, not the ACK path.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.accept_phases import SCREEN_OFF_SEC, screen_off_hold  # noqa: E402
from lib.extprobe import HdcError, hdc, recv_clean  # noqa: E402

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = "TEST_DEVICE_SERIAL"
BUNDLE = "com.oscarwoltz.tongdao"
BROWSER = "com.huawei.hmos.browser"
FILES = f"/data/app/el2/100/base/{BUNDLE}/haps/entry/files"
EVID = ROOT / "evidence/20260903-r1-baseline/lifecycle-background"


def run_hdc(*args: str, timeout: int = 40) -> str:
    def runner(full, to):
        import subprocess

        return subprocess.run(list(full), capture_output=True, timeout=to)

    return hdc([HDC, "-t", SERIAL, *args], timeout=timeout, runner=runner)


def _serial_runner(args, timeout):
    import subprocess

    cmd = list(args)
    if cmd and str(cmd[0]).endswith("hdc") and "-t" not in cmd:
        cmd = [cmd[0], "-t", SERIAL, *cmd[1:]]
    elif not cmd or not str(cmd[0]).endswith("hdc"):
        cmd = [HDC, "-t", SERIAL, *cmd]
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


def pull_json(name: str, dest: Path) -> dict:
    raw = recv_clean(f"{FILES}/{name}", dest, runner=_serial_runner)
    return json.loads(raw)


def status() -> dict:
    return pull_json("dataplane-status.json", Path("/tmp/life-status.json"))


def keepalive() -> dict:
    try:
        return pull_json("background-keepalive.json", Path("/tmp/life-keep.json"))
    except (HdcError, json.JSONDecodeError):
        return {}


def main() -> int:
    if __import__("os").environ.get("TONGDAO_DEVICE") != "1":
        print(json.dumps({"ok": False, "reason": "device_run_gated", "note": "真机写入未授权；只做主机检查。"}))
        return 2
    hold = int(__import__("os").environ.get("SCREEN_OFF_SEC", str(SCREEN_OFF_SEC)))
    EVID.mkdir(parents=True, exist_ok=True)
    rec: dict = {"ok": False, "fails": [], "holdSec": hold}
    try:
        rec["device"] = run_hdc("shell", "param get const.product.model").strip()
        if "ALT-AL10" not in rec["device"]:
            raise HdcError(["model"], 2, rec["device"])
        before = status()
        rec["before"] = {
            "generation": before.get("generation"),
            "phase": before.get("phase"),
            "lastProvenRid": before.get("lastProvenRid"),
            "evidenceAt": before.get("evidenceAt"),
        }
        if before.get("phase") not in ("CANARY_OK", "UNPROVEN", "DEGRADED_UNPROVEN", "FORWARDER_RUNNING"):
            raise HdcError(["vpn"], 2, f"vpn not live phase={before.get('phase')}")
        gen = str(before.get("generation") or "")
        rid0 = str(before.get("lastProvenRid") or "")
        run_hdc("shell", "aa", "start", "-b", BROWSER, "-A", "ohos.want.action.viewData",
                "-U", "https://www.google.com/generate_204?rid=life-browser")
        time.sleep(2)
        rec["afterBrowserKeep"] = keepalive()
        rec["afterBrowserStatus"] = {
            "phase": status().get("phase"),
            "generation": status().get("generation"),
        }
        if str(status().get("generation") or "") != gen:
            rec["fails"].append("generation changed after opening browser")

        def poll() -> None:
            import subprocess

            subprocess.run([HDC, "list", "targets"], capture_output=True, timeout=20)

        def read_screen() -> str:
            return run_hdc("shell", "hidumper -s PowerManagerService") + run_hdc(
                "shell", "hidumper -s DisplayManagerService"
            )

        def alive() -> int:
            keep = keepalive()
            if keep.get("ok") is not True:
                raise HdcError(["keep"], 2, f"keepalive not ok {keep}")
            return int(keep.get("progress") or 0)

        rec["screen"] = screen_off_hold(
            run=run_hdc, seconds=hold, poll=poll, read_screen=read_screen, alive_fn=alive
        )
        after = status()
        rec["after"] = {
            "generation": after.get("generation"),
            "phase": after.get("phase"),
            "lastProvenRid": after.get("lastProvenRid"),
            "evidenceAt": after.get("evidenceAt"),
        }
        rec["keepalive"] = keepalive()
        if str(after.get("generation") or "") != gen:
            rec["fails"].append("generation changed during screen-off; VPN restarted")
        rid1 = str(after.get("lastProvenRid") or "")
        if not rid1 or rid1 == rid0:
            rec["fails"].append(f"no new RID during background hold last={rid0} now={rid1}")
        if int(after.get("evidenceAt") or 0) <= int(before.get("evidenceAt") or 0):
            rec["fails"].append("evidenceAt did not advance")
        keep = rec.get("keepalive") or {}
        if keep.get("ok") is not True:
            rec["fails"].append(
                f"background keep-alive not ok code={keep.get('errorCode')} err={keep.get('error')}"
            )
        rec["ok"] = len(rec["fails"]) == 0
    except HdcError as exc:
        rec["fails"].append(str(exc))
        rec["ok"] = False
    (EVID / "lifecycle.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"ok": rec["ok"], "fails": rec["fails"], "holdSec": hold}, ensure_ascii=False))
    return 0 if rec["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
