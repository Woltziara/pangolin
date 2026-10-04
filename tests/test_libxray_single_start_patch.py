#!/usr/bin/env python3
from pathlib import Path
import importlib.util
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/libxray-xray.go-20d70a98"


def load_patcher():
    spec = importlib.util.spec_from_file_location(
        "libxray_single_start", ROOT / "native/patches/libxray-single-start.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> None:
    mod = load_patcher()
    original = FIXTURE.read_text(encoding="utf-8")
    if "StartInstance" not in mod.start_xray_from_json_block(original):
        raise SystemExit("fixture is not the unpatched 20d70a98 StartXrayFromJSON")
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "xray.go"
        shutil.copy(FIXTURE, path)
        mod.patch_xray_go(path)
        text = path.read_text(encoding="utf-8")
        mod.verify_patched(text)
        start_fn = mod.start_xray_from_json_block(text)
        run_fn = mod.run_xray_from_json_block(text)
        if "StartInstance" in start_fn:
            raise SystemExit("patched StartXrayFromJSON still calls StartInstance")
        if "coreServer.Close()" not in run_fn:
            raise SystemExit("patched RunXrayFromJSON missing Close")
    print("ok - libxray-single-start.py rewrites pinned 20d70a98 xray.go")


if __name__ == "__main__":
    main()
