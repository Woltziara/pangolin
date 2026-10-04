#!/usr/bin/env python3
"""Import a non-HK ChatGPT-capable node from on-device ClashBox YAML.

Writes gitignored runtime files only. Never prints secrets.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = os.environ.get("TONGDAO_SERIAL", "")
CLASH_YAML = os.environ.get("TONGDAO_CLASH_YAML", "")
PREFERENCE: list[str] = []


def region_of(name: str) -> str:
    mapping = [
        ("美国", "美国"),
        ("德国", "德国"),
        ("新加坡", "新加坡"),
        ("日本", "日本"),
        ("英国", "英国"),
        ("荷兰", "荷兰"),
        ("澳大利亚", "澳大利亚"),
        ("中国台湾", "中国台湾"),
        ("中国香港", "中国香港"),
    ]
    for key, region in mapping:
        if key in name:
            return region
    return "其他"


def parse_proxies(text: str) -> list[dict[str, object]]:
    proxies: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    in_proxies = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("proxies:"):
            in_proxies = True
            continue
        if in_proxies and line.startswith("proxy-groups:"):
            break
        if not in_proxies:
            continue
        if re.match(r"^\s*-\s*$", line) or re.match(r"^\s*-\s+\S", line):
            if current and current.get("name"):
                proxies.append(current)
            current = {}
            m = re.search(r"name:\s*(.+)$", line)
            if m:
                current["name"] = m.group(1).strip().strip("'\"")
            continue
        if current is None:
            continue
        m = re.match(r"^\s{2,}([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not m:
            continue
        key, value = m.group(1), m.group(2).strip().strip("'\"")
        if key in {"name", "type", "server", "password", "sni"}:
            current[key] = value
        elif key == "port":
            try:
                current[key] = int(value)
            except ValueError:
                current[key] = 0
        elif key == "skip-cert-verify":
            current["skip"] = value.lower() == "true"
    if current and current.get("name"):
        proxies.append(current)
    return proxies


def pick(proxies: list[dict[str, object]]) -> dict[str, object]:
    by_name = {str(p.get("name", "")): p for p in proxies}
    for name in PREFERENCE:
        node = by_name.get(name)
        if node and str(node.get("type", "")).lower() == "trojan":
            return node
    for node in proxies:
        name = str(node.get("name", ""))
        if "香港" in name or "V6" in name:
            continue
        if str(node.get("type", "")).lower() == "trojan" and "美国" in name:
            return node
    raise SystemExit("no suitable non-HK trojan node")


def to_xray_outbound(node: dict[str, object], allow_insecure_name: str = "") -> dict[str, object]:
    password = str(node.get("password", ""))
    if not password:
        raise ValueError("selected node has empty password")
    name = str(node.get("name", ""))
    skip = bool(node.get("skip"))
    if skip and name != allow_insecure_name:
        raise ValueError("Stage 1 拒绝 skip-cert-verify（未对该节点显式授权）")
    server = str(node.get("server", ""))
    sni = str(node.get("sni") or "").strip()
    if not sni:
        sni = server
    if not sni or ":" in sni or (sni and sni[0].isdigit()):
        raise ValueError("节点缺少可写入 serverName 的 SNI")
    tls = {
        "allowInsecure": False,
        "alpn": ["h2", "http/1.1"],
        "serverName": sni,
    }
    if skip and name == allow_insecure_name:
        tls["allowInsecure"] = True
    return {
        "protocol": "trojan",
        "tag": "proxy",
        "settings": {
            "servers": [
                {
                    "address": node.get("server"),
                    "port": node.get("port"),
                    "password": password,
                }
            ]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": tls,
        },
    }


def hdc(*args: str) -> subprocess.CompletedProcess[str]:
    cmd = [HDC, "-t", SERIAL, *args]
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def main() -> int:
    if not SERIAL or not CLASH_YAML:
        raise SystemExit("Set TONGDAO_SERIAL and TONGDAO_CLASH_YAML for your own device and profile")
    root = Path(__file__).resolve().parents[1]
    runtime = root / ".runtime"
    runtime.mkdir(exist_ok=True)
    yaml_path = runtime / "clash-profile.yaml"
    print("pulling ClashBox profile from device (secrets stay in .runtime/)", file=sys.stderr)
    hdc("file", "recv", CLASH_YAML, str(yaml_path))
    text = yaml_path.read_text(encoding="utf-8", errors="replace")
    proxies = parse_proxies(text)
    node = pick(proxies)
    name = str(node.get("name"))
    region = region_of(name)
    print(f"selected node: {name}", file=sys.stderr)
    print(f"region: {region}", file=sys.stderr)
    allow_insecure_name = os.environ.get("TONGDAO_ALLOW_INSECURE_NODE", "")
    try:
        outbound = to_xray_outbound(node, allow_insecure_name)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    (runtime / "outbound.json").write_text(json.dumps(outbound, ensure_ascii=False), encoding="utf-8")
    runtime_config = {
        "log": {"loglevel": "warning"},
        "dns": {"queryStrategy": "UseIPv4", "servers": ["1.1.1.1", "8.8.8.8"]},
        "inbounds": [
            {
                "tag": "tun-in",
                "listen": "127.0.0.1",
                "port": 18082,
                "protocol": "socks",
                "settings": {"udp": True, "auth": "noauth"},
                "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
            },
            {
                "tag": "metrics_in",
                "listen": "127.0.0.1",
                "port": 18086,
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
            },
        ],
        "outbounds": [
            outbound,
            {"tag": "direct", "protocol": "freedom", "settings": {}},
            {"tag": "block", "protocol": "blackhole", "settings": {}},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "inboundTag": ["metrics_in"], "outboundTag": "metrics_out"},
                {
                    "type": "field",
                    "ip": [
                        "10.0.0.0/8",
                        "172.16.0.0/12",
                        "192.168.0.0/16",
                        "127.0.0.0/8",
                        "169.254.0.0/16",
                        "224.0.0.0/4",
                    ],
                    "outboundTag": "direct",
                },
                {"type": "field", "ip": ["::/0"], "outboundTag": "block"},
                {"type": "field", "network": "udp", "port": "443", "outboundTag": "block"},
                {"type": "field", "inboundTag": ["tun-in"], "outboundTag": "proxy"},
            ],
        },
        "stats": {},
        "metrics": {"tag": "metrics_out"},
        "policy": {
            "system": {
                "statsOutboundUplink": True,
                "statsOutboundDownlink": True,
            }
        },
    }
    (runtime / "xray-config.json").write_text(
        json.dumps(runtime_config, ensure_ascii=False), encoding="utf-8"
    )
    os.chmod(runtime / "xray-config.json", 0o600)
    meta = {
        "name": name,
        "region": region,
        "server": node.get("server"),
        "port": node.get("port"),
        "protocol": "trojan",
    }
    (runtime / "node-meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(runtime / "outbound.json", 0o600)
    os.chmod(yaml_path, 0o600)
    print(str(runtime / "outbound.json"))
    print(str(runtime / "node-meta.json"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
