#!/usr/bin/env python3
"""Compile the actual protect region, substituting only the NAPI platform edge."""
import hashlib, os, subprocess, tempfile, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
node = Path(subprocess.check_output(['node', '-p', 'process.execPath'], text=True).strip())
inc = Path(os.environ.get('NODE_INCLUDE', str(node.parent.parent / 'include/node')))
if not (inc / 'node_api.h').is_file():
    raise SystemExit('Node-API host headers absent; set NODE_INCLUDE. NOT a HarmonyOS build.')
source = ROOT / 'entry/src/main/cpp/napi_init.cpp'
text = source.read_text()
region = text[text.index('struct ProtectWaiter {'):text.index('bool ReadUrandom(')]
with tempfile.TemporaryDirectory(prefix='pangolin-protect-') as td:
    td = Path(td); (td/'protect-production.inc').write_text(region)
    print('PRODUCTION_SOURCE_SHA256', hashlib.sha256(source.read_bytes()).hexdigest(), flush=True)
    print('EXTRACTED_REGION_SHA256', hashlib.sha256(region.encode()).hexdigest(), flush=True)
    command = [os.environ.get('CXX', 'c++'), '-std=c++17', '-pthread', '-g', '-fsanitize=address,undefined',
        '-I'+str(inc), '-I'+str(ROOT/'entry/src/main/cpp'), '-I'+str(td),
        str(ROOT/'tests/protect_bridge_test.cpp'), '-o', str(td/'test')]
    if sys.platform != 'darwin': command.append('-ldl')
    print('COMMAND', ' '.join(command), flush=True)
    subprocess.run(command, check=True, timeout=45)
    subprocess.run([str(td/'test')], check=True, timeout=30)
