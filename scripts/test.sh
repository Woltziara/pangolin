#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tests/node-runner"
npm ci --no-audit --no-fund
npm test
cd "$ROOT"
python3 -m unittest discover -s tests -p 'test_*.py'
if [[ -n "${HEV_WORK_DIR:-}" || -n "${HEV_SOURCE_DIR:-}" ]]; then
  python3 tests/hev_udp_first_packet_test.py
fi
