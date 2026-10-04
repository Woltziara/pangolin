#!/usr/bin/env python3
"""One cold ChatGPT -> Google auth visit on the connected Mate X5."""
import json
import subprocess
import sys
import time
from pathlib import Path

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = "TEST_DEVICE_SERIAL"
DEVECOCLI = "/path/to/user/.npm-global/bin/devecocli"
ROOT = Path(__file__).resolve().parents[1]
EVID = ROOT / "evidence" / "20260902-accept-a"
LAYOUT = Path("/data/local/tmp/accept-layout.json")
LOCAL = Path("/tmp/accept-layout.json")


def sh(*args, timeout=30):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def hdc(*args, timeout=30):
    return sh(HDC, "-t", SERIAL, *args, timeout=timeout)


def dump_texts():
    hdc("shell", f"uitest dumpLayout -p {LAYOUT}")
    hdc("file", "recv", str(LAYOUT), str(LOCAL))
    data = json.loads(LOCAL.read_text(encoding="utf-8"))
    texts = []

    def walk(n):
        if isinstance(n, dict):
            t = (n.get("text") or "").strip()
            if t:
                texts.append((t, n.get("bounds"), n.get("type")))
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for i in n:
                walk(i)

    walk(data)
    return texts


def click_xy(x, y):
    hdc("shell", "uitest", "uiInput", "click", str(x), str(y))


def center(bounds):
    body = bounds.strip("[]").split("][")
    x1, y1 = map(int, body[0].split(","))
    x2, y2 = map(int, body[1].split(","))
    return (x1 + x2) // 2, (y1 + y2) // 2


def screenshot(name):
    path = EVID / name
    sh(DEVECOCLI, "ui", "screenshot", "--device", SERIAL, "--path", str(path), timeout=20)
    return path


def tun():
    code, out = hdc("shell", "cat /proc/net/dev")
    for line in out.splitlines():
        if "vpn-tun" in line:
            return line.strip()
    return "no vpn-tun"


def has(texts, *keys):
    blob = " ".join(t[0] for t in texts)
    return any(k in blob for k in keys)


def click_text(texts, needle, prefer_types=None):
    for t, b, ty in texts:
        if needle in t and b:
            if prefer_types and ty not in prefer_types:
                continue
            x, y = center(b)
            # Google button is clipped at webview top; keep click inside bounds.
            click_xy(x, y)
            return True, t, b
    return False, "", ""


def run_visit(n: int) -> dict:
    EVID.mkdir(parents=True, exist_ok=True)
    rec = {"n": n, "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "steps": []}
    rec["tun_before"] = tun()
    hdc("shell", "aa", "start", "-b", "com.huawei.hmos.browser", "-a", "MainAbility",
        "-U", "https://chatgpt.com")
    texts = []
    for _ in range(10):
        time.sleep(4)
        texts = dump_texts()
        if has(texts, "请验证您是真人", "正在验证"):
            click_text(texts, "请验证您是真人")
            rec["steps"].append("homepage cloudflare")
            continue
        if has(texts, "登录", "使用 Google 账户继续", "你想做点什么"):
            break
    rec["after_open"] = [t[0] for t in texts][:20]
    screenshot(f"visit{n}-open.png")

    if has(texts, "使用 Google 账户继续"):
        rec["steps"].append("login sheet already")
    elif has(texts, "登录"):
        for attempt in range(3):
            click_xy(950, 390)
            rec["steps"].append(f"clicked 登录 attempt {attempt+1}")
            time.sleep(5)
            texts = dump_texts()
            if has(texts, "使用 Google 账户继续"):
                break
    else:
        rec["steps"].append("no login control")
        rec["result"] = "FAIL no login"
        return rec

    if not has(texts, "使用 Google 账户继续"):
        rec["result"] = "FAIL no google continue"
        rec["texts"] = [t[0] for t in texts]
        screenshot(f"visit{n}-nogoogle.png")
        return rec

    # Prefer the visually first Google button. Clipped bounds sit at y~766-802.
    ok, label, bounds = click_text(texts, "使用 Google 账户继续")
    rec["steps"].append(f"clicked {label} {bounds}")
    texts = []
    for _ in range(8):
        time.sleep(4)
        texts = dump_texts()
        if has(texts, "accounts.google.com", "继续前往", "下一步", "请验证您是真人", "正在进行安全验证"):
            break
    rec["after_google_click"] = [t[0] for t in texts][:24]
    screenshot(f"visit{n}-after-google.png")

    if has(texts, "请验证您是真人", "正在进行安全验证"):
        rec["steps"].append("cloudflare")
        for attempt in range(3):
            click_text(texts, "请验证您是真人")
            rec["steps"].append(f"cf click {attempt+1}")
            for _ in range(5):
                time.sleep(5)
                texts = dump_texts()
                if has(texts, "accounts.google.com", "继续前往", "下一步"):
                    break
                if has(texts, "糟糕", "请稍后重试"):
                    break
            if has(texts, "accounts.google.com", "继续前往", "下一步", "糟糕"):
                break
        screenshot(f"visit{n}-after-cf.png")

    if has(texts, "accounts.google.com", "继续前往", "下一步"):
        rec["google_ok"] = True
        rec["steps"].append("google auth visible")
        time.sleep(30)
        texts2 = dump_texts()
        rec["after_30s"] = [t[0] for t in texts2][:24]
        screenshot(f"visit{n}-google-30s.png")
        rec["google_stable"] = has(texts2, "accounts.google.com", "继续前往", "下一步")
        rec["result"] = "PASS" if rec["google_stable"] else "DEGRADED after 30s"
    else:
        rec["google_ok"] = False
        rec["result"] = "FAIL no google auth"
    rec["tun_after"] = tun()
    rec["done"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    return rec


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    rec = run_visit(n)
    logp = EVID / "visits.json"
    data = {"visits": []}
    if logp.exists():
        data = json.loads(logp.read_text())
    data["visits"].append(rec)
    logp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    print(json.dumps(rec, ensure_ascii=False, indent=2))
    if rec.get("result") != "PASS":
        sys.exit(2)


if __name__ == "__main__":
    main()
