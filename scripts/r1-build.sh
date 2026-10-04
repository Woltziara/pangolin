#!/bin/zsh
set -euo pipefail
# R1 fail-closed: verify CORE_LOCK, assemble unsigned HAP, Huawei-sign, install on X5,
# dump identity to a file (never pipe into a heredoc), write a rerunnable manifest.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
SERIAL="${TONGDAO_SERIAL:?Set TONGDAO_SERIAL to your own hdc target}"
BUNDLE="com.oscarwoltz.tongdao"
LOCK="$ROOT/native/CORE_LOCK.json"
APP_JSON="$ROOT/AppScope/app.json5"
MANIFEST_DIR="$ROOT/.runtime/r1-manifests"
python3 -c "
from pathlib import Path
p = Path('$MANIFEST_DIR')
if not p.is_dir():
    p.mkdir(parents=True)
"
PKG_LOCK="$MANIFEST_DIR/package.lock"
python3 "$ROOT/scripts/lib/hdc_singleton.py" hold "$PKG_LOCK" $$ >"$MANIFEST_DIR/package.hold.out" 2>&1 &
PKG_HOLD=$!
if ! python3 "$ROOT/scripts/lib/hdc_singleton.py" wait-acquired "$MANIFEST_DIR/package.hold.out" "$PKG_HOLD"; then
  echo "package lock held; refuse concurrent build/publish/install" >&2
  kill "$PKG_HOLD" 2>/dev/null || true
  exit 3
fi
release_pkg() {
  kill "$PKG_HOLD" 2>/dev/null || true
}
trap release_pkg EXIT
# Phone install is a later, explicit choice. Default is sign-only.
if [[ "${TONGDAO_INSTALL:-0}" != "1" ]]; then
  SKIP_INSTALL=1
fi

export TONGDAO_R1_PUBLISH=1
export TONGDAO_NATIVE_BUILD=1
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export HOS_SDK_HOME="$DEVECO_SDK_HOME"
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
if [[ -z "${HVIGOR_USER_HOME:-}" ]]; then
  HVIGOR_USER_HOME="$(mktemp -d /tmp/hvigor-user.XXXXXX)"
fi
python3 -c "
from pathlib import Path
Path('$HVIGOR_USER_HOME').mkdir(parents=True, exist_ok=True)
Path('$ROOT/.runtime/npm-cache').mkdir(parents=True, exist_ok=True)
Path('$ROOT/.runtime/hvigor-pnpm').mkdir(parents=True, exist_ok=True)
"
export HVIGOR_USER_HOME
export npm_config_cache="$ROOT/.runtime/npm-cache"
export npm_config_audit=false
export npm_config_fund=false
export npm_config_update_notifier=false
export npm_config_fetch_timeout=30000
export npm_config_fetch_retries=1
export npm_config_prefer_offline=true
NPM_BIN="$(command -v npm || true)"
if [[ -z "$NPM_BIN" ]]; then
  NPM_BIN="/Applications/DevEco-Studio.app/Contents/tools/node/bin/npm"
fi
PYTHONPATH="$ROOT/scripts" python3 - "$HVIGOR_USER_HOME" "$ROOT/.runtime/hvigor-pnpm" "$NPM_BIN" <<'PY'
import sys
from pathlib import Path
from lib.hvigor_pnpm import PnpmSeedError, seed_hvigor_pnpm
try:
    how = seed_hvigor_pnpm(Path(sys.argv[1]), Path(sys.argv[2]), npm=sys.argv[3])
except PnpmSeedError as exc:
    print("FAIL pnpm seed", exc, file=sys.stderr)
    raise SystemExit(1)
print("hvigor-pnpm", how)
PY
# Unique workdirs. Do not reuse a fixed /tmp/libhevsocks5tun-ohos or clobber HOME.
export XRAY_WORK_DIR="${XRAY_WORK_DIR:-$(mktemp -d /tmp/xray-ohos.XXXXXX)}"
export HEV_WORK_DIR="${HEV_WORK_DIR:-$(mktemp -d /tmp/hev-ohos.XXXXXX)}"
export GOPATH="${GOPATH:-$(mktemp -d /tmp/gopath.XXXXXX)}"
export GOCACHE="${GOCACHE:-$(mktemp -d /tmp/gocache.XXXXXX)}"
export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
# Sandbox cannot read ~/.gitconfig. Point git at an empty file; do not clobber HOME.
export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$(mktemp /tmp/gitconfig.XXXXXX)}"
export GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
# Do not clobber operator HOME. Opt in only when ~/.ohpm is unreadable.
if [[ "${TONGDAO_ISOLATE_HOME:-0}" == "1" ]]; then
  export HOME="$(mktemp -d /tmp/tongdao-home.XXXXXX)"
fi

echo "== device =="
model="SKIP"
osname="SKIP"
if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  echo "SKIP_INSTALL=1: not requiring X5 for native/HAP rebuild"
else
  if ! "$HDC" list targets | tr -d '\r' | grep -qx "$SERIAL"; then
    echo "target device $SERIAL not connected" >&2
    exit 2
  fi
  model="$("$HDC" -t "$SERIAL" shell param get const.product.model | tr -d '\r ')"
  osname="$("$HDC" -t "$SERIAL" shell param get const.ohos.fullname | tr -d '\r ')"
  echo "device $SERIAL model=$model os=$osname"
  case "$model" in
    ALT-AL10|GRL-AL20) : ;;
    *) echo "refusing unsupported model $model (want ALT-AL10 X5 or GRL-AL20 XTS)" >&2; exit 2 ;;
  esac
fi

echo "== CORE_LOCK =="
python3 - "$LOCK" "$ROOT" <<'PY'
import hashlib, json, sys
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
failed = 0
for key in ("libxray", "hev"):
    item = lock[key]
    path = root / item["artifact"]
    if not path.is_file():
        print(f"FAIL missing {item['artifact']}", file=sys.stderr)
        failed += 1
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    want = item["sha256"]
    if digest != want:
        print(f"FAIL {item['artifact']} sha256 {digest} != {want}", file=sys.stderr)
        failed += 1
    else:
        print(f"OK {item['artifact']} sha256={digest}")
if failed:
    sys.exit(1)
print("CORE_LOCK hashes match")
PY
echo "== geo restore =="
python3 "$ROOT/scripts/restore_geo.py"

if [[ "${REBUILD_HEV:-0}" == "1" ]]; then
  echo "== hev rebuild =="
  # A previously staged build is reusable only after the publisher rechecks
  # source/patch/ABI receipts, exports and raw/stripped artifact digests.
  if [[ ! -f "$HEV_WORK_DIR/stage/libhevsocks5tun.so" ]]; then
    bash "$ROOT/scripts/build_hev_ohos.sh"
  fi
  PYTHONPATH="$ROOT/scripts" python3 "$ROOT/scripts/publish_hev_stage.py" "$ROOT" "$HEV_WORK_DIR"
fi
if [[ "${REBUILD_XRAY:-0}" == "1" ]]; then
  echo "== libxray rebuild =="
  bash "$ROOT/scripts/build_libxray_ohos.sh"
  PYTHONPATH="$ROOT/scripts" python3 - "$LOCK" "$ROOT" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
from datetime import datetime
from lib.provenance import measure_artifacts, publish_rebuilt_libxray, unrecorded_env, verify_measured
lock_path = Path(sys.argv[1])
root = Path(sys.argv[2])
lock = json.loads(lock_path.read_text())
work = Path(os.environ.get("XRAY_WORK_DIR", ""))
staged = work / "libxray.so"
if not staged.is_file():
    print("FAIL staged libxray missing", staged, file=sys.stderr)
    sys.exit(1)
path = staged
digest = hashlib.sha256(path.read_bytes()).hexdigest()
old = lock["libxray"]["sha256"]
patch = root / "native/patches/libxray-cgohello.patch"
patch_hash = hashlib.sha256(patch.read_bytes()).hexdigest() if patch.is_file() else ""
def read_txt(name):
    p = work / name
    return p.read_text().strip() if p.is_file() else ""
measured_commit = read_txt("measured-libxray-commit.txt")
measured_go = read_txt("measured-go-commit.txt")
measured_go_ver = read_txt("measured-go-version.txt")
applied = read_txt("measured-patch-applied.txt") == "applied"
single_start = read_txt("measured-single-start-patch.txt") == "applied"
single_start_hash = read_txt("measured-single-start-patch-sha256.txt")
if not measured_commit:
    print("FAIL missing measured checkout commit", file=sys.stderr)
    sys.exit(1)
pin = str(lock["libxray"]["commit"])
if pin not in measured_commit and not measured_commit.startswith(pin):
    print("FAIL measured checkout", measured_commit, "!= pin", pin, file=sys.stderr)
    sys.exit(1)
if not applied:
    print("FAIL CGoHello patch not applied to checkout", file=sys.stderr)
    sys.exit(1)
if not single_start:
    print("FAIL libxray single-start patch not applied to checkout", file=sys.stderr)
    sys.exit(1)
want_single = hashlib.sha256((root / "native/patches/libxray-single-start.py").read_bytes()).hexdigest()
if single_start_hash != want_single:
    print("FAIL measured single-start patch hash", single_start_hash, "!=", want_single, file=sys.stderr)
    sys.exit(1)
go_pin = str(lock["go"].get("commit", ""))
if measured_go and go_pin and go_pin not in measured_go and not measured_go.startswith(go_pin):
    print("FAIL measured go commit", measured_go, "!=", go_pin, file=sys.stderr)
    sys.exit(1)
nm = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/llvm-nm"
exports = []
if Path(nm).exists():
    out = subprocess.check_output([nm, "-D", str(path)], text=True, errors="replace")
    for name in ("CGoHello", "CGoRunXrayFromJSON", "CGoStopXray", "CGoXrayVersion", "CGoPing", "CGoQueryStats"):
        if name in out:
            exports.append(name)
identity = {
    "at": datetime.now().isoformat(timespec="seconds"),
    "rebuiltSha256": digest,
    "previousLockSha256": old,
    "bitIdenticalToLock": digest == old,
    "copiedFromLock": False,
    "measuredCheckoutCommit": measured_commit,
    "measuredGoCommit": measured_go,
    "measuredGoVersion": measured_go_ver,
    "measuredPatchApplied": True,
    "libxrayCommit": measured_commit,
    "xrayCore": lock["libxray"]["xray_core"],
    "goVersion": measured_go_ver or lock["go"]["version"],
    "goCommit": measured_go or lock["go"].get("commit", ""),
    "patch": "native/patches/libxray-cgohello.patch",
    "patchSha256": patch_hash,
    "singleStartPatch": "native/patches/libxray-single-start.py",
    "singleStartPatchSha256": single_start_hash,
    "measuredSingleStartApplied": True,
    "buildFlags": "CGO_ENABLED=1 GOOS=openharmony GOARCH=arm64 -buildmode=c-shared -trimpath -ldflags=-s -w -checklinkname=0 -buildid=",
    "exports": exports,
    "abi": "legacy SOCKS CGoHello/CGoRunXrayFromJSON (not CGoInvoke)",
    "note": "Go c-shared is not bit-reproducible across workdirs. Identity uses measured checkout/toolchain/patch, not CORE_LOCK copies.",
    "frozenSha256": lock["libxray"].get("frozenSha256", old),
}
measured = measure_artifacts(root, lock)
recorded = {
    "LIBXRAY_PIN": pin,
    "LIBXRAY_REPO": lock["libxray"]["repo"],
    "OHOS_GO_COMMIT": go_pin,
    "OHOS_GO_FORK": str((root / lock["go"]["local_toolchain"]).resolve()),
    "HEV_TAG": lock["hev"]["tag"],
}
bad_env = unrecorded_env(os.environ, recorded)
if bad_env:
    print("FAIL unrecorded env override", bad_env, file=sys.stderr)
    sys.exit(1)
if len(exports) < 6:
    print("FAIL missing exports", exports, file=sys.stderr)
    sys.exit(1)
leaks = subprocess.check_output(["strings", str(path)], text=True, errors="replace")
if "/tmp/xray-ohos" in leaks or "/path/to/user/go" in leaks:
    print("FAIL libxray.so embeds host workdir paths", file=sys.stderr)
    sys.exit(1)
from lib.native_strip import expected_packed_sha256
packed = expected_packed_sha256(path)
note = "sha256 is last clean rebuild; packedSha256 is llvm-strip --strip-all of that raw file, not a copy from HAP."
dest = root / lock["libxray"]["artifact"]
def _verify():
    verify_measured(measure_artifacts(root, json.loads(lock_path.read_text())), rebuilt_this_run=True, identity=identity)
publish_rebuilt_libxray(staged, dest, lock_path, digest, packed, note, _verify)
lock = json.loads(lock_path.read_text())
lock["libxray"]["frozenSha256"] = identity["frozenSha256"]
lock_path.write_text(json.dumps(lock, indent=2) + "\n")
man = root / ".runtime/r1-manifests"
man.mkdir(parents=True, exist_ok=True)
(man / "libxray-identity.json").write_text(json.dumps(identity, indent=2) + "\n")
print("libxray identity", digest, "bitIdentical", identity["bitIdenticalToLock"], "checkout", measured_commit)
print("OK libxray.so published after full verification")
PY
fi

echo "== hap =="
DST="$(mktemp -d /tmp/tongdao-r1.XXXXXX)"
HAP_HOME="$(mktemp -d /tmp/hap-home.XXXXXX)"
trap 'rm -rf "$DST" "$HAP_HOME"; release_pkg' EXIT
# Do not clobber operator HOME. Only the hap subshell uses HAP_HOME for ohpm/hvigor.
rsync -a \
  --exclude evidence \
  --exclude .git \
  --exclude third_party \
  --exclude .runtime \
  --exclude entry/build \
  --exclude oh_modules \
  --exclude entry/oh_modules \
  "$ROOT/" "$DST/"
PYTHONPATH="$ROOT/scripts" python3 - "$ROOT" "$DST" <<'PY'
import sys
from pathlib import Path
from lib.provenance import ProvenanceError, source_tree_digest
root, dest = Path(sys.argv[1]), Path(sys.argv[2])
a = source_tree_digest(root)
b = source_tree_digest(dest)
if a != b:
    raise ProvenanceError(f"root digest {a} != staged digest {b}")
(dest / "root-digest.txt").write_text(a)
(dest / "staged-digest.txt").write_text(a)
print("root==staged", a)
PY
ROOT_DIGEST="$(cat "$DST/root-digest.txt")"
STAGED_DIGEST="$(cat "$DST/staged-digest.txt")"
python3 - "$DST" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]) / 'entry/src/main/resources/rawfile/runtime'
p.mkdir(parents=True, exist_ok=True)
(p/'nodes.json').write_text('{"selected":"","nodes":[]}\n')
(p/'outbound.json').write_text('{}\n')
(p/'xray-config.json').write_text('{}\n')
(p/'node-meta.json').write_text('{"name":"","region":"","server":"","port":0,"protocol":"trojan"}\n')
print('runtime placeholders ok')
PY
PYTHONPATH="$ROOT/scripts" python3 - "$ROOT" "$DST" "$ROOT_DIGEST" <<'PY'
import sys
from pathlib import Path
from lib.provenance import ProvenanceError, source_tree_digest
root, dest = Path(sys.argv[1]), Path(sys.argv[2])
root_digest = sys.argv[3].strip()
if source_tree_digest(root) != root_digest:
    raise ProvenanceError("root changed while writing runtime placeholders")
staged = source_tree_digest(dest)
(dest / "staged-digest.txt").write_text(staged + "\n")
print("staged-after-placeholders", staged)
PY
STAGED_DIGEST="$(tr -d ' \n' < "$DST/staged-digest.txt")"
if [[ "${COMPILE_ONLY:-0}" == "1" ]]; then
python3 - "$DST/build-profile.json5" <<'PY'
import re, sys
from pathlib import Path
profile = Path(sys.argv[1])
text = profile.read_text()
text = re.sub(r"\n\s*signingConfigs:\s*\[[\s\S]*?\],", "\n", text, count=1)
text = re.sub(r"\n\s*signingConfig:\s*'default',", "\n", text)
profile.write_text(text)
print("COMPILE_ONLY: signing materials stripped from staged profile")
PY
else
python3 - "$DST/build-profile.json5" "$ROOT/.runtime/huawei-cbg/signing.json" <<'PY'
import json, re, sys
from pathlib import Path
profile, signing = Path(sys.argv[1]), Path(sys.argv[2])
if not signing.is_file():
    raise SystemExit("signing.json missing; refuse to put credentials in git")
doc = json.loads(signing.read_text())
key = str(doc.get("keyPassword") or "")
store = str(doc.get("storePassword") or "")
if not key or not store or key == "USE_SIGNING_JSON":
    raise SystemExit("signing.json incomplete")
text = profile.read_text()
text = re.sub(r"keyPassword:\s*'[^']*'", "keyPassword: '" + key.replace("\\", "\\\\").replace("'", "\\'") + "'", text, count=1)
text = re.sub(r"storePassword:\s*'[^']*'", "storePassword: '" + store.replace("\\", "\\\\").replace("'", "\\'") + "'", text, count=1)
profile.write_text(text)
print("build-profile passwords injected from signing.json")
PY
fi
cd "$DST"
PYTHONPATH="$ROOT/scripts" python3 - "$HAP_HOME" "$HVIGOR_USER_HOME" <<'PY'
import os
import sys
from lib.bounded_cmd import BoundedCmdError, run_bounded
hap_home, hvigor_home = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["HOME"] = hap_home
env["HVIGOR_USER_HOME"] = hvigor_home
try:
    command = ["ohpm", "install"]
    cache = env.get("TONGDAO_OHPM_CACHE", "")
    if cache:
        if not os.path.isdir(cache):
            raise SystemExit("configured dependency cache missing")
        command.extend(["--cache", cache])
    run_bounded(command, cwd=os.getcwd(), env=env, timeout=180)
except BoundedCmdError as exc:
    print("ohpm install failed", exc, file=sys.stderr)
    raise SystemExit(1)
print("ohpm install ok")
PY
set +e
PYTHONPATH="$ROOT/scripts" python3 - "$HAP_HOME" "$HVIGOR_USER_HOME" <<'PY'
import os
import subprocess
import sys
hap_home, hvigor_home = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["HOME"] = hap_home
env["HVIGOR_USER_HOME"] = hvigor_home
try:
    command = ["hvigorw", "assembleHap", "-p", "product=default", "-p", "buildMode=debug", "--no-daemon"]
    result = subprocess.run(
        command,
        cwd=os.getcwd(),
        env=env,
        timeout=420,
    )
except subprocess.TimeoutExpired:
    print("hvigor timed out", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
hv_rc=$?
set -e
UNSIGNED="$DST/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [[ ! -f "$UNSIGNED" ]]; then
  echo "unsigned hap missing (hvigor rc=$hv_rc)" >&2
  exit 1
fi
if [[ "${COMPILE_ONLY:-0}" == "1" ]]; then
  if [[ "$hv_rc" -ne 0 ]]; then
    echo "COMPILE_ONLY hvigor failed rc=$hv_rc" >&2
    exit 1
  fi
  KEEP_UNSIGNED="$ROOT/.runtime/r1-manifests/compile-only-unsigned.hap"
  mkdir -p "$ROOT/.runtime/r1-manifests"
  cp "$UNSIGNED" "$KEEP_UNSIGNED"
  echo "COMPILE_ONLY unsigned HAP $KEEP_UNSIGNED"
  ls -l "$KEEP_UNSIGNED"
  exit 0
fi
if [[ "$hv_rc" -ne 0 ]]; then
  if grep -R "Failed :entry:default@SignHap" "$DST/.hvigor/outputs/build-logs" >/dev/null 2>&1 \
    && { grep -R "EPERM: operation not permitted, stat" "$DST/.hvigor/outputs/build-logs" >/dev/null 2>&1 \
      || grep -R "Invalid initialization vector" "$DST/.hvigor/outputs/build-logs" >/dev/null 2>&1 \
      || grep -R "00303242 Configuration Error" "$DST/.hvigor/outputs/build-logs" >/dev/null 2>&1; }; then
    echo "hvigor rc=$hv_rc isolated to known SignHap failure in isolated HOME (ciphertext password undecryptable there); unsigned HAP kept, real signing runs next"
  else
    echo "hvigor failed rc=$hv_rc (not the known SignHap failure)" >&2
    exit 1
  fi
fi
SIGNED="$DST/entry-default-signed.hap"
TICKET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
python3 - "$UNSIGNED" "$DST/.sign-permit" "$TICKET" <<'PY'
import hashlib, os, sys
from pathlib import Path
unsigned, permit, ticket = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
fd = os.open(str(permit), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
try:
    os.write(fd, (hashlib.sha256(unsigned.read_bytes()).hexdigest() + " " + ticket + "\n").encode())
    os.fsync(fd)
finally:
    os.close(fd)
PY
export TONGDAO_SIGN_PERMIT="$DST/.sign-permit"
export TONGDAO_SIGN_TICKET="$TICKET"
zsh "$ROOT/scripts/huawei-sign-hap.sh" "$UNSIGNED" "$SIGNED"
PYTHONPATH="$ROOT/scripts" python3 - "$UNSIGNED" "$SIGNED" <<'PY'
import sys
from pathlib import Path
from lib.provenance import scan_hap_secrets
blocked = []
for hap in (Path(sys.argv[1]), Path(sys.argv[2])):
    blocked.extend(f"{hap.name}:{item}" for item in scan_hap_secrets(hap))
if blocked:
    print("HAP_SECRET_FAIL", ",".join(blocked), file=sys.stderr)
    sys.exit(1)
print("HAP_SECRET_SCAN_OK")
PY
python3 -c "
from pathlib import Path
p = Path('$ROOT/entry/build/default/outputs/default')
if not p.is_dir():
    p.mkdir(parents=True)
p = Path('$ROOT/.runtime/r1-manifests')
if not p.is_dir():
    p.mkdir(parents=True)
"
PYTHONPATH="$ROOT/scripts" python3 - "$ROOT" "$ROOT_DIGEST" <<'PY'
import sys
from pathlib import Path
from lib.provenance import ProvenanceError, source_tree_digest
root = Path(sys.argv[1])
want = sys.argv[2].strip()
got = source_tree_digest(root)
if got != want:
    raise ProvenanceError(f"root changed during build {got} != {want}")
print("root-unchanged", got)
PY
HAP_SHA=$(PYTHONPATH="$ROOT/scripts" python3 - "$SIGNED" "$ROOT/entry/build/default/outputs/default/entry-default-signed.hap" <<'PY'
import json, sys
from pathlib import Path
from lib.provenance import atomic_publish_hap
pub = atomic_publish_hap(Path(sys.argv[1]), Path(sys.argv[2]))
print(pub["sha256"])
Path(sys.argv[2]).parent.joinpath("tongdao-pub.json").write_text(json.dumps(pub))
PY
)
# pub json sits next to the published hap
PUBJSON="$ROOT/entry/build/default/outputs/default/tongdao-pub.json"
HAP_SIZE="$(wc -c < "$ROOT/entry/build/default/outputs/default/entry-default-signed.hap" | tr -d ' ')"
echo "signed $HAP_SIZE bytes sha256=$HAP_SHA"

WANT_NAME="$(python3 - "$APP_JSON" "$DST/want-code.txt" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
name = re.search(r'"versionName":\s*"([^"]+)"', text).group(1)
code = re.search(r'"versionCode":\s*([0-9]+)', text).group(1)
print(name)
Path(sys.argv[2]).write_text(code)
PY
)"
WANT_CODE="$(cat "$DST/want-code.txt")"

if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  echo "SKIP_INSTALL=1 signed copied to repo outputs, not installed"
  PYTHONPATH="$ROOT/scripts" python3 - "$LOCK" "$ROOT" "$HAP_SHA" "$HAP_SIZE" "$WANT_NAME" "$WANT_CODE" "${REBUILD_XRAY:-0}" "${REBUILD_HEV:-0}" "$UNSIGNED" "$SIGNED" "$STAGED_DIGEST" "$PUBJSON" "$SERIAL" <<'PY'
import json, os, sys
from pathlib import Path
from datetime import datetime
from lib.provenance import (
    AUTHORIZED_SIGNER_FINGERPRINT,
    assert_installable,
    atomic_publish_hap,
    atomic_publish_manifest,
    commit_latest_manifest,
    hap_module_identity,
    measure_artifacts,
    measure_hap_embedded_cores,
    measure_hap_sign_artifacts,
    sha256_file,
    source_tree_digest,
    unrecorded_env,
    verify_measured,
)
lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
staged = sys.argv[11].strip()
if source_tree_digest(root) != staged:
    print("FAIL root changed before manifest", file=sys.stderr)
    sys.exit(1)
measured = measure_artifacts(root, lock)
recorded = {
    "LIBXRAY_PIN": lock["libxray"]["commit"],
    "LIBXRAY_REPO": lock["libxray"]["repo"],
    "OHOS_GO_COMMIT": lock["go"].get("commit", ""),
    "OHOS_GO_FORK": str((root / lock["go"]["local_toolchain"]).resolve()),
    "HEV_TAG": lock["hev"]["tag"],
}
bad_env = unrecorded_env(os.environ, recorded)
if bad_env:
    print("FAIL unrecorded env override", bad_env, file=sys.stderr)
    sys.exit(1)
rebuilt = sys.argv[7] == "1"
hev_rebuilt = sys.argv[8] == "1"
identity = {}
ident_path = root / ".runtime/r1-manifests/libxray-identity.json"
if ident_path.is_file():
    identity = json.loads(ident_path.read_text())
verify_measured(measured, rebuilt_this_run=rebuilt, identity=identity)
unsigned_src = Path(sys.argv[9])
pubdoc = json.loads(Path(sys.argv[12]).read_text())
signed = Path(pubdoc.get("dest") or sys.argv[10])
if not unsigned_src.is_file() or not signed.is_file():
    print("FAIL unsigned/signed hap missing", file=sys.stderr)
    sys.exit(1)
upub = atomic_publish_hap(unsigned_src, root / "entry/build/default/outputs/default/entry-default-unsigned.hap")
unsigned = Path(upub["immutable"])
ident = hap_module_identity(signed)
sign = measure_hap_sign_artifacts(signed)
fp = sign["signerFingerprint"]
if ident["versionName"] != sys.argv[5] or ident["versionCode"] != sys.argv[6]:
    print("FAIL HAP version", ident, "!= AppScope", sys.argv[5], sys.argv[6], file=sys.stderr)
    sys.exit(1)
if fp.lower() != AUTHORIZED_SIGNER_FINGERPRINT.lower():
    print("FAIL measured HAP fingerprint", fp, file=sys.stderr)
    sys.exit(1)
cores = measure_hap_embedded_cores(signed)
if not cores["hapLibxraySha256"] or not cores["hapHevSha256"]:
    print("FAIL HAP missing embedded cores", file=sys.stderr)
    sys.exit(1)
hev_work = Path(os.environ.get("HEV_WORK_DIR") or "")
measured_hev = ""
if hev_rebuilt:
    receipt = hev_work / "measured-hev-commit.txt"
    if not receipt.is_file():
        print("FAIL missing measured HEV checkout receipt", file=sys.stderr)
        sys.exit(1)
    measured_hev = receipt.read_text().strip()
    pin = str(lock["hev"].get("commit") or "")
    if pin and pin not in measured_hev and not measured_hev.startswith(pin):
        print("FAIL measured HEV", measured_hev, "!=", pin, file=sys.stderr)
        sys.exit(1)
doc = {
    "serial": sys.argv[13],
    "skipInstall": True,
    "reason": "soak-safe; do not overwrite a running device session",
    "versionName": ident["versionName"],
    "versionCode": int(ident["versionCode"]),
    "hapSha256": sys.argv[3],
    "hapBytes": int(sys.argv[4]),
    "sourceTreeDigest": staged,
    "immutableHap": json.loads(Path(sys.argv[12]).read_text()).get("immutable", ""),
    "immutableUnsigned": str(unsigned),
    "measuredLibxraySha256": measured["measuredLibxraySha256"],
    "measuredHevSha256": measured["measuredHevSha256"],
    "measuredPatchSha256": measured["measuredPatchSha256"],
    "measuredGoCommit": measured.get("measuredGoCommit", ""),
    "lockLibxraySha256": lock["libxray"]["sha256"],
    "lockHevSha256": lock["hev"]["sha256"],
    "libxrayCommit": lock["libxray"]["commit"],
    "xrayCore": lock["libxray"]["xray_core"],
    "hevTag": lock["hev"]["tag"],
    "rebuildXray": sys.argv[7],
    "rebuildHev": sys.argv[8],
    "secretScan": "ok",
    "copiedFromLock": False,
    "signerFingerprint": fp,
    "fingerprint": fp,
    "measuredFromHap": True,
    "hapLibxraySha256": cores["hapLibxraySha256"],
    "hapHevSha256": cores["hapHevSha256"],
    "lockedHevCommit": lock["hev"].get("commit", ""),
    "measuredHevCheckout": measured_hev,
    "ohosNdk": measured.get("ohosNdk", ""),
    "clang": measured.get("clang", ""),
    "clangVersion": measured.get("clangVersion", ""),
    "clangSha256": measured.get("clangSha256", ""),
    "unsignedHapSha256": upub["sha256"],
    "signedHapSha256": sha256_file(signed),
    "profileSha256": sign["profileSha256"],
    "appCertSha256": sign["appCertSha256"],
    "note": "HAP has no node passwords. Provenance hashed on-disk artifacts. Not STAGE_1_PASS.",
    "bundleName": "com.oscarwoltz.tongdao",
}
for key in ("unsignedHapSha256", "signedHapSha256", "profileSha256", "appCertSha256"):
    if not doc[key]:
        print("FAIL missing", key, file=sys.stderr)
        sys.exit(1)
man_dir = root / ".runtime/r1-manifests"
man_dir.mkdir(parents=True, exist_ok=True)
skip_latest = man_dir / "latest-skip-install.json"
signed_latest = man_dir / "latest-signed.json"
pubm = atomic_publish_manifest(doc, skip_latest, commit_latest=False)
atomic_publish_manifest(doc, signed_latest, commit_latest=False)
assert_installable(root, signed, doc, unsigned=unsigned)
commit_latest_manifest(pubm["immutable"], skip_latest)
commit_latest_manifest(pubm["immutable"], signed_latest)
print("skip-install manifest", pubm["immutable"])
print("measured libxray", measured["measuredLibxraySha256"])
print("measured hev", measured["measuredHevSha256"])
print("hap libxray", cores["hapLibxraySha256"])
PY
  echo "R1 package signed, not installed (soak-safe)."
  exit 0
fi
echo "== install X5 =="
PYTHONPATH="$ROOT/scripts" python3 - "$ROOT" "$SIGNED" "$UNSIGNED" "$ROOT/.runtime/r1-manifests/latest-skip-install.json" <<'PY'
import json, sys
from pathlib import Path
from lib.provenance import ProvenanceError, assert_installable
root, signed, unsigned, man = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
if not man.is_file():
    raise SystemExit("complete skip-quality manifest required before install")
doc = json.loads(man.read_text())
print("installable", assert_installable(root, signed, doc, unsigned=unsigned))
PY
"$HDC" -t "$SERIAL" install -r "$SIGNED"
DUMP="$MANIFEST_DIR/bm-dump-latest.txt"
"$HDC" -t "$SERIAL" shell "bm dump -n $BUNDLE" > "$DUMP"
PYTHONPATH="$ROOT/scripts" python3 - "$DUMP" "$WANT_NAME" "$WANT_CODE" "$BUNDLE" <<'PY'
import sys
from pathlib import Path
from lib.provenance import check_install_dump
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
got = check_install_dump(text, sys.argv[2], sys.argv[3], sys.argv[4])
for key in ("bundleName", "versionName", "versionCode", "appProvisionType", "debug", "fingerprint"):
    print(key, got.get(key, ""))
print("install readback OK")
PY

STAMP="$(date +%Y%m%d-%H%M%S)"
MANIFEST="$MANIFEST_DIR/install-$STAMP.json"
PYTHONPATH="$ROOT/scripts" python3 - "$LOCK" "$ROOT" "$HAP_SHA" "$HAP_SIZE" "$SIGNED" "$DUMP" "$MANIFEST" "$STAMP" "$SERIAL" <<'PY'
import json, os, sys
from pathlib import Path
from datetime import datetime
from lib.provenance import (
    AUTHORIZED_SIGNER_FINGERPRINT,
    hap_module_identity,
    measure_artifacts,
    measure_hap_signer_fingerprint,
    sha256_file,
    source_tree_digest,
)
lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
signed = Path(sys.argv[5])
ident = hap_module_identity(signed)
fp = measure_hap_signer_fingerprint(signed)
if fp.lower() != AUTHORIZED_SIGNER_FINGERPRINT.lower():
    raise SystemExit(f"HAP fingerprint {fp} not authorized")
measured = measure_artifacts(root, lock)
doc = {
    "serial": sys.argv[9],
    "skipInstall": False,
    "versionName": ident["versionName"],
    "versionCode": int(ident["versionCode"]),
    "hapSha256": sys.argv[3],
    "hapBytes": int(sys.argv[4]),
    "sourceTreeDigest": source_tree_digest(root),
    "signerFingerprint": fp,
    "fingerprint": fp,
    "measuredFromHap": True,
    "measuredLibxraySha256": measured["measuredLibxraySha256"],
    "measuredHevSha256": measured["measuredHevSha256"],
    "measuredPatchSha256": measured["measuredPatchSha256"],
    "hevCheckout": measured.get("measuredHevCheckout") or lock["hev"].get("commit", ""),
    "ohosNdk": measured.get("ohosNdk", ""),
    "clang": measured.get("clang", ""),
    "clangSha256": measured.get("clangSha256", ""),
    "clangVersion": measured.get("clangVersion", ""),
    "signingInputSha256": sha256_file(signed),
    "note": "Same immutable manifest as skip-install. Not STAGE_1_PASS.",
}
# Do not overwrite latest-signed with a weak install receipt.
path = Path(sys.argv[7])
path.write_text(json.dumps(doc, indent=2) + "\n")
print("install receipt", path, "(latest-signed unchanged)")
PY
echo "R1 package installed. Import nodes privately before start. HAP has no node passwords."
echo "NOT STAGE_1_PASS. SOCKS canary is health only."
