#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL="${TONGDAO_SERIAL:?Set TONGDAO_SERIAL to your own hdc target}"
BUNDLE="com.oscarwoltz.tongdao"
HAP_DIR="$ROOT/entry/build/default/outputs/default"
FILES_DIR="/data/app/el2/100/base/${BUNDLE}/haps/entry/files"

confirm_device() {
  local listed model osname
  listed="$("$HDC" list targets | tr -d '\r' | head -n 1)"
  if [[ "$listed" != "$SERIAL" ]]; then
    echo "device mismatch: got '$listed' want $SERIAL" >&2
    exit 2
  fi
  model="$("$HDC" -t "$SERIAL" shell param get const.product.model | tr -d '\r ')"
  osname="$("$HDC" -t "$SERIAL" shell param get const.ohos.fullname | tr -d '\r ')"
  echo "device $SERIAL model=$model os=$osname"
  case "$model" in
    GRL-AL20) : ;;
    *) echo "refusing to operate non-target model $model (want GRL-AL20 XTS)" >&2; exit 2 ;;
  esac
}

build_hap() {
  export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
  export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
  export HOS_SDK_HOME="$DEVECO_SDK_HOME"
  export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
  export HVIGOR_USER_HOME="${HVIGOR_USER_HOME:-$ROOT/.runtime/hvigor-home}"
  mkdir -p "$HVIGOR_USER_HOME"
  cd "$ROOT"
  ohpm install
  hvigorw assembleHap -p product=default -p buildMode=debug --no-daemon
  ls -la "$HAP_DIR"
}

install_hap() {
  confirm_device
  local hap
  hap="$HAP_DIR/entry-default-signed.hap"
  if [[ ! -f "$hap" ]]; then
    hap="$(ls "$HAP_DIR"/*signed*.hap 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "${hap}" || ! -f "$hap" ]]; then
    echo "missing signed hap" >&2
    exit 1
  fi
  echo "install $hap"
  "$HDC" -t "$SERIAL" install -r "$hap"
}

import_node() {
  confirm_device
  python3 "$ROOT/scripts/import-node.py"
  "$HDC" -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility || true
  sleep 1
  "$HDC" -t "$SERIAL" shell mkdir -p "$FILES_DIR"
  "$HDC" -t "$SERIAL" file send "$ROOT/.runtime/outbound.json" "$FILES_DIR/outbound.json"
  "$HDC" -t "$SERIAL" file send "$ROOT/.runtime/node-meta.json" "$FILES_DIR/node-meta.json"
  "$HDC" -t "$SERIAL" file send "$ROOT/.runtime/xray-config.json" "$FILES_DIR/xray-config.json"
  echo "imported outbound + node-meta + xray-config into app sandbox"
}

stop_clashbox() {
  confirm_device
  "$HDC" -t "$SERIAL" shell aa force-stop org.xbgroup.clashboxLTS || true
  sleep 2
  "$HDC" -t "$SERIAL" shell "cat /proc/net/dev" | grep vpn-tun || echo "vpn-tun gone"
}

start_app() {
  confirm_device
  "$HDC" -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility
}

cmd="${1:-}"
if [[ "$cmd" == "import-node" || "$cmd" == "stop-clashbox" || "$cmd" == "start" || "$cmd" == "device" ]]; then
  if [[ "${TONGDAO_DEVICE:-0}" != "1" ]]; then
    echo "device run gated; TONGDAO_DEVICE=1 required" >&2
    exit 2
  fi
fi
case "$cmd" in
  device) confirm_device ;;
  build)
    echo "device.sh build is disabled; use scripts/r1-build.sh (package.lock)" >&2
    exit 2
    ;;
  install)
    echo "device.sh install is disabled; use scripts/r1-build.sh or stage1-bringup-soak.sh" >&2
    exit 2
    ;;
  import-node) import_node ;;
  stop-clashbox) stop_clashbox ;;
  start) start_app ;;
  sign)
    echo "device.sh sign is disabled; signing is inside scripts/r1-build.sh under package.lock" >&2
    exit 2
    ;;
  all)
    echo "use scripts/r1-build.sh — refusing the old unsigned-debug all path" >&2
    exit 2
    ;;
  *)
    echo "usage: $0 {device|build|sign|install|import-node|stop-clashbox|start|all}" >&2
    exit 1
    ;;
esac
