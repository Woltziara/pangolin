"""Measured build provenance. CORE_LOCK declarations are not actual inputs."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Any, Callable, Mapping

SECRET_KEYS = ("password", "passwd", "token", "secret", "privateKey")
SHARE_SCHEMES = ("trojan://", "vless://", "ss://", "vmess://")

SENSITIVE_ENV = (
    "LIBXRAY_PIN",
    "LIBXRAY_SRC",
    "LIBXRAY_REPO",
    "OHOS_GO_COMMIT",
    "OHOS_GO_FORK",
    "GOFLAGS",
    "GO_TAGS",
    "GO_LDFLAGS",
    "HEV_SRC",
    "HEV_TAG",
    "CC",
    "CXX",
    "CGO_CFLAGS",
    "CGO_LDFLAGS",
)

ALLOWED_ENV = {
    "SKIP_INSTALL",
    "REBUILD_XRAY",
    "REBUILD_HEV",
    "TONGDAO_ISOLATE_HOME",
    "HVIGOR_USER_HOME",
    "XRAY_WORK_DIR",
    "HEV_WORK_DIR",
    "GOPATH",
    "GOCACHE",
    "GOMODCACHE",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "JAVA_HOME",
    "DEVECO_SDK_HOME",
    "HOS_SDK_HOME",
    "PATH",
    "HOME",
    "GOTOOLCHAIN",
    "CGO_CFLAGS",
    "CGO_ENABLED",
    "CGO_LDFLAGS",
    "CC",
    "CXX",
    "OHOS_NATIVE_HOME",
    "LIBXRAY_REPO",
    "LIBXRAY_PIN",
    "LIBXRAY_SRC",
    "OHOS_GO_FORK",
    "OHOS_GO_COMMIT",
    "HEV_SRC",
    "HEV_TAG",
    "GOFLAGS",
    "GO_TAGS",
    "GO_LDFLAGS",
    "GOROOT",
    "GOPROXY",
    "GOSUMDB",
    "GO111MODULE",
    "GOTMPDIR",
    "TMPDIR",
    "NODE",
    "MATERIAL_DIR",
    "PROFILE",
}

EXPECT_PROVISION = "debug"
EXPECT_DEBUG = "true"
AUTHORIZED_SIGNER_FINGERPRINT = "41729BE2333D65F43406B8A4144AFE5986238C5A54F9A875ADBD095FEC2E8717"
EXPECT_BUNDLE = "com.oscarwoltz.tongdao"


class ProvenanceError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def scan_hap_secrets(hap: Path) -> list[str]:
    blocked: list[str] = []
    key_re = re.compile(
        r'"(?:' + "|".join(SECRET_KEYS) + r')"\s*:\s*"(?!")[^"]{4,}"',
        re.I,
    )
    with zipfile.ZipFile(hap) as zf:
        for name in zf.namelist():
            lower = name.lower().replace("\\", "/")
            if "/.runtime/" in f"/{lower}" or lower.startswith(".runtime/"):
                blocked.append(f"{name}:runtime-dir")
                continue
            if not (lower.endswith(".json") or "rawfile/runtime" in lower or lower.endswith(".txt")):
                continue
            raw = zf.read(name)
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
            if key_re.search(text):
                blocked.append(f"{name}:secret-field")
            for scheme in SHARE_SCHEMES:
                if scheme in text:
                    blocked.append(f"{name}:share-link")
            if "rawfile/runtime" in lower:
                try:
                    doc = json.loads(text)
                except json.JSONDecodeError:
                    blocked.append(f"{name}:invalid-json")
                    continue
                blob = json.dumps(doc)
                if re.search(r'"server"\s*:\s*"[^"]+"', blob) and '"nodes":[]' not in blob:
                    blocked.append(f"{name}:node-server")
    return blocked


def _dir_fsync(path: Path) -> None:
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write_bytes(dest: Path, data: bytes, *, mode: int = 0o644) -> None:
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    nonce = f"{os.getpid()}.{time.time_ns()}"
    tmp = dest.with_name(f".{dest.name}.{nonce}.tmp")
    fd = os.open(str(tmp), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(str(tmp), str(dest))
    os.chmod(dest, mode)
    _dir_fsync(dest.parent)


def atomic_write_text(dest: Path, text: str, *, mode: int = 0o644) -> None:
    atomic_write_bytes(dest, text.encode("utf-8"), mode=mode)


def atomic_publish_hap(src: Path, dest: Path) -> dict[str, str]:
    """Content-addressed publish: unique temp, rehash, atomic rename, readonly."""
    dest = Path(dest)
    src = Path(src)
    dest.parent.mkdir(parents=True, exist_ok=True)
    digest = sha256_file(src)
    frozen = dest.with_name(f"{dest.stem}.{digest}{dest.suffix}")
    if frozen.exists():
        existing = sha256_file(frozen)
        if existing != digest:
            raise ProvenanceError(
                f"content-addressed object corrupt {frozen.name} have {existing} want {digest}"
            )
    else:
        payload = src.read_bytes()
        nonce = f"{os.getpid()}.{time.time_ns()}"
        tmp = dest.with_name(f".{dest.stem}.{digest}.{nonce}.tmp")
        fd = os.open(str(tmp), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, payload)
            os.fsync(fd)
        finally:
            os.close(fd)
        got = sha256_file(tmp)
        if got != digest:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise ProvenanceError(f"frozen tmp hash {got} != {digest}")
        os.replace(str(tmp), str(frozen))
        _dir_fsync(dest.parent)
    os.chmod(frozen, 0o444)
    if sha256_file(frozen) != digest:
        raise ProvenanceError(f"frozen hash mismatch after publish {frozen}")
    canonical = frozen.read_bytes()
    if hashlib.sha256(canonical).hexdigest() != digest:
        raise ProvenanceError("canonical payload hash mismatch")
    pub_tmp = dest.with_name(f".{dest.name}.{os.getpid()}.{time.time_ns()}.pub")
    fd = os.open(str(pub_tmp), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, canonical)
        os.fsync(fd)
    finally:
        os.close(fd)
    if hashlib.sha256(pub_tmp.read_bytes()).hexdigest() != digest:
        os.unlink(pub_tmp)
        raise ProvenanceError("publish tmp hash mismatch")
    os.replace(str(pub_tmp), str(dest))
    _dir_fsync(dest.parent)
    return {"sha256": digest, "immutable": str(frozen), "dest": str(dest)}


SOURCE_INPUTS = (
    "entry/src/main/ets",
    "entry/src/main/cpp/napi_init.cpp",
    "entry/src/main/cpp/app_flow_router.cpp",
    "entry/src/main/cpp/app_flow_router.h",
    "entry/src/main/cpp/CMakeLists.txt",
    "entry/src/main/cpp/types",
    "entry/src/main/module.json5",
    "entry/src/main/resources",
    "AppScope/app.json5",
    "AppScope/resources",
    "native/CORE_LOCK.json",
    "native/GEO_LOCK.json",
    "native/patches",
    "oh-package.json5",
    "oh-package-lock.json5",
    "entry/oh-package.json5",
    "entry/oh-package-lock.json5",
    "build-profile.json5",
    "entry/build-profile.json5",
    "hvigor/hvigor-config.json5",
    "hvigorfile.ts",
    "entry/hvigorfile.ts",
    "scripts/r1-build.sh",
    "scripts/restore_geo.py",
    "scripts/huawei-sign-hap.js",
    "scripts/huawei-sign-hap.sh",
    "scripts/lib/provenance.py",
    "scripts/lib/hvigor_pnpm.py",
    "scripts/lib/bounded_cmd.py",
    "scripts/lib/hdc_singleton.py",
    "scripts/lib/stage1_loop.py",
    "scripts/stage1-loop.py",
    "scripts/build_libxray_ohos.sh",
    "scripts/build_hev_ohos.sh",
    "scripts/publish_hev_stage.py",
    "tests/hev_udp_first_packet_test.py",
    "tests/hev_udp_first_packet_fixture.c",
)
_SKIP_SUFFIX = {".o", ".a", ".pyc"}


def iter_source_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for spec in SOURCE_INPUTS:
        path = root / spec
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(p for p in path.rglob("*") if p.is_file()))
    out: list[Path] = []
    for path in files:
        if path.suffix.lower() in _SKIP_SUFFIX:
            continue
        rel = path.as_posix()
        if "/rawfile/runtime/" in rel.replace("\\", "/"):
            continue
        out.append(path)
    return out


def atomic_publish_manifest(doc: Mapping[str, Any], latest: Path, *, commit_latest: bool = False) -> dict[str, str]:
    latest = Path(latest)
    latest.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(dict(doc), indent=2) + "\n"
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    frozen = latest.with_name(f"{latest.stem}.{digest}.json")
    atomic_write_bytes(frozen, payload.encode("utf-8"), mode=0o444)
    os.chmod(frozen, 0o444)
    if commit_latest:
        commit_latest_manifest(frozen, latest)
    return {"sha256": digest, "immutable": str(frozen), "latest": str(latest)}


def commit_latest_manifest(frozen: Path, latest: Path) -> None:
    payload = Path(frozen).read_bytes()
    atomic_write_bytes(latest, payload, mode=0o644)


def source_tree_digest(root: Path) -> str:
    hasher = hashlib.sha256()
    for path in iter_source_files(root):
        rel = path.relative_to(root).as_posix().encode("utf-8")
        hasher.update(rel)
        hasher.update(b"\0")
        hasher.update(path.read_bytes())
        hasher.update(b"\n")
    return hasher.hexdigest()


def newest_source_mtime(root: Path) -> float:
    times = [p.stat().st_mtime for p in iter_source_files(root)]
    return max(times) if times else 0.0


def check_source_matches_artifact(root: Path, hap: Path, manifest: Mapping[str, Any]) -> dict[str, str]:
    want = str(manifest.get("sourceTreeDigest") or "")
    if not want:
        raise ProvenanceError("manifest missing sourceTreeDigest; refuse install")
    digest = source_tree_digest(root)
    if digest != want:
        raise ProvenanceError(f"source digest {digest} != manifest {want}")
    if not hap.is_file():
        raise ProvenanceError("hap missing")
    newest = newest_source_mtime(root)
    if newest > hap.stat().st_mtime + 1.0:
        raise ProvenanceError("source newer than hap artifact; refuse stale package")
    return {"sourceTreeDigest": digest}


def measure_hap_embedded_cores(hap: Path) -> dict[str, str]:
    out = {
        "hapLibxraySha256": "",
        "hapHevSha256": "",
        "hapLibxrayName": "",
        "hapHevName": "",
    }
    with zipfile.ZipFile(hap) as zf:
        for name in zf.namelist():
            lower = name.lower().replace("\\", "/")
            if lower.endswith("libxray.so"):
                out["hapLibxraySha256"] = hashlib.sha256(zf.read(name)).hexdigest()
                out["hapLibxrayName"] = name
            if lower.endswith("libhevsocks5tun.so"):
                out["hapHevSha256"] = hashlib.sha256(zf.read(name)).hexdigest()
                out["hapHevName"] = name
    return out


def check_manifest_gate(manifest: Mapping[str, Any], *, hap_sha: str, root: Path | None = None) -> None:
    if "bundleName" not in manifest or not str(manifest.get("bundleName") or ""):
        raise ProvenanceError("manifest missing bundleName")
    bundle = str(manifest.get("bundleName") or "")
    if bundle != EXPECT_BUNDLE:
        raise ProvenanceError(f"wrong bundle {bundle}")
    if str(manifest.get("secretScan") or "") != "ok":
        raise ProvenanceError("secretScan failed")
    immutable = str(manifest.get("immutableHap") or "")
    if not immutable:
        raise ProvenanceError("manifest missing immutableHap")
    imm = Path(immutable)
    if not imm.is_file():
        raise ProvenanceError("immutableHap missing")
    if sha256_file(imm) != hap_sha:
        raise ProvenanceError("immutableHap hash mismatch")
    man_fp = str(manifest.get("signerFingerprint") or manifest.get("fingerprint") or "")
    if man_fp and man_fp.lower() != AUTHORIZED_SIGNER_FINGERPRINT.lower():
        raise ProvenanceError("forged signature hash")
    for key in (
        "lockLibxraySha256",
        "lockHevSha256",
        "lockedHevCommit",
        "clang",
        "hapLibxraySha256",
        "hapHevSha256",
        "unsignedHapSha256",
        "profileSha256",
        "appCertSha256",
    ):
        if not str(manifest.get(key) or ""):
            raise ProvenanceError(f"manifest missing core/lock receipt {key}")
    if root is not None:
        lock = json.loads((Path(root) / "native/CORE_LOCK.json").read_text(encoding="utf-8"))
        if str(manifest.get("lockLibxraySha256") or "") != str(lock["libxray"]["sha256"]):
            raise ProvenanceError("forged lockLibxraySha256")
        if str(manifest.get("lockHevSha256") or "") != str(lock["hev"]["sha256"]):
            raise ProvenanceError("forged lockHevSha256")
        packed_xray = str(lock["libxray"].get("packedSha256") or "")
        packed_hev = str(lock["hev"].get("packedSha256") or "")
        if not packed_xray or not packed_hev:
            raise ProvenanceError("CORE_LOCK missing packedSha256 for post-strip libraries")
        if str(manifest.get("hapLibxraySha256") or "") != packed_xray:
            raise ProvenanceError("hapLibxraySha256 is not the locked post-strip library")
        if str(manifest.get("hapHevSha256") or "") != packed_hev:
            raise ProvenanceError("hapHevSha256 is not the locked post-strip library")
        try:
            from lib.native_strip import expected_packed_sha256, find_llvm_strip

            strip = find_llvm_strip(Path(root))
            raw_x = Path(root) / str(lock["libxray"]["artifact"])
            raw_h = Path(root) / str(lock["hev"]["artifact"])
            if raw_x.is_file() and expected_packed_sha256(raw_x, strip) != packed_xray:
                raise ProvenanceError("packedSha256 is not llvm-strip --strip-all of locked raw libxray")
            if raw_h.is_file() and expected_packed_sha256(raw_h, strip) != packed_hev:
                raise ProvenanceError("packedSha256 is not llvm-strip --strip-all of locked raw hev")
        except FileNotFoundError:
            raise ProvenanceError("llvm-strip missing; cannot replay raw→packed")


def assert_installable(
    root: Path,
    hap: Path,
    manifest: Mapping[str, Any],
    unsigned: Path | None = None,
) -> dict[str, str]:
    out = {}
    out.update(check_hap_artifact(hap, manifest))
    out.update(check_source_matches_artifact(root, hap, manifest))
    want_name = str(manifest.get("versionName") or "")
    want_code = str(manifest.get("versionCode") or "")
    if not want_name or not want_code:
        raise ProvenanceError("manifest missing versionName/versionCode")
    check_manifest_gate(manifest, hap_sha=str(manifest.get("hapSha256") or out.get("sha256") or ""), root=root)
    ident = hap_module_identity(hap)
    if ident["versionName"] != want_name or str(ident["versionCode"]) != str(want_code):
        raise ProvenanceError(f"HAP module identity {ident} != manifest {want_name}/{want_code}")
    if "bundleName" not in manifest:
        raise ProvenanceError("manifest missing bundleName")
    bundle = str(ident.get("bundleName") or "")
    want_bundle = str(manifest.get("bundleName") or "")
    if not want_bundle:
        raise ProvenanceError("manifest missing bundleName")
    if not bundle:
        raise ProvenanceError("HAP module.json missing bundleName")
    if bundle != want_bundle:
        raise ProvenanceError(f"wrong bundle {bundle} want {want_bundle}")
    if bundle != EXPECT_BUNDLE:
        raise ProvenanceError(f"wrong bundle {bundle}")
    out["versionName"] = ident["versionName"]
    out["versionCode"] = ident["versionCode"]
    out["bundleName"] = bundle
    sign = measure_hap_sign_artifacts(hap)
    fp = sign["signerFingerprint"]
    if fp.lower() != AUTHORIZED_SIGNER_FINGERPRINT.lower():
        raise ProvenanceError(f"HAP signer {fp} not authorized")
    man_fp = str(manifest.get("signerFingerprint") or manifest.get("fingerprint") or "")
    if not man_fp:
        raise ProvenanceError("manifest missing signerFingerprint")
    if man_fp.lower() != fp.lower():
        raise ProvenanceError("forged signature hash: manifest signerFingerprint does not match re-read HAP")
    if str(manifest.get("profileSha256") or "") != sign["profileSha256"]:
        raise ProvenanceError("forged profileSha256")
    if str(manifest.get("appCertSha256") or "") != sign["appCertSha256"]:
        raise ProvenanceError("forged appCertSha256")
    out["signerFingerprint"] = fp
    cores = measure_hap_embedded_cores(hap)
    if not cores["hapLibxraySha256"] or not cores["hapHevSha256"]:
        raise ProvenanceError("HAP missing embedded libxray/HEV")
    want_xray = str(manifest.get("hapLibxraySha256") or "")
    want_hev = str(manifest.get("hapHevSha256") or "")
    if not want_xray:
        raise ProvenanceError("manifest missing hapLibxraySha256")
    if not want_hev:
        raise ProvenanceError("manifest missing hapHevSha256")
    if want_xray != cores["hapLibxraySha256"]:
        raise ProvenanceError("hapLibxraySha256 mismatch vs embedded")
    if want_hev != cores["hapHevSha256"]:
        raise ProvenanceError("hapHevSha256 mismatch vs embedded")
    want_u = str(manifest.get("unsignedHapSha256") or "")
    if not want_u:
        raise ProvenanceError("manifest missing unsignedHapSha256")
    if unsigned is None:
        imm_u = str(manifest.get("immutableUnsigned") or "")
        unsigned = Path(imm_u) if imm_u else None
    if unsigned is None:
        raise ProvenanceError("unsigned hap not provided to verify unsignedHapSha256")
    unsigned = Path(unsigned)
    if not unsigned.is_file():
        raise ProvenanceError("unsigned hap missing")
    got_u = sha256_file(unsigned)
    if got_u != want_u:
        raise ProvenanceError("forged unsignedHapSha256")
    u_ident = hap_module_identity(unsigned)
    if u_ident.get("bundleName") != ident.get("bundleName") or u_ident.get("versionName") != ident.get("versionName"):
        raise ProvenanceError("unsigned hap identity does not match signed")
    u_cores = measure_hap_embedded_cores(unsigned)
    if u_cores.get("hapLibxraySha256") != cores.get("hapLibxraySha256") or u_cores.get("hapHevSha256") != cores.get(
        "hapHevSha256"
    ):
        raise ProvenanceError("unsigned embedded cores do not match signed")
    out.update(cores)
    out["immutableUnsigned"] = str(manifest.get("immutableUnsigned") or unsigned)
    out["immutableHap"] = str(manifest.get("immutableHap") or "")
    return out


def check_hap_artifact(hap: Path, manifest: Mapping[str, Any]) -> dict[str, str]:
    if not hap.is_file():
        raise ProvenanceError("hap missing")
    digest = sha256_file(hap)
    want = str(manifest.get("hapSha256") or "")
    if not want or digest != want:
        raise ProvenanceError(f"hap hash {digest} != manifest {want}")
    size = hap.stat().st_size
    want_size = int(manifest.get("hapBytes") or 0)
    if want_size and size != want_size:
        raise ProvenanceError(f"hap bytes {size} != manifest {want_size}")
    return {"sha256": digest, "bytes": str(size)}


def git_tracked_producers(root: Path, gitignore_text: str = "") -> list[str]:
    needed = [
        "native/CORE_LOCK.json",
        "native/GEO_LOCK.json",
        "native/patches/libxray-cgohello.patch",
        "scripts/r1-build.sh",
        "scripts/restore_geo.py",
        "scripts/lib/provenance.py",
        "tests/test_audit_gaps.py",
    ]
    env = os.environ.copy()
    gitconfig = env.get("GIT_CONFIG_GLOBAL") or "/dev/null"
    env["GIT_CONFIG_GLOBAL"] = gitconfig
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    try:
        out = subprocess.check_output(
            ["git", "-C", str(root), "ls-files"],
            env=env,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        return [f"git-ls-files-failed:{exc}"]
    tracked = {ln.strip() for ln in out.splitlines() if ln.strip()}
    missing = []
    for rel in needed:
        if not (root / rel).is_file():
            missing.append(rel)
        if rel not in tracked:
            missing.append(f"untracked:{rel}")
        if gitignore_text and any(
            line.strip() == rel or line.strip() == "/" + rel for line in gitignore_text.splitlines()
        ):
            missing.append(f"gitignore:{rel}")
    return missing


def check_install_dump(
    text: str,
    want_name: str,
    want_code: str,
    bundle: str,
    want_fingerprint: str = AUTHORIZED_SIGNER_FINGERPRINT,
) -> dict[str, str]:
    def grab_str(key: str) -> str:
        vals = re.findall(r'"%s":\s*"([^"]*)"' % key, text)
        for val in vals:
            if val:
                return val
        return ""

    def grab_bool(key: str) -> str:
        match = re.search(r'"%s":\s*(true|false)' % key, text)
        return match.group(1) if match else ""

    codes = [int(x) for x in re.findall(r'"versionCode":\s*([0-9]+)', text)]
    got = {
        "bundleName": grab_str("bundleName"),
        "versionName": grab_str("versionName"),
        "versionCode": str(max(codes) if codes else ""),
        "appProvisionType": grab_str("appProvisionType"),
        "debug": grab_bool("debug"),
        "fingerprint": grab_str("fingerprint"),
    }
    failed: list[str] = []
    if got["bundleName"] != bundle:
        failed.append(f"bundle {got['bundleName']}")
    if got["versionName"] != want_name:
        failed.append(f"versionName {got['versionName']} want {want_name}")
    if got["versionCode"] != str(want_code):
        failed.append(f"versionCode {got['versionCode']} want {want_code}")
    if got["appProvisionType"] != EXPECT_PROVISION:
        failed.append(f"appProvisionType {got['appProvisionType']} want {EXPECT_PROVISION}")
    if got["debug"] != EXPECT_DEBUG:
        failed.append(f"debug {got['debug']} want {EXPECT_DEBUG}")
    if not re.fullmatch(r"[0-9A-Fa-f]{64}", got["fingerprint"] or ""):
        failed.append("signature fingerprint missing")
    if want_fingerprint and got["fingerprint"].lower() != want_fingerprint.lower():
        failed.append(f"fingerprint {got['fingerprint']} want {want_fingerprint}")
    if failed:
        raise ProvenanceError("install_readback " + "; ".join(failed))
    return got


def unrecorded_env(environ: Mapping[str, str], recorded: Mapping[str, str] | None = None) -> list[str]:
    recorded = recorded or {}
    bad: list[str] = []
    for key in SENSITIVE_ENV:
        if key not in environ:
            continue
        if key not in recorded:
            bad.append(key)
        elif environ[key] != recorded[key]:
            bad.append(f"{key} override {environ[key]!r} != recorded {recorded[key]!r}")
    extra_re = re.compile(r"^(LIBXRAY_|XRAY_PATCH|HEV_PIN|HEV_SRC|GOFLAGS|GO_TAGS)")
    for key in environ:
        if extra_re.match(key) and key not in recorded and key not in bad:
            bad.append(key)
    return bad


def measure_artifacts(root: Path, lock: dict[str, Any]) -> dict[str, Any]:
    libxray = root / lock["libxray"]["artifact"]
    hev = root / lock["hev"]["artifact"]
    patch = root / "native/patches/libxray-cgohello.patch"
    go_fork = Path(lock["go"].get("local_toolchain") or "")
    if not go_fork.is_absolute():
        go_fork = root / go_fork
    measured_go_commit = ""
    git_head = go_fork / ".git"
    if git_head.exists() or (go_fork / ".git").exists():
        head = go_fork / ".git" / "HEAD"
        if head.is_file():
            raw = head.read_text().strip()
            if raw.startswith("ref:"):
                ref = go_fork / ".git" / raw.split(" ", 1)[1].strip()
                if ref.is_file():
                    measured_go_commit = ref.read_text().strip()
            else:
                measured_go_commit = raw
    ndk = os.environ.get("OHOS_NATIVE_HOME") or ""
    sdk = os.environ.get("DEVECO_SDK_HOME") or "/Applications/DevEco-Studio.app/Contents/sdk"
    if not ndk:
        for cand in (
            Path(sdk) / "default/openharmony/native",
            Path("/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"),
        ):
            if cand.is_dir():
                ndk = str(cand)
                break
    clang = os.environ.get("CC", "")
    if ndk:
        cross = Path(ndk) / "llvm/bin/aarch64-unknown-linux-ohos-clang"
        generic = Path(ndk) / "llvm/bin/clang"
        if not clang:
            if cross.is_file():
                clang = str(cross)
            elif generic.is_file():
                clang = str(generic)
        elif Path(clang).name == "clang" and cross.is_file():
            clang = str(cross)
    clang_ver = ""
    if clang:
        try:
            clang_ver = subprocess.check_output([clang, "--version"], text=True, timeout=8).splitlines()[0]
        except (OSError, subprocess.CalledProcessError, IndexError):
            clang_ver = ""
    hev_checkout = ""
    hev_work = Path(os.environ.get("HEV_WORK_DIR") or "")
    receipt = hev_work / "measured-hev-commit.txt" if hev_work else Path()
    if receipt.is_file():
        hev_checkout = receipt.read_text().strip()
    clang_hash = sha256_file(Path(clang)) if clang and Path(clang).is_file() else ""
    return {
        "measuredLibxraySha256": sha256_file(libxray) if libxray.is_file() else "",
        "measuredHevSha256": sha256_file(hev) if hev.is_file() else "",
        "measuredPatchSha256": sha256_file(patch) if patch.is_file() else "",
        "measuredGoCommit": measured_go_commit,
        "measuredHevCheckout": hev_checkout,
        "ohosNdk": ndk,
        "clang": clang,
        "clangVersion": clang_ver,
        "clangSha256": clang_hash,
        "lockLibxraySha256": lock["libxray"]["sha256"],
        "lockHevSha256": lock["hev"]["sha256"],
        "lockLibxrayCommit": lock["libxray"]["commit"],
        "lockGoCommit": lock["go"].get("commit", ""),
        "lockGoVersion": lock["go"].get("version", ""),
        "lockHevCheckout": lock.get("hev", {}).get("commit", ""),
        "authorizedSignerFingerprint": AUTHORIZED_SIGNER_FINGERPRINT,
    }


def verify_measured(measured: Mapping[str, Any], *, rebuilt_this_run: bool, identity: Mapping[str, Any] | None = None) -> None:
    if not measured.get("measuredLibxraySha256"):
        raise ProvenanceError("missing measured libxray sha256")
    if not measured.get("measuredHevSha256"):
        raise ProvenanceError("missing measured hev sha256")
    if not measured.get("measuredPatchSha256"):
        raise ProvenanceError("missing measured patch sha256")
    identity = identity or {}
    # CORE_LOCK declaration must not impersonate a rebuild measurement.
    if rebuilt_this_run:
        declared = identity.get("libxrayCommit")
        if declared and not identity.get("measuredCheckoutCommit"):
            raise ProvenanceError("CORE_LOCK commit used without measured checkout")
        if identity.get("rebuiltSha256") == measured.get("lockLibxraySha256") and identity.get("copiedFromLock"):
            raise ProvenanceError("lock hash copied as rebuilt sha256")
        from lib.native_strip import expected_packed_sha256, find_llvm_strip

        root = Path(__file__).resolve().parents[2]
        lock = json.loads((root / "native/CORE_LOCK.json").read_text(encoding="utf-8"))
        strip = find_llvm_strip(root)
        raw_x = root / str(lock["libxray"]["artifact"])
        packed = expected_packed_sha256(raw_x, strip)
        want = str(lock["libxray"].get("packedSha256") or "")
        if packed != want:
            raise ProvenanceError(
                f"rebuilt packed {packed} != CORE_LOCK.packedSha256 {want}; "
                "update sha256 and packedSha256 from llvm-strip --strip-all of the new raw .so, not from HAP"
            )
    if not rebuilt_this_run:
        if measured["measuredLibxraySha256"] != measured["lockLibxraySha256"]:
            raise ProvenanceError("on-disk libxray sha256 != CORE_LOCK")
        if measured["measuredHevSha256"] != measured["lockHevSha256"]:
            raise ProvenanceError("on-disk hev sha256 != CORE_LOCK")


def publish_rebuilt_libxray(
    staged: Path,
    dest: Path,
    lock_path: Path,
    digest: str,
    packed: str,
    note: str,
    verify: Callable[[], None],
    component: str = "libxray",
) -> None:
    """Copy a verified staged .so into prebuilt and update lock; roll back both on verify failure."""
    if component not in ("libxray", "hev"):
        raise ProvenanceError("unknown native component")
    if not staged.is_file():
        raise ProvenanceError(f"staged libxray missing: {staged}")
    old_so = dest.read_bytes() if dest.is_file() else b""
    old_lock = lock_path.read_text(encoding="utf-8") if lock_path.is_file() else ""
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(staged, dest)
        lock = json.loads(old_lock) if old_lock else {}
        libxray = dict(lock.get(component) or {})
        libxray["sha256"] = digest
        libxray["packedSha256"] = packed
        lock[component] = libxray
        lock["note"] = note
        lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
        verify()
    except Exception:
        if old_so:
            dest.write_bytes(old_so)
        if old_lock:
            lock_path.write_text(old_lock, encoding="utf-8")
        raise


def hap_module_identity(hap: Path) -> dict[str, str]:
    if not hap.is_file():
        raise ProvenanceError("hap missing")
    try:
        zf = zipfile.ZipFile(hap)
    except zipfile.BadZipFile as exc:
        raise ProvenanceError(f"HAP is not a zip: {exc}") from exc
    with zf:
        try:
            raw = zf.read("module.json")
        except KeyError as exc:
            raise ProvenanceError("HAP module.json missing") from exc
    doc = json.loads(raw.decode("utf-8"))
    app = doc.get("app") or {}
    name = str(app.get("versionName") or "")
    code = str(app.get("versionCode") or "")
    if not name or not code:
        raise ProvenanceError("HAP module.json missing version")
    bundle = str(app.get("bundleName") or "")
    if not bundle:
        raise ProvenanceError("HAP module.json missing bundleName")
    return {"versionName": name, "versionCode": code, "bundleName": bundle}


def measure_hap_sign_artifacts(hap: Path) -> dict[str, str]:
    fp, chain, profile = measure_hap_signer_fingerprint(hap, with_files=True)
    if not chain.is_file() or not profile.is_file():
        raise ProvenanceError("verify-app did not write cert chain/profile")
    return {
        "signerFingerprint": fp,
        "appCertSha256": sha256_file(chain),
        "profileSha256": sha256_file(profile),
    }


def measure_hap_signer_fingerprint(hap: Path, with_files: bool = False):
    java = "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java"
    jar = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
    if not Path(java).is_file() or not Path(jar).is_file():
        raise ProvenanceError("hap-sign-tool missing; cannot measure signer from HAP")
    outdir = Path(tempfile.mkdtemp(prefix="hap-verify-chain."))
    chain = outdir / "chain.cer"
    profile = outdir / "profile.p7b"
    result = subprocess.run(
        [
            java,
            "-jar",
            jar,
            "verify-app",
            "-inFile",
            str(hap),
            "-outCertChain",
            str(chain),
            "-outProfile",
            str(profile),
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    text = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        raise ProvenanceError(f"verify-app failed: {text[-400:]}")
    fp = fingerprint_from_verify_app_text(text)
    if with_files:
        return fp, chain, profile
    return fp


def fingerprint_from_verify_app_text(text: str) -> str:
    # Profile cert is printed first. The HAP code-sign cert that bm dump
    # reports is "certificate #1" in the verify-app chain.
    idx = text.lower().find("certificate #1")
    chunk = text[idx:] if idx >= 0 else text
    found: list[str] = []
    for line in chunk.splitlines():
        if "SHA256:" in line:
            hexed = re.sub(r"[^0-9A-Fa-f]", "", line.split("SHA256:", 1)[1])
            if len(hexed) == 64:
                found.append(hexed.upper())
    if not found:
        raise ProvenanceError("verify-app printed no SHA256 fingerprint")
    return found[0]


def rsync_excludes_runtime(script: str) -> bool:
    excludes = re.findall(r"--exclude\s+(\S+)", script)
    return ".runtime" in excludes and ".runtime/native-build" not in excludes
