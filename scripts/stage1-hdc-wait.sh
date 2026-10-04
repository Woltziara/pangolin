#!/bin/zsh
# Observe unique Mate X5. Does not install, import, or start soak.
# Lock is OS flock held by a child process for this waiter's lifetime.
set -u
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL="${TONGDAO_SERIAL:?Set TONGDAO_SERIAL to your own hdc target}"
ROOT="/path/to/pangolin"
EVID="$ROOT/evidence/20260903-r1-baseline"
LOG="$EVID/hdc-wait.log"
PIDF="$EVID/hdc-wait.pid"
LOCKFILE="$EVID/hdc-wait.flock"
SINGLETON="$ROOT/scripts/lib/hdc_singleton.py"
mkdir -p "$EVID"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

python3 "$SINGLETON" hold "$LOCKFILE" $$ >"$EVID/hdc-wait.hold.out" 2>&1 &
HOLD_PID=$!
if ! python3 "$SINGLETON" wait-acquired "$EVID/hdc-wait.hold.out" "$HOLD_PID"; then
  log "HDC_WAIT_DUPLICATE pid=$$ hold=$(cat "$EVID/hdc-wait.hold.out" 2>/dev/null) (exit, no install)"
  kill "$HOLD_PID" 2>/dev/null || true
  exit 3
fi
print -r -- $$ > "$PIDF"
release_lock() {
  kill "$HOLD_PID" 2>/dev/null || true
}
trap release_lock EXIT
log "HDC_WAIT_OBSERVE pid=$$ want=$SERIAL flock=1 no-auto-install"

while true; do
  TARGETS=$("$HDC" list targets 2>/dev/null | tr -d '\r')
  LIVE=$(print -r -- "$TARGETS" | grep -v '^$' | grep -v 'Empty' | grep -v 'Fail')
  COUNT=$(print -r -- "$LIVE" | grep -c . || true)
  if [[ "$COUNT" -eq 1 ]] && print -r -- "$LIVE" | grep -qx "$SERIAL"; then
    MODEL=$("$HDC" -t "$SERIAL" shell param get const.product.model 2>/dev/null | tr -d '\r ')
    if [[ "$MODEL" == "ALT-AL10" ]]; then
      log "X5_VISIBLE model=$MODEL (observe only; will not install)"
      print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $SERIAL $MODEL" > "$EVID/hdc-visible.txt"
    else
      log "wrong_model $MODEL"
    fi
  else
    if print -r -- "$TARGETS" | grep -q Empty || [[ "$COUNT" -eq 0 ]]; then
      print -r -- "PHYSICAL_DATA_LINK_UNAVAILABLE $(date '+%Y-%m-%d %H:%M:%S') targets=[$TARGETS]" > "$EVID/PHYSICAL_DATA_LINK_UNAVAILABLE.flag"
      log "waiting PHYSICAL_DATA_LINK_UNAVAILABLE targets=[$TARGETS] (no auto-install)"
    else
      log "waiting targets=[$TARGETS]"
    fi
  fi
  sleep 15
done
