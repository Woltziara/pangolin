#!/usr/bin/env python3
"""Publish the measured HEV build under the r1 package lock, with raw/packed rollback."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from lib.native_strip import expected_packed_sha256
from lib.provenance import publish_rebuilt_libxray


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(root: Path, work: Path):
    if os.environ.get('TONGDAO_R1_PUBLISH') != '1':
        raise RuntimeError('Use r1-build.sh to publish staged HEV')
    lock_path = root / 'native/CORE_LOCK.json'
    if not lock_path.is_file():
        raise RuntimeError('HEV publication requires an existing CORE_LOCK')
    lock = json.loads(lock_path.read_text())
    staged = work / 'stage/libhevsocks5tun.so'
    receipt = lambda name: (work / name).read_text().strip()
    commit = receipt('measured-hev-commit.txt')
    if not commit.startswith(lock['hev']['commit']):
        raise RuntimeError('HEV source commit does not match CORE_LOCK')
    if receipt('measured-hev-diagnostic-kind.txt') != lock['hev'].get('diagnostic', ''):
        raise RuntimeError('HEV diagnostic variant changed')
    patch = root / 'native/patches/hev-app-routing.patch'
    header = root / 'native/patches/app-flow-route.h'
    if receipt('measured-hev-app-routing-patch-sha256.txt') != sha(patch):
        raise RuntimeError('App routing patch changed since HEV build')
    if receipt('measured-hev-app-flow-header-sha256.txt') != sha(header):
        raise RuntimeError('App flow ABI changed since HEV build')
    digest = sha(staged)
    if digest != receipt('measured-hev-staged-so-sha256.txt'):
        raise RuntimeError('HEV stage digest mismatch')
    patches = json.loads(receipt('measured-hev-patches.json'))
    required = [p for p in lock['patches'] if '/hev-' in p]
    required += ['native/patches/hev-app-routing.patch', 'native/patches/app-flow-route.h']
    for relative in required:
        if patches.get(relative) != sha(root / relative):
            raise RuntimeError('HEV patch receipt mismatch: ' + relative)
    llvm = Path('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin')
    symbols = subprocess.check_output([str(llvm / 'llvm-nm'), '-D', str(staged)], text=True)
    for symbol in ('hev_socks5_tunnel_main_from_str', 'hev_socks5_tunnel_quit',
                   'hev_socks5_tunnel_stats', 'hev_socks5_tunnel_set_app_route_callbacks'):
        if not any(line.split()[-2:] == ['T', symbol] for line in symbols.splitlines()):
            raise RuntimeError('HEV required export missing: ' + symbol)
    packed = expected_packed_sha256(staged, llvm / 'llvm-strip')
    dest = root / lock['hev']['artifact']
    if not dest.is_file():
        raise RuntimeError('HEV publication requires an existing artifact for rollback')
    def verify():
        current = json.loads(lock_path.read_text())
        if sha(dest) != current['hev']['sha256'] or expected_packed_sha256(dest, llvm / 'llvm-strip') != current['hev']['packedSha256']:
            raise RuntimeError('Published HEV raw/packed verification failed')
        current['hev']['appRouting'] = 'per-session-uid-v1'
        for relative in ('native/patches/hev-app-routing.patch', 'native/patches/app-flow-route.h'):
            if relative not in current['patches']:
                current['patches'].append(relative)
        lock_path.write_text(json.dumps(current, indent=2) + '\n')
    publish_rebuilt_libxray(staged, dest, lock_path, digest, packed, lock['note'], verify, component='hev')
    evidence = root / '.runtime/r1-manifests/hev-identity.json'
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text(json.dumps({'commit': commit, 'sha256': digest, 'packedSha256': packed,
                                   'patches': patches, 'workDir': str(work)}, indent=2) + '\n')
    print('HEV published and raw/packed verified', digest)


if __name__ == '__main__':
    publish(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
