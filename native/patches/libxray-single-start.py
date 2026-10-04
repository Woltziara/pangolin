#!/usr/bin/env python3
"""Make libXray start the core once, and Close it if that Start fails.

Pinned libXray 20d70a98 StartXrayFromJSON used core.StartInstance (New+Start).
RunXrayFromJSON then called Start() again. tcpWorker.Start() overwrites hub
without closing the first listener; Close() only closes the second.
"""
from __future__ import annotations

import sys
from pathlib import Path

OLD_IMPORT = (
    "import (\n"
    '\t"os"\n'
    '\t"runtime/debug"\n'
    "\n"
    '\t"github.com/xtls/libxray/memory"\n'
    '\t"github.com/xtls/xray-core/common/cmdarg"\n'
    '\t"github.com/xtls/xray-core/core"\n'
    '\t_ "github.com/xtls/xray-core/main/distro/all"\n'
    ")"
)

NEW_IMPORT = (
    "import (\n"
    '\t"bytes"\n'
    '\t"os"\n'
    '\t"runtime/debug"\n'
    "\n"
    '\t"github.com/xtls/libxray/memory"\n'
    '\t"github.com/xtls/xray-core/common/cmdarg"\n'
    '\t"github.com/xtls/xray-core/core"\n'
    '\t_ "github.com/xtls/xray-core/main/distro/all"\n'
    ")"
)

OLD_START = (
    "func StartXrayFromJSON(configJSON string) (*core.Instance, error) {\n"
    "\t// Convert JSON string to bytes\n"
    "\tconfigBytes := []byte(configJSON)\n"
    "\t\n"
    "\t// Use core.StartInstance which can load configuration directly from bytes\n"
    '\tserver, err := core.StartInstance("json", configBytes)\n'
    "\tif err != nil {\n"
    "\t\treturn nil, err\n"
    "\t}\n"
    "\n"
    "\treturn server, nil\n"
    "}"
)

NEW_START = (
    "func StartXrayFromJSON(configJSON string) (*core.Instance, error) {\n"
    '\tconfig, err := core.LoadConfig("json", bytes.NewReader([]byte(configJSON)))\n'
    "\tif err != nil {\n"
    "\t\treturn nil, err\n"
    "\t}\n"
    "\n"
    "\tserver, err := core.New(config)\n"
    "\tif err != nil {\n"
    "\t\treturn nil, err\n"
    "\t}\n"
    "\n"
    "\treturn server, nil\n"
    "}"
)

OLD_START_FAIL = (
    "\tif err = coreServer.Start(); err != nil {\n"
    "\t\treturn\n"
    "\t}"
)

NEW_START_FAIL = (
    "\tif err = coreServer.Start(); err != nil {\n"
    "\t\t_ = coreServer.Close()\n"
    "\t\tcoreServer = nil\n"
    "\t\treturn\n"
    "\t}"
)


def start_xray_from_json_block(text: str) -> str:
    marker = "func StartXrayFromJSON"
    start = text.find(marker)
    if start < 0:
        raise SystemExit("StartXrayFromJSON not found")
    nxt = text.find("\nfunc ", start + 1)
    if nxt < 0:
        nxt = len(text)
    return text[start:nxt]


def run_xray_from_json_block(text: str) -> str:
    marker = "func RunXrayFromJSON"
    start = text.find(marker)
    if start < 0:
        raise SystemExit("RunXrayFromJSON not found")
    nxt = text.find("\nfunc ", start + 1)
    if nxt < 0:
        nxt = len(text)
    return text[start:nxt]


def verify_patched(text: str) -> None:
    start_fn = start_xray_from_json_block(text)
    if "StartInstance" in start_fn:
        raise SystemExit("StartXrayFromJSON still calls StartInstance")
    if "core.New(" not in start_fn:
        raise SystemExit("StartXrayFromJSON does not call core.New")
    if "bytes.NewReader" not in start_fn:
        raise SystemExit("StartXrayFromJSON does not load JSON via bytes.NewReader")
    run_fn = run_xray_from_json_block(text)
    if "coreServer.Close()" not in run_fn:
        raise SystemExit("RunXrayFromJSON does not Close on Start failure")
    if run_fn.count("coreServer.Start()") != 1:
        raise SystemExit("RunXrayFromJSON Start() count is not 1")


def patch_xray_go(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if OLD_START not in text:
        raise SystemExit(f"{path}: StartXrayFromJSON block not found")
    if OLD_IMPORT not in text:
        raise SystemExit(f"{path}: import block not found")
    fail_count = text.count(OLD_START_FAIL)
    if fail_count < 1:
        raise SystemExit(f"{path}: Start failure return not found")
    text = text.replace(OLD_IMPORT, NEW_IMPORT, 1)
    text = text.replace(OLD_START, NEW_START, 1)
    text = text.replace(OLD_START_FAIL, NEW_START_FAIL)
    verify_patched(text)
    path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: libxray-single-start.py <xray.go>")
    patch_xray_go(Path(sys.argv[1]))
    print("OK libxray single-start patch applied and verified")
