#!/bin/zsh
# Fail-closed soak. Isolated run directory. Never reuse a stale summary as OK.
set -u
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL="${TONGDAO_SERIAL:?Set TONGDAO_SERIAL to your own hdc target}"
BUNDLE="com.oscarwoltz.tongdao"
ROOT="/path/to/pangolin"
EVID="$ROOT/evidence/20260903-r1-baseline"
STATUS_REMOTE="/data/app/el2/100/base/${BUNDLE}/haps/entry/files/dataplane-status.json"
SNAPSHOT_REMOTE="/data/app/el2/100/base/${BUNDLE}/haps/entry/files/dataplane-event-snapshot.json"
MIN_DURATION=7200
MIN_ROUNDS=8
SCREEN_OFF_SEC=1800

if [[ "${TONGDAO_DEVICE:-0}" != "1" ]]; then
  print -u2 -- "device run gated; soak writes to phone"
  exit 2
fi
if [[ "${1:-}" == "--help" ]]; then
  print -u2 -- "usage: $0 [end_unix_ts]"
  exit 2
fi

NOW_TS=$(date +%s)
if [[ -n "${1:-}" ]]; then
  END_TS="$1"
else
  END_TS=$(( NOW_TS + MIN_DURATION ))
fi
PLANNED=$(( END_TS - NOW_TS ))
if [[ "$PLANNED" -lt "$MIN_DURATION" ]]; then
  print -u2 -- "END_TS in the past or shorter than ${MIN_DURATION}s; refuse"
  exit 2
fi

RUN_UUID=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
GEN_HINT="nogen"
RUN_ID="${GEN_HINT}-${RUN_UUID}"
RUN_DIR="$EVID/soak-runs/$RUN_ID"
mkdir -p "$RUN_DIR/rounds"
LOG="$RUN_DIR/soak.log"
PIDF="$RUN_DIR/soak.pid"
SUMMARY="$RUN_DIR/summary.json"
echo $$ > "$PIDF"
print -r -- "$RUN_ID" > "$EVID/current-soak-run"
print -r -- "$$" > "$EVID/current-soak-pid"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

PYTHONPATH="$ROOT/scripts" python3 - "$SUMMARY" "$RUN_ID" "$NOW_TS" "$END_TS" "$$" <<'PY'
import sys
from pathlib import Path
from lib.soak_run import start_summary, write_progress
path, run_id, start_ts, end_ts, pid = sys.argv[1:6]
write_progress(Path(path), start_summary(run_id=run_id, generation="", start_ts=int(start_ts), end_ts=int(end_ts), pid=int(pid)))
print("IN_PROGRESS", run_id)
PY

log "SOAK_START runId=$RUN_ID pid=$$ end=$END_TS fail-closed unique-serial=$SERIAL"

ROUND=0
OK=0
WANT_GEN=""
LAST_AT=0
LAST_EVENT_SEQ=0
LAST_RID=""
DID_WIFI=0
DID_SCREEN=0
HELD_SEC=0
LAST_WALL=0
export DID_WIFI DID_SCREEN HELD_SEC LAST_WALL

fail_end() {
  log "SOAK_FAIL $*"
  PYTHONPATH="$ROOT/scripts" python3 - "$SUMMARY" "$WANT_GEN" "$ROUND" "$OK" "$*" <<'PY'
import sys, time
from pathlib import Path
from lib.soak_run import finalize_summary, write_progress
import json
path = Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["generation"] = sys.argv[2]
doc["rounds"] = int(sys.argv[3])
doc["okRounds"] = int(sys.argv[4])
doc["attemptIndex"] = int(sys.argv[3])
doc["verdict"] = "FAIL"
doc["failReason"] = sys.argv[5]
write_progress(path, finalize_summary(doc))
PY
  rm -f "$PIDF"
  exit 1
}

while [[ $(date +%s) -lt $END_TS ]]; do
  ROUND=$((ROUND + 1))
  DEST="$RUN_DIR/rounds/status-R${ROUND}.json"
  rm -f "$DEST"

  TARGETS=$("$HDC" list targets 2>/dev/null | tr -d '\r')
  LIVE=$(print -r -- "$TARGETS" | grep -v '^$' | grep -v 'Empty' | grep -v 'Fail')
  COUNT=$(print -r -- "$LIVE" | grep -c . || true)
  if [[ "$COUNT" -ne 1 ]] || ! print -r -- "$LIVE" | grep -qx "$SERIAL"; then
    fail_end "hdc_targets_not_unique_x5 [$TARGETS]"
  fi

  MODEL=$("$HDC" -t "$SERIAL" shell param get const.product.model 2>/dev/null | tr -d '\r ')
  if [[ "$MODEL" != "ALT-AL10" ]]; then
    fail_end "not_x5 model=$MODEL"
  fi

  REMAIN=$(( END_TS - $(date +%s) ))
  if [[ "$DID_WIFI" -eq 0 && "$ROUND" -ge 1 && "$REMAIN" -gt $((SCREEN_OFF_SEC + 180)) ]]; then
    log "SOAK_PHASE wifi-bounce"
    WIFI_OUT=$(PYTHONPATH="$ROOT/scripts" python3 - <<'PY'
from lib.accept_phases import wifi_bounce
from lib.extprobe import hdc
HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = "TEST_DEVICE_SERIAL"

def run(*args, timeout=40):
    import subprocess
    def runner(full, to):
        return subprocess.run(list(full), capture_output=True, timeout=to)
    return hdc([HDC, "-t", SERIAL, *args], timeout=timeout, runner=runner)

def verify():
    try:
        return run("shell", "ifconfig wlan0") + run("shell", "hidumper -s WifiService | head -20")
    except Exception as exc:
        return str(exc)

print(wifi_bounce(run=run, verify=verify))
PY
) || fail_end "wifi_bounce_fail $WIFI_OUT"
    DID_WIFI=1
    export DID_WIFI
    LAST_RID=""
  elif [[ "$DID_SCREEN" -eq 0 && "$ROUND" -ge 1 && "$REMAIN" -gt $((SCREEN_OFF_SEC + 60)) ]]; then
    log "SOAK_PHASE screen-off ${SCREEN_OFF_SEC}s no UI wakeup"
    SCREEN_OUT=$(PYTHONPATH="$ROOT/scripts" python3 - "$SCREEN_OFF_SEC" <<'PY'
import sys
from lib.accept_phases import SCREEN_OFF_SEC, screen_off_hold
from lib.extprobe import hdc
HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL = "TEST_DEVICE_SERIAL"
sec = int(sys.argv[1])
if sec < SCREEN_OFF_SEC:
    raise SystemExit(f"screen-off {sec} < {SCREEN_OFF_SEC}")

def run(*args, timeout=40):
    import subprocess
    def runner(full, to):
        return subprocess.run(list(full), capture_output=True, timeout=to)
    return hdc([HDC, "-t", SERIAL, *args], timeout=timeout, runner=runner)

def poll():
    import subprocess
    subprocess.run(["/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc", "list", "targets"], capture_output=True, timeout=20)

def read_screen():
    try:
        return run("shell", "hidumper -s PowerManagerService") + run("shell", "hidumper -s DisplayManagerService")
    except Exception as exc:
        return str(exc)

def alive():
    import json
    from pathlib import Path
    dest = "/tmp/soak-keep.json"
    run("file", "recv", "/data/app/el2/100/base/com.oscarwoltz.tongdao/haps/entry/files/background-keepalive.json", dest)
    rec = json.loads(Path(dest).read_text(encoding="utf-8"))
    if rec.get("ok") is not True:
        raise RuntimeError(f"keepalive not ok {rec}")
    return int(rec.get("progress") or 0)

print(screen_off_hold(run=run, seconds=sec, poll=poll, read_screen=read_screen, alive_fn=alive))
PY
) || fail_end "screen_off_fail $SCREEN_OUT"
    DID_SCREEN=1
    HELD_SEC="$SCREEN_OFF_SEC"
    SCREEN_ROUND=1
    export DID_SCREEN HELD_SEC SCREEN_ROUND
    LAST_RID=""
  fi

  PROBE_OUT=$(PYTHONPATH="$ROOT/scripts" python3 "$ROOT/scripts/stage1-extprobe.py" 2>/dev/null) || fail_end "extprobe_fail $PROBE_OUT"
  PROBE_RID=$(print -r -- "$PROBE_OUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("productionRid") or "")' 2>/dev/null || true)
  if [[ -z "$PROBE_RID" || "$PROBE_RID" == "$LAST_RID" ]]; then
    fail_end "probe_rid_not_fresh last=$LAST_RID now=$PROBE_RID"
  fi
  LAST_RID="$PROBE_RID"

  if ! "$HDC" -t "$SERIAL" file recv "$STATUS_REMOTE" "$DEST" >/dev/null 2>&1; then
    fail_end "status_recv_fail"
  fi
  if [[ ! -s "$DEST" ]]; then
    fail_end "status_file_empty"
  fi

  TUN=$("$HDC" -t "$SERIAL" shell "grep vpn-tun /proc/net/dev || echo no-tun" 2>/dev/null | tr -d '\r')
  CB=$("$HDC" -t "$SERIAL" shell "pidof org.xbgroup.clashboxLTS || echo clashbox-absent" 2>/dev/null | tr -d '\r')
  VPNPID=$("$HDC" -t "$SERIAL" shell "ps -A" 2>/dev/null | grep 'tongdao:vpn' | grep -v grep | awk '{print $1}' | tr -d '\r')

  CHECK=$(PYTHONPATH="$ROOT/scripts" python3 - "$TARGETS" "$SERIAL" "$MODEL" "$DEST" "$TUN" "$CB" "$VPNPID" "$WANT_GEN" "$LAST_AT" "$PROBE_RID" <<'PY'
import json, sys
from pathlib import Path
from lib.soak_round import SoakFail, evaluate_round
targets, serial, model, dest, tun, cb, vpn, want_gen, last_at, probe_rid = sys.argv[1:11]
try:
    rec = evaluate_round(
        targets=targets,
        serial=serial,
        model=model,
        status_path=Path(dest),
        tun=tun,
        cb=cb,
        vpn=vpn,
        want_gen=want_gen,
        last_at=int(last_at or 0),
        status_rc=0,
        did_wifi=int(__import__("os").environ.get("DID_WIFI", "0")),
        did_screen=int(__import__("os").environ.get("DID_SCREEN", "0")),
        held_sec=int(__import__("os").environ.get("HELD_SEC", "0")),
        require_phases=int(__import__("os").environ.get("DID_SCREEN", "0")) == 1,
        lan_ok=True,
        require_lan=True,
        wall_now=int(__import__("time").time()),
        last_wall=int(__import__("os").environ.get("LAST_WALL", "0") or 0),
        max_gap_sec=180,
        last_tun_rx=int(__import__("os").environ.get("LAST_TUN_RX", "0") or 0),
        last_tun_tx=int(__import__("os").environ.get("LAST_TUN_TX", "0") or 0),
        screen_round=__import__("os").environ.get("SCREEN_ROUND", "0") == "1",
    )
    data = json.loads(Path(dest).read_text(encoding="utf-8"))
    rid = str(data.get("evidenceRid") or "")
    if probe_rid and rid != probe_rid:
        raise SoakFail(f"evidenceRid {rid} != probe {probe_rid}")
    ev_at = int(data.get("evidenceAt") or 0)
    if ev_at < 1:
        raise SoakFail("missing_evidence_at")
except SoakFail as exc:
    print(exc.reason)
    sys.exit(2)
print(
    f"SOAK_METRICS gen={rec['generation']} at={rec['at']} tun_rx={rec['tun_rx']} "
    f"tun_tx={rec['tun_tx']} rev={rec['sessionRevision']} rid={probe_rid}"
)
PY
)
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail_end "$CHECK"
  fi

  GEN_NOW=$(print -r -- "$CHECK" | awk '{for(i=1;i<=NF;i++) if($i ~ /^gen=/) {split($i,a,"="); print a[2]}}' | tail -1)
  AT_NOW=$(print -r -- "$CHECK" | awk '{for(i=1;i<=NF;i++) if($i ~ /^at=/) {split($i,a,"="); print a[2]}}' | tail -1)
  TUN_RX_NOW=$(print -r -- "$CHECK" | awk '{for(i=1;i<=NF;i++) if($i ~ /^tun_rx=/) {split($i,a,"="); print a[2]}}' | tail -1)
  TUN_TX_NOW=$(print -r -- "$CHECK" | awk '{for(i=1;i<=NF;i++) if($i ~ /^tun_tx=/) {split($i,a,"="); print a[2]}}' | tail -1)
  if [[ -z "$WANT_GEN" ]]; then
    WANT_GEN="$GEN_NOW"
    NEW_ID="${WANT_GEN}-${RUN_UUID}"
    NEW_DIR="$EVID/soak-runs/$NEW_ID"
    if [[ "$RUN_DIR" != "$NEW_DIR" ]]; then
      mv "$RUN_DIR" "$NEW_DIR"
      RUN_DIR="$NEW_DIR"
      LOG="$RUN_DIR/soak.log"
      PIDF="$RUN_DIR/soak.pid"
      SUMMARY="$RUN_DIR/summary.json"
    fi
    RUN_ID="$NEW_ID"
    print -r -- "$RUN_ID" > "$EVID/current-soak-run"
    print -r -- "$$" > "$EVID/current-soak-pid"
    log "SOAK_GEN $WANT_GEN runId=$RUN_ID dir=$RUN_DIR"
  fi
  LAST_AT="$AT_NOW"

  SNAP="$RUN_DIR/rounds/event-snapshot-R${ROUND}.json"
  rm -f "$SNAP"
  if ! "$HDC" -t "$SERIAL" file recv "$SNAPSHOT_REMOTE" "$SNAP" >/dev/null 2>&1; then
    fail_end "event_snapshot_recv_fail"
  fi

  CHECK2=$(PYTHONPATH="$ROOT/scripts" python3 - "$SNAP" "$LAST_EVENT_SEQ" "$WANT_GEN" "$DEST" <<'PY'
import json, sys
from pathlib import Path
from lib.soak_round import SoakFail, check_event_snapshot
snap, last, want_gen, status_path = sys.argv[1:5]
status = json.loads(Path(status_path).read_text(encoding="utf-8"))
try:
    seq = check_event_snapshot(
        snapshot_path=Path(snap),
        last_seq=int(last or 0),
        want_gen=str(status.get("generation") or want_gen),
        want_rev=int(status.get("sessionRevision") or 0),
        recv_rc=0,
    )
except SoakFail as exc:
    print(exc.reason)
    sys.exit(2)
print(seq)
PY
)
  erc=$?
  if [[ "$erc" -ne 0 ]]; then
    fail_end "$CHECK2"
  fi
  LAST_EVENT_SEQ="$CHECK2"

  OK=$((OK + 1))
  PYTHONPATH="$ROOT/scripts" python3 - "$SUMMARY" "$WANT_GEN" "$ROUND" "$OK" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
from lib.soak_run import write_progress
path = Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["generation"] = sys.argv[2]
doc["rounds"] = int(sys.argv[3])
doc["okRounds"] = int(sys.argv[4])
doc["attemptIndex"] = int(sys.argv[3])
doc["runId"] = sys.argv[5]
doc["pid"] = int(Path(sys.argv[1]).with_name("soak.pid").read_text().strip() or "0") if Path(sys.argv[1]).with_name("soak.pid").is_file() else int(__import__("os").environ.get("SOAK_PID", "0") or 0)
doc["verdict"] = "IN_PROGRESS"
doc["didWifi"] = int(__import__("os").environ.get("DID_WIFI", "0"))
doc["didScreen"] = int(__import__("os").environ.get("DID_SCREEN", "0"))
doc["heldSec"] = int(__import__("os").environ.get("HELD_SEC", "0"))
write_progress(path, doc)
PY
  log "R$ROUND $CHECK seq=$LAST_EVENT_SEQ rid=$LAST_RID"
  LAST_WALL=$(date +%s)
  export LAST_WALL
  export LAST_TUN_RX="$TUN_RX_NOW"
  export LAST_TUN_TX="$TUN_TX_NOW"
  export SCREEN_ROUND=0
  sleep 15
done

PYTHONPATH="$ROOT/scripts" python3 - "$SUMMARY" "$WANT_GEN" "$ROUND" "$OK" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
from lib.soak_run import SoakRunFail, check_final, finalize_summary, write_progress
path = Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["generation"] = sys.argv[2]
doc["rounds"] = int(sys.argv[3])
doc["okRounds"] = int(sys.argv[4])
doc["attemptIndex"] = int(sys.argv[3])
doc["runId"] = sys.argv[5]
doc["verdict"] = "OK"
doc = finalize_summary(doc)
try:
    check_final(doc)
except SoakRunFail as exc:
    doc["verdict"] = "FAIL"
    doc["failReason"] = exc.reason
    write_progress(path, doc)
    raise SystemExit(exc.reason)
write_progress(path, doc)
print("FINAL_OK", doc["runId"], doc["durationSec"], doc["rounds"])
PY
frc=$?
if [[ "$frc" -ne 0 ]]; then
  fail_end "final_checker"
fi
log "SOAK_END rounds=$ROUND ok=$OK fail=0 runId=$RUN_ID"
rm -f "$PIDF"
exit 0
