#!/bin/zsh
# Unique X5 is already visible. Install latest signed HAP, import nodes privately, start NEW soak3.
set -euo pipefail
if [[ "${TONGDAO_INSTALL:-0}" != "1" ]]; then
  echo "bringup install is gated; set TONGDAO_INSTALL=1 only for an exact reviewed candidate" >&2
  exit 2
fi
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL="${TONGDAO_SERIAL:?Set TONGDAO_SERIAL to your own hdc target}"
BUNDLE="com.oscarwoltz.tongdao"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVID="$ROOT/evidence/20260903-r1-baseline"
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
FILES="/data/app/el2/100/base/${BUNDLE}/haps/entry/files"
LOG="$EVID/bringup.log"
BRINGUP_LOCK="$EVID/bringup.lock"
SINGLETON="$ROOT/scripts/lib/hdc_singleton.py"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

PKG_LOCK="$ROOT/.runtime/r1-manifests/package.lock"
mkdir -p "$ROOT/.runtime/r1-manifests"
mkdir -p "$EVID"
python3 "$SINGLETON" hold "$BRINGUP_LOCK" $$ >"$EVID/bringup.hold.out" 2>&1 &
BRING_HOLD=$!
if ! python3 "$SINGLETON" wait-acquired "$EVID/bringup.hold.out" "$BRING_HOLD"; then
  log "BRINGUP_DUPLICATE pid=$$ $(cat "$EVID/bringup.hold.out" 2>/dev/null) (no second install/import/soak3)"
  kill "$BRING_HOLD" 2>/dev/null || true
  exit 3
fi
python3 "$SINGLETON" hold "$PKG_LOCK" $$ >"$EVID/package.hold.out" 2>&1 &
PKG_HOLD=$!
if ! python3 "$SINGLETON" wait-acquired "$EVID/package.hold.out" "$PKG_HOLD"; then
  log "PACKAGE_LOCK held, not installing half-written HAP"
  kill "$PKG_HOLD" "$BRING_HOLD" 2>/dev/null || true
  exit 4
fi
release_bringup() {
  kill "$PKG_HOLD" "$BRING_HOLD" 2>/dev/null || true
}
trap release_bringup EXIT

if pgrep -f 'stage1-soak-failclosed.sh' >/dev/null 2>&1; then
  log "soak3 already running; refusing second bringup"
  exit 3
fi

listed="$("$HDC" list targets | tr -d '\r')"
live=$(print -r -- "$listed" | grep -v '^$' | grep -v Empty | grep -v Fail)
count=$(print -r -- "$live" | grep -c . || true)
if [[ "$count" -ne 1 ]] || ! print -r -- "$live" | grep -qx "$SERIAL"; then
  log "not unique X5 [$listed] — PHYSICAL_DATA_LINK_UNAVAILABLE, no install"
  exit 2
fi
if print -r -- "$listed" | grep -q Empty; then
  log "hdc Empty — no auto-install"
  exit 2
fi
model="$("$HDC" -t "$SERIAL" shell param get const.product.model | tr -d '\r ')"
if [[ "$model" != "ALT-AL10" ]]; then
  log "not X5 $model"
  exit 2
fi
if [[ ! -f "$HAP" ]]; then
  log "missing signed hap"
  exit 1
fi
MANIFEST="$ROOT/.runtime/r1-manifests/latest-signed.json"
if [[ ! -f "$MANIFEST" ]]; then
  MANIFEST="$ROOT/.runtime/r1-manifests/latest-skip-install.json"
fi
PYTHONPATH="$ROOT/scripts" python3 - "$ROOT" "$HAP" "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
from lib.provenance import assert_installable
root, hap, man = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
if not man.is_file():
    raise SystemExit("manifest missing; refuse install")
doc = json.loads(man.read_text())
unsigned = Path(str(doc.get("immutableUnsigned") or ""))
print("installable", assert_installable(root, hap, doc, unsigned=unsigned if unsigned.is_file() else None))
PY

log "force-stop clashbox"
"$HDC" -t "$SERIAL" shell aa force-stop org.xbgroup.clashboxLTS >/dev/null 2>&1 || true

log "install $HAP"
"$HDC" -t "$SERIAL" install -r "$HAP"

DUMP="$ROOT/.runtime/r1-manifests/bm-dump-bringup.txt"
mkdir -p "$ROOT/.runtime/r1-manifests"
"$HDC" -t "$SERIAL" shell "bm dump -n $BUNDLE" > "$DUMP"
PYTHONPATH="$ROOT/scripts" python3 - "$DUMP" "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
from lib.provenance import AUTHORIZED_SIGNER_FINGERPRINT, check_install_dump
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
man = json.loads(Path(sys.argv[2]).read_text())
fp = str(man.get("fingerprint") or man.get("signerFingerprint") or "") or AUTHORIZED_SIGNER_FINGERPRINT
got = check_install_dump(
    text,
    str(man.get("versionName") or ""),
    str(man.get("versionCode") or ""),
    "com.oscarwoltz.tongdao",
    want_fingerprint=fp,
)
print("readback", got)
PY

log "import nodes privately"
python3 "$ROOT/scripts/import-node.py" >/dev/null
"$HDC" -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility >/dev/null 2>&1 || true
sleep 2
"$HDC" -t "$SERIAL" shell mkdir -p "$FILES"
"$HDC" -t "$SERIAL" file send "$ROOT/.runtime/outbound.json" "$FILES/outbound.json"
"$HDC" -t "$SERIAL" file send "$ROOT/.runtime/node-meta.json" "$FILES/node-meta.json"
# do not send full xray-config with secrets beyond outbound; VPN rebuilds config at start

log "start VPN via play"
"$HDC" -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility >/dev/null 2>&1 || true
sleep 2
"$HDC" -t "$SERIAL" shell uitest uiInput click 302 2254 >/dev/null 2>&1 || true
sleep 8
log "STRONG_PROBE stage1-extprobe.py"
python3 "$ROOT/scripts/stage1-extprobe.py"
prc=$?
if [[ "$prc" -ne 0 ]]; then
  log "strong probe failed rc=$prc; not launching soak without bound RID"
  exit 5
fi

chmod +x "$ROOT/scripts/stage1-soak-failclosed.sh"
log "SOAK3_LAUNCH new 2h from zero"
nohup zsh "$ROOT/scripts/stage1-soak-failclosed.sh" >> "$EVID/soak3-nohup.out" 2>&1 &
log "soak3 pid=$!"
exit 0
