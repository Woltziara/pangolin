#!/usr/bin/env bash
set -euo pipefail
# Internal pinned-core builder; use scripts/build.sh.
if [[ "${TONGDAO_NATIVE_BUILD:-0}" != "1" ]]; then
  echo "Use scripts/build.sh to prepare the pinned toolchain and source revisions." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-${SDK_HOME}/default/openharmony/native}"
CC_BIN="${OHOS_NATIVE_HOME}/llvm/bin/aarch64-unknown-linux-ohos-clang"
CXX_BIN="${OHOS_NATIVE_HOME}/llvm/bin/aarch64-unknown-linux-ohos-clang++"
OUT_DIR="${ROOT_DIR}/entry/src/main/cpp/prebuilt/arm64-v8a"
LIBXRAY_REPO="${LIBXRAY_REPO:-https://github.com/XTLS/libXray.git}"
GO_LDFLAGS_DEFAULT="-s -w -checklinkname=0 -buildid= -linkmode external -extldflags \"-Wl,--version-script=PLACEHOLDER -Wl,-z,lazy\""

# Reuse project-local caches across native rebuilds without changing HOME.
GOPATH="${GOPATH:-${ROOT_DIR}/.runtime/native-build/gopath}"
GOCACHE="${GOCACHE:-${ROOT_DIR}/.runtime/native-build/go-cache}"
GOMODCACHE="${GOMODCACHE:-${GOPATH}/pkg/mod}"
export GOPATH GOCACHE GOMODCACHE
export GOTOOLCHAIN=local
mkdir -p "${GOPATH}" "${GOCACHE}" "${GOMODCACHE}"

if [[ -z "${XRAY_WORK_DIR:-}" ]]; then
  if [[ -d "${ROOT_DIR}/.runtime" ]]; then
    XRAY_WORK_DIR="$(mktemp -d "${ROOT_DIR}/.runtime/xray-ohos.XXXXXX")"
  else
    XRAY_WORK_DIR="$(mktemp -d /tmp/xray-ohos.XXXXXX)"
  fi
fi
WORK_DIR="${XRAY_WORK_DIR}"
SRC_DIR="${WORK_DIR}/src"
EXPORTS_FILE="${WORK_DIR}/libxray.exports"
GO_LDFLAGS_DEFAULT="-s -w -checklinkname=0 -buildid= -linkmode external -extldflags \"-Wl,--version-script=${EXPORTS_FILE} -Wl,-z,lazy\""

# OHOS Go 工具链（openharmony-sig go1.24.5 fork，commit 钉在 CORE_LOCK.go.commit）
OHOS_GO_FORK="${OHOS_GO_FORK:-${ROOT_DIR}/.runtime/native-build/ohos_golang_go}"
OHOS_GO_COMMIT="${OHOS_GO_COMMIT:-302a5306b6fad2f47196360b82561d1db1f954cf}"
LIBXRAY_PIN="${LIBXRAY_PIN:-20d70a98}"

# Keep the operator's Git configuration; this build never rewrites it.

mkdir -p "${WORK_DIR}"
rm -rf "${SRC_DIR}"

# ── 工具链：OHOS Go fork ───────────────────────────────────────────────────────────
if [[ -x "${OHOS_GO_FORK}/bin/go" ]]; then
  export PATH="${OHOS_GO_FORK}/bin:${PATH}"
  export GOTOOLCHAIN=local
else
  echo "ERROR: 找不到 OHOS Go fork: ${OHOS_GO_FORK}/bin/go" >&2
  echo "  按 docs/BUILDING.md 构建该工具链：" >&2
  echo "  git clone --branch release-branch.go1.24 https://gitcode.com/openharmony-sig/ohos_golang_go.git" >&2
  echo "  cd ohos_golang_go/src && GOROOT_BOOTSTRAP=/usr/local/go GOTOOLCHAIN=local ./make.bash" >&2
  exit 1
fi
if [[ -d "${OHOS_GO_FORK}/.git" ]]; then
  HAVE_GO_COMMIT="$(git -C "${OHOS_GO_FORK}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${HAVE_GO_COMMIT}" && "${HAVE_GO_COMMIT}" != "${OHOS_GO_COMMIT}" ]]; then
    echo "ERROR: Go fork commit ${HAVE_GO_COMMIT} != pinned ${OHOS_GO_COMMIT}" >&2
    exit 1
  fi
  echo "OK Go fork commit ${OHOS_GO_COMMIT}"
fi
# 去掉其余 IE-TLS 重定位，配合 fork 的 tls_g TLSDESC——musl 在 dlopen 的库里只接受
# 通用动态 TLS（global-dynamic / TLSDESC），不接受 initial-exec。
export CGO_CFLAGS="${CGO_CFLAGS:-} -ftls-model=global-dynamic"
# ⚠️ 不能加 netgo：openharmony 的 net 端口需要 cgo，加了会报 _C_getifaddrs undefined。
GO_TAGS="${GO_TAGS:-}"

# Pinned SOCKS ABI with CGoHello warmup; upgrades must update the native bridge.
cat > "${EXPORTS_FILE}" <<'MAP'
{
  global:
    CGoHello;
    CGoRunXrayFromJSON;
    CGoStopXray;
    CGoXrayVersion;
    CGoPing;
    CGoQueryStats;
  local: *;
};
MAP

# ── 取 libXray 源码 ───────────────────────────────────────────────────────────────
git clone "${LIBXRAY_REPO}" "${SRC_DIR}"
git -C "${SRC_DIR}" checkout "${LIBXRAY_PIN}"
git -C "${SRC_DIR}" rev-parse HEAD > "${WORK_DIR}/measured-libxray-commit.txt"
PATCH_FILE="${ROOT_DIR}/native/patches/libxray-cgohello.patch"
if [[ -f "${PATCH_FILE}" ]]; then
  shasum -a 256 "${PATCH_FILE}" | awk '{print $1}' > "${WORK_DIR}/measured-patch-sha256.txt"
fi
SINGLE_START_PATCH="${ROOT_DIR}/native/patches/libxray-single-start.py"
if [[ ! -f "${SINGLE_START_PATCH}" ]]; then
  echo "ERROR: missing ${SINGLE_START_PATCH}" >&2
  exit 1
fi
if [[ ! -f "${SRC_DIR}/xray/xray.go" ]]; then
  echo "ERROR: libXray checkout missing xray/xray.go" >&2
  exit 1
fi
python3 "${SINGLE_START_PATCH}" "${SRC_DIR}/xray/xray.go"
echo "applied" > "${WORK_DIR}/measured-single-start-patch.txt"
shasum -a 256 "${SINGLE_START_PATCH}" | awk '{print $1}' > "${WORK_DIR}/measured-single-start-patch-sha256.txt"
if python3 - "${SRC_DIR}/xray/xray.go" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
start = text.find("func StartXrayFromJSON")
run = text.find("func RunXrayFromJSON")
if start < 0 or run < 0:
    raise SystemExit("patched xray.go missing StartXrayFromJSON/RunXrayFromJSON")
start_fn = text[start:text.find("\nfunc ", start + 1)]
run_fn = text[run:text.find("\nfunc ", run + 1)]
if "StartInstance" in start_fn:
    raise SystemExit("StartXrayFromJSON still calls StartInstance")
if "core.New(" not in start_fn:
    raise SystemExit("StartXrayFromJSON missing core.New")
if "coreServer.Close()" not in run_fn:
    raise SystemExit("RunXrayFromJSON missing Close on Start failure")
print("OK verified single-start source in checkout")
PY
then
  echo "OK single-start source verified"
else
  echo "ERROR: single-start patch did not change checkout source" >&2
  exit 1
fi
if [[ -x "${OHOS_GO_FORK}/bin/go" && -d "${OHOS_GO_FORK}/.git" ]]; then
  git -C "${OHOS_GO_FORK}" rev-parse HEAD > "${WORK_DIR}/measured-go-commit.txt"
  "${OHOS_GO_FORK}/bin/go" version > "${WORK_DIR}/measured-go-version.txt"
fi

cd "${SRC_DIR}"
go mod edit -go=1.24 || true
TEMPLATE_GO="${SRC_DIR}/build/template/main.go"
if [[ ! -f "${TEMPLATE_GO}" ]]; then
  echo "ERROR: 未找到 libXray CGo 模板 ${TEMPLATE_GO}" >&2
  exit 1
fi
# Linux/OHOS c-shared 构建：把 template/main.go 拷到模块根，并把根目录
# package libXray 改成 package main。不要去编 ./main（那是 geo 下载器，没有 import "C"）。
cp "${TEMPLATE_GO}" "${SRC_DIR}/main.go"
python3 - "${SRC_DIR}" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in root.glob("*.go"):
    text = path.read_text()
    if text.startswith("//go:build android") or "\n//go:build android\n" in text[:80]:
        continue
    if text.startswith("package libXray") or "\npackage libXray\n" in text[:200]:
        path.write_text(text.replace("package libXray", "package main", 1))
PY
if ! grep -q 'export CGoHello' "${SRC_DIR}/main.go"; then
  cat >> "${SRC_DIR}/main.go" <<'HELLO'

//export CGoHello
func CGoHello() *C.char {
	return C.CString("hello-from-libxray")
}
HELLO
fi
if ! grep -q 'export CGoHello' "${SRC_DIR}/main.go"; then
  echo "ERROR: CGoHello patch was not applied to checkout" >&2
  exit 1
fi
# Bind Xray dials to the physical NIC so CGo sockets cannot loop into vpn-tun.
cat > "${SRC_DIR}/ohos_protect.go" <<'PROTECT'
package main

/*
#cgo LDFLAGS: -ldl
#include <dlfcn.h>
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 4
#endif
static int call_hey_protect(int fd) {
	typedef int (*fn)(int);
	static fn f;
	if (f == 0) {
		void *h = dlopen("libheyvpn.so", RTLD_LAZY | RTLD_NOLOAD);
		if (h == 0) {
			h = dlopen("libheyvpn.so", RTLD_LAZY);
		}
		if (h != 0) {
			f = (fn)dlsym(h, "hey_protect_socket");
		}
		if (f == 0) {
			f = (fn)dlsym((void*)0, "hey_protect_socket");
		}
	}
	if (f == 0) {
		return -2;
	}
	return f(fd);
}
*/
import "C"

import (
	"fmt"
	"syscall"

	xnet "github.com/xtls/xray-core/transport/internet"
)

// HarmonyOS-native anti-loop: VpnConnection.protect(socketFd) only.
// Binding the socket to a NIC name is an Android leftover and is ignored
// on OHOS. DNS outbounds (1.1.1.1/8.8.8.8) and the node share this controller.
// Fail closed: an unprotected fd must not dial into vpn-tun.
func ohosProtectDialer(network, address string, c syscall.RawConn) error {
	var rc C.int = -3
	err := c.Control(func(fd uintptr) {
		rc = C.call_hey_protect(C.int(fd))
	})
	if err != nil {
		return err
	}
	if rc != 0 {
		return fmt.Errorf("ohos protect failed rc=%d network=%s addr=%s", int(rc), network, address)
	}
	return nil
}

func init() {
	if err := xnet.RegisterDialerController(ohosProtectDialer); err != nil {
		panic("ohos protect dialer register failed: " + err.Error())
	}
}
PROTECT
echo "applied" > "${WORK_DIR}/measured-patch-applied.txt"
XRAY_BUILD_PKG="."

# ── gvisor fdbased Fstat 补丁（尽力而为）────────────────────────────────────────────
# gvisor 的 fdbased 端点用 unix.Fstat 判断 dispatcher，而 HarmonyOS 的 VPN fd 会拒 Fstat
# （readv/writev 正常）。现役 libxray 是“SOCKS 版”（数据面走 HEV，不再用核心自带的
# TUN 入站），通常不命中此处；但钉死的旧版若仍引用，则需此补丁。故改为尽力而为：补丁不中
# 只告警、不中断。
GVISOR_MODULE_VERSION="$(go list -m -f '{{.Version}}' gvisor.dev/gvisor 2>/dev/null || true)"
if [[ -n "${GVISOR_MODULE_VERSION}" ]]; then
  GVISOR_MODULE_DIR="$(go env GOMODCACHE)/gvisor.dev/gvisor@${GVISOR_MODULE_VERSION}"
  if [[ ! -d "${GVISOR_MODULE_DIR}" ]]; then
    go mod download gvisor.dev/gvisor || true
  fi
  FDBASED_GO="${GVISOR_MODULE_DIR}/pkg/tcpip/link/fdbased/endpoint.go"
  if [[ -f "${FDBASED_GO}" ]] && grep -q 'func isSocketFD(fd int)' "${FDBASED_GO}"; then
    # Relative replace so the .so does not embed /tmp/xray-ohos.* workdir paths.
    PATCHED_GVISOR_DIR="${SRC_DIR}/third_party/gvisor-patched"
    mkdir -p "${SRC_DIR}/third_party"
    [[ -d "${PATCHED_GVISOR_DIR}" ]] && chmod -R u+w "${PATCHED_GVISOR_DIR}"
    rm -rf "${PATCHED_GVISOR_DIR}"
    cp -R "${GVISOR_MODULE_DIR}" "${PATCHED_GVISOR_DIR}"
    chmod -R u+w "${PATCHED_GVISOR_DIR}"
    python3 - "${PATCHED_GVISOR_DIR}/pkg/tcpip/link/fdbased/endpoint.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """func isSocketFD(fd int) (bool, error) {
\tvar stat unix.Stat_t
\tif err := unix.Fstat(fd, &stat); err != nil {
\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)
\t}
\treturn (stat.Mode & unix.S_IFSOCK) == unix.S_IFSOCK, nil
}
"""
new = """func isSocketFD(fd int) (bool, error) {
\t// HarmonyOS VPN fd 会拒 Fstat（但 readv/writev 正常），强制走可移植的
\t// 非 socket Readv dispatcher，绕开 Fstat。
\treturn false, nil
}
"""
if old not in text:
    print("WARN: isSocketFD 实现与预期不符，跳过 gvisor 补丁（SOCKS 版通常不需要）", file=sys.stderr)
else:
    path.write_text(text.replace(old, new))
    print("Patched gvisor isSocketFD")
PY
    go mod edit -replace="gvisor.dev/gvisor=./third_party/gvisor-patched"
  else
    echo "WARN: 未在 gvisor 找到 fdbased/isSocketFD，跳过补丁（SOCKS 版通常不需要）" >&2
  fi
else
  echo "WARN: 依赖里未发现 gvisor 模块，跳过补丁。" >&2
fi

# Locked Xray ignores controller errors in TCP/UDP Dial. Fail closed here.
go mod download github.com/xtls/xray-core
XRAY_CORE_DIR="$(go list -m -f '{{.Dir}}' github.com/xtls/xray-core)"
if [[ -z "${XRAY_CORE_DIR}" || ! -f "${XRAY_CORE_DIR}/transport/internet/system_dialer.go" ]]; then
  echo "ERROR: locked xray-core system_dialer.go missing" >&2
  exit 1
fi
PATCHED_XRAY_DIR="${SRC_DIR}/third_party/xray-core-protect-fail-closed"
mkdir -p "${SRC_DIR}/third_party"
[[ -d "${PATCHED_XRAY_DIR}" ]] && chmod -R u+w "${PATCHED_XRAY_DIR}"
rm -rf "${PATCHED_XRAY_DIR}"
cp -R "${XRAY_CORE_DIR}" "${PATCHED_XRAY_DIR}"
chmod -R u+w "${PATCHED_XRAY_DIR}"
python3 "${ROOT_DIR}/native/patches/xray-protect-fail-closed.py" \
  "${PATCHED_XRAY_DIR}/transport/internet/system_dialer.go"
if grep -q 'failed to apply external controller' "${PATCHED_XRAY_DIR}/transport/internet/system_dialer.go"; then
  echo "ERROR: xray protect fail-closed patch did not replace controller logging" >&2
  exit 1
fi
if ! grep -q 'return err' "${PATCHED_XRAY_DIR}/transport/internet/system_dialer.go"; then
  echo "ERROR: xray protect fail-closed patch missing return err" >&2
  exit 1
fi
# Relative replace so Go BuildInfo cannot embed /tmp/xray-ohos.* workdir paths.
go mod edit -replace="github.com/xtls/xray-core=./third_party/xray-core-protect-fail-closed"
echo "applied xray protect fail-closed" > "${WORK_DIR}/measured-xray-protect-patch.txt"

# ── 构建 ─────────────────────────────────────────────────────────────────────────
STAGED_SO="${WORK_DIR}/libxray.so"
CGO_ENABLED=1 \
GOOS=openharmony \
GOARCH=arm64 \
CC="${CC_BIN}" \
CXX="${CXX_BIN}" \
go build \
  -tags "${GO_TAGS}" \
  -trimpath \
  -ldflags="${GO_LDFLAGS:-${GO_LDFLAGS_DEFAULT}}" \
  -buildmode=c-shared \
  -o "${STAGED_SO}" \
  "${XRAY_BUILD_PKG}"

# 撤掉构建期注入的 gvisor replace（若有），保持 SRC 干净。
go mod edit -dropreplace="gvisor.dev/gvisor" 2>/dev/null || true

if [[ ! -f "${STAGED_SO}" ]]; then
  echo "ERROR: missing staged ${STAGED_SO}" >&2
  exit 1
fi
NM_BIN="${OHOS_NATIVE_HOME}/llvm/bin/llvm-nm"
if [[ -x "${NM_BIN}" ]]; then
  SYMS="$("${NM_BIN}" -D "${STAGED_SO}" || true)"
  for need in CGoHello CGoRunXrayFromJSON CGoStopXray CGoXrayVersion CGoPing CGoQueryStats; do
    if ! printf '%s\n' "${SYMS}" | grep -q "${need}"; then
      echo "ERROR: libxray.so missing export ${need}" >&2
      exit 1
    fi
  done
  echo "OK libxray exports: CGoHello CGoRunXrayFromJSON CGoStopXray CGoXrayVersion CGoPing CGoQueryStats"
fi
if strings "${STAGED_SO}" | grep -E '/tmp/xray-ohos|/path/to/user/go' >/dev/null; then
  echo "ERROR: libxray.so embeds host workdir paths (trimpath/replace leak)" >&2
  strings "${STAGED_SO}" | grep -E '/tmp/xray-ohos|/path/to/user/go' | head -5 >&2
  mkdir -p "${ROOT_DIR}/.runtime/rejected-native"
  cp "${STAGED_SO}" "${ROOT_DIR}/.runtime/rejected-native/libxray.$(shasum -a 256 "${STAGED_SO}" | awk '{print $1}').so"
  exit 1
fi
echo "STAGED_LIBXRAY=${STAGED_SO}"
echo "Built staged ${STAGED_SO} (GOOS=openharmony); build.sh publishes after full verification"

# ── 把内置 Xray 核版本号戳进 CoreInfo.ets ───────────────────────────────────────────
# About 页直接显示这个常量，而不在运行时调原生 CGoXrayVersion()。该常量从所锁定的
# xtls/xray-core 源码（core/core.go 的 Version_x/y/z）读取，与 prebuilt .so 同步。
# 历史上 GOOS=android 的库冷调 CGoXrayVersion 会 SIGSEGV；openharmony(fork) 路线已无此问题，
# 但保留“构建期戳常量”做法仍可避免一次原生冷调用，且更省事。
CORE_INFO_FILE="${ROOT_DIR}/entry/src/main/ets/core/CoreInfo.ets"
XRAY_CORE_DIR="$(go list -m -f '{{.Dir}}' github.com/xtls/xray-core 2>/dev/null || true)"
CORE_GO="${XRAY_CORE_DIR}/core/core.go"
if [[ -n "${XRAY_CORE_DIR}" && -f "${CORE_GO}" ]]; then
  VX="$(grep -E 'Version_x[[:space:]]+byte' "${CORE_GO}" | grep -oE '[0-9]+' | head -1)"
  VY="$(grep -E 'Version_y[[:space:]]+byte' "${CORE_GO}" | grep -oE '[0-9]+' | head -1)"
  VZ="$(grep -E 'Version_z[[:space:]]+byte' "${CORE_GO}" | grep -oE '[0-9]+' | head -1)"
else
  VX=""; VY=""; VZ=""
fi
if [[ -n "${VX}" && -n "${VY}" && -n "${VZ}" ]]; then
  XRAY_VER="${VX}.${VY}.${VZ}"
  if [[ -f "${CORE_INFO_FILE}" ]] && grep -q 'export const BUNDLED_XRAY_VERSION' "${CORE_INFO_FILE}"; then
    python3 - "${CORE_INFO_FILE}" "${XRAY_VER}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
next_text, count = re.subn(
    r"export const BUNDLED_XRAY_VERSION: string = '[^']*';",
    f"export const BUNDLED_XRAY_VERSION: string = '{version}';",
    text,
    count=1,
)
if count != 1:
    raise SystemExit("BUNDLED_XRAY_VERSION export not found")
path.write_text(next_text)
PY
  else
    cat > "${CORE_INFO_FILE}" <<EOF
/**
 * 内置 Xray 内核（xtls/xray-core）的版本号 —— 即 \`core.Version()\` 的返回值。
 *
 * 此常量在重新编译 libxray.so 时由 scripts/build_libxray_ohos.sh 从所锁定的
 * xtls/xray-core 源码（core/core.go 的 Version_x/y/z 常量）自动写入，
 * 与 prebuilt/arm64-v8a/libxray.so 保持同步——请勿手动修改。
 */
export const BUNDLED_XRAY_VERSION: string = '${XRAY_VER}';
EOF
  fi
  echo "Stamped bundled Xray core version ${XRAY_VER} into ${CORE_INFO_FILE}"
else
  echo "WARN: could not parse Xray core version from ${CORE_GO}; left CoreInfo.ets unchanged" >&2
fi
