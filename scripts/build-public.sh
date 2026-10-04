#!/usr/bin/env bash
# Build an unsigned public-source HAP. Never signs, installs or contacts devices.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
case "$MODE" in
  --help|-h) echo "Usage: bash scripts/build-public.sh [--native-only]"; exit 0 ;;
  ""|--native-only) : ;;
  *) echo "Unknown argument: $MODE" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo "Too many arguments" >&2; exit 2; fi

DEVECO_STUDIO_HOME="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_STUDIO_HOME/Contents/sdk}"
export OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-$DEVECO_SDK_HOME/default/openharmony/native}"
export HOS_SDK_HOME="$DEVECO_SDK_HOME"
export JAVA_HOME="${JAVA_HOME:-$DEVECO_STUDIO_HOME/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$DEVECO_STUDIO_HOME/Contents/tools/node/bin:$DEVECO_STUDIO_HOME/Contents/tools/ohpm/bin:$DEVECO_STUDIO_HOME/Contents/tools/hvigor/bin:$PATH"
export OHOS_GO_FORK="${OHOS_GO_FORK:-$ROOT/.runtime/native-build/ohos_golang_go}"
LOCK="$ROOT/native/CORE_LOCK.json"
lock_value() {
  python3 - "$LOCK" "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    value = json.load(stream)[sys.argv[2]][sys.argv[3]]
print(value)
PY
}
export LIBXRAY_REPO="$(lock_value libxray repo)"
export LIBXRAY_PIN="$(lock_value libxray commit)"
export OHOS_GO_COMMIT="$(lock_value go commit)"
export HEV_REPO="$(lock_value hev repo)"
export HEV_PIN="$(lock_value hev commit)"
if [[ ! -x "$OHOS_GO_FORK/bin/go" ]]; then
  echo "Missing OpenHarmony Go toolchain. Follow docs/BUILDING.md first." >&2
  exit 1
fi
if [[ ! -x "$OHOS_NATIVE_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang" ]]; then
  echo "Missing OpenHarmony native SDK. Check OHOS_NATIVE_HOME." >&2
  exit 1
fi

mkdir -p "$ROOT/.runtime/public-build" "$ROOT/entry/src/main/cpp/prebuilt/arm64-v8a"
export XRAY_WORK_DIR="$(mktemp -d "$ROOT/.runtime/public-build/xray.XXXXXX")"
export HEV_WORK_DIR="$(mktemp -d "$ROOT/.runtime/public-build/hev.XXXXXX")"
export HEV_STAGE_DIR="$HEV_WORK_DIR/stage"
export TONGDAO_NATIVE_BUILD=1
bash "$ROOT/scripts/build_libxray_ohos.sh"
bash "$ROOT/scripts/build_hev_ohos.sh"
cp "$XRAY_WORK_DIR/libxray.so" "$ROOT/entry/src/main/cpp/prebuilt/arm64-v8a/libxray.so"
cp "$HEV_STAGE_DIR/libhevsocks5tun.so" "$ROOT/entry/src/main/cpp/prebuilt/arm64-v8a/libhevsocks5tun.so"
python3 "$ROOT/scripts/restore_geo.py"
if [[ "$MODE" == "--native-only" ]]; then
  echo "Native cores and Geo data prepared. No HAP built."
  exit 0
fi

cd "$ROOT"
ohpm install
hvigorw assembleHap -p product=default -p buildMode=debug --no-daemon
HAP="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [[ ! -f "$HAP" ]]; then echo "Expected unsigned HAP missing" >&2; exit 1; fi
echo "Unsigned HAP: $HAP"
