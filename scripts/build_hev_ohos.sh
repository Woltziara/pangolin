#!/usr/bin/env bash
set -euo pipefail

# 交叉编译 hev-socks5-tunnel（C）为 HarmonyOS 的 libhevsocks5tun.so。
#
# 这是「使用 Hev TUN 引擎」开关打开时走的高性能数据面，对照默认的 gvisor/xjasonlyu
# 引擎（libheytun2socks.so，见 build_tun2socks_ohos.sh）。两者都干同一件事：读 Harmony
# VPN 的 TUN fd → 转发进内核的本地 SOCKS 入站（127.0.0.1:VPN_DATA_SOCKS_PORT）；只是
# 实现不同：hev 是纯 C 协程栈（hev-task-system + 内置 yaml），更轻更快。
#
# ✅ 与三个 Go 库不同：hev 是 **纯 C**，不碰 Go-on-musl 的 TLS 墙
#    （docs/harmonyos-go-tls-wall.md），用 DevEco 的 OHOS clang 直接交叉编译即可，
#    不需要 OHOS Go fork。
#
#    若无 OHOS NDK，改脚本后无法本机验证编译；请在装好 DevEco 的机器实跑，
#    并按 docs/building-native-cores.md §4 校验产物：
#      nm -D libhevsocks5tun.so | grep hev_socks5_tunnel
#    应见既有入口以及本次逐流路由 callback setter。
#    若 hev 上游改了符号名或 yaml 字段，需同步改 napi_init.cpp 与 HevTunConfig.ets。

if [[ "${TONGDAO_NATIVE_BUILD:-0}" != "1" && "${TONGDAO_R1_PUBLISH:-0}" != "1" ]]; then
  echo "ERROR: native hev builder is not a publish entry. Use scripts/r1-build.sh REBUILD_HEV=1" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-${SDK_HOME}/default/openharmony/native}"
CC_BIN="${OHOS_NATIVE_HOME}/llvm/bin/aarch64-unknown-linux-ohos-clang"
AR_BIN="${OHOS_NATIVE_HOME}/llvm/bin/llvm-ar"
RANLIB_BIN="${OHOS_NATIVE_HOME}/llvm/bin/llvm-ranlib"
SYSROOT="${OHOS_NATIVE_HOME}/sysroot"
WORK_DIR="${HEV_WORK_DIR:-}"
if [[ -z "${WORK_DIR}" ]]; then
  echo "ERROR: HEV_WORK_DIR must be set to an isolated workdir (r1-build provides one). Refusing to use the project .git" >&2
  exit 2
fi
if [[ "$WORK_DIR" == "$ROOT_DIR" || "$WORK_DIR" == "$ROOT_DIR"/*/.git* ]]; then
  echo "ERROR: HEV_WORK_DIR must not be the project tree" >&2
  exit 2
fi
STAGE_DIR="${HEV_STAGE_DIR:-${WORK_DIR}/stage}"
PREBUILT_DIR="${ROOT_DIR}/entry/src/main/cpp/prebuilt"
if [[ "$STAGE_DIR" == "$PREBUILT_DIR" || "$STAGE_DIR" == "$PREBUILT_DIR"/* ]]; then
  echo "ERROR: HEV_STAGE_DIR must not be the shared prebuilt tree; r1-build publishes the staged artifact" >&2
  exit 2
fi

# hev 上游与钉死版本。改版本前先确认符号名/yaml 字段未变（见脚本顶部 ⚠️）。
HEV_REPO="${HEV_REPO:-https://github.com/heiher/hev-socks5-tunnel.git}"
HEV_PIN="${HEV_PIN:-2.17.1}"

if [[ ! -x "${CC_BIN}" ]]; then
  echo "ERROR: 找不到 OHOS clang: ${CC_BIN}" >&2
  echo "  装好 DevEco Studio / HarmonyOS SDK，或用 OHOS_NATIVE_HOME 覆盖路径。" >&2
  exit 1
fi

mkdir -p "${WORK_DIR}" "${STAGE_DIR}"

# ── 拉源码（含子模块 hev-socks5-core / hev-task-system / lwip / yaml）─────────────────
SRC_DIR="${WORK_DIR}/src"
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  git clone --recursive "${HEV_REPO}" "${SRC_DIR}"
fi
cd "${SRC_DIR}"
git fetch --tags --quiet
git checkout --quiet "${HEV_PIN}"
git submodule update --init --recursive

# Explicit diagnostic variant of the pinned core. The forwarding decisions stay
# unchanged; the patch adds count-only observations consumed by native-stats.
DIAGNOSTIC_KIND="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hev"].get("diagnostic", ""))' "$ROOT_DIR/native/CORE_LOCK.json")"
PATCH_FLAGS=" -I$ROOT_DIR/native/patches"
APPLIED_INPUTS=( "native/patches/app-flow-route.h" )
if [[ "$DIAGNOSTIC_KIND" == "udp-counters-v1" ]]; then
  git apply --check "$ROOT_DIR/native/patches/hev-udp-diagnostics.patch"
  git -C third-part/hev-task-system apply --check "$ROOT_DIR/native/patches/hev-udp-diagnostics-task-system.patch"
  git apply "$ROOT_DIR/native/patches/hev-udp-diagnostics.patch"
  git -C third-part/hev-task-system apply "$ROOT_DIR/native/patches/hev-udp-diagnostics-task-system.patch"
  cp "$ROOT_DIR/native/patches/hev-udp-diagnostics.c" src/hev-udp-diagnostics.c
  APPLIED_INPUTS+=(
    "native/patches/hev-udp-diagnostics.patch"
    "native/patches/hev-udp-diagnostics-task-system.patch"
    "native/patches/hev-udp-diagnostics.c"
    "native/patches/hev-udp-diagnostics.h"
  )
  FIX_KIND="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hev"].get("fix", ""))' "$ROOT_DIR/native/CORE_LOCK.json")"
  if [[ "$FIX_KIND" == "udp-demand-write-v1" || "$FIX_KIND" == "socket-demand-events-v2" ]]; then
    git apply --check "$ROOT_DIR/native/patches/hev-udp-demand-write.patch"
    git apply "$ROOT_DIR/native/patches/hev-udp-demand-write.patch"
    APPLIED_INPUTS+=( "native/patches/hev-udp-demand-write.patch" )
    PATCH_FLAGS="$PATCH_FLAGS -DCHUANSHAN_HEV_UDP_DEMAND_WRITE=1"
    if [[ "$FIX_KIND" == "socket-demand-events-v2" ]]; then
      git apply --check "$ROOT_DIR/native/patches/hev-tcp-demand-events.patch"
      git -C third-part/hev-task-system apply --check "$ROOT_DIR/native/patches/hev-socket-wait-events.patch"
      git apply "$ROOT_DIR/native/patches/hev-tcp-demand-events.patch"
      git -C third-part/hev-task-system apply "$ROOT_DIR/native/patches/hev-socket-wait-events.patch"
      APPLIED_INPUTS+=(
        "native/patches/hev-tcp-demand-events.patch"
        "native/patches/hev-socket-wait-events.patch"
      )
      PATCH_FLAGS="$PATCH_FLAGS -DCHUANSHAN_HEV_SOCKET_DEMAND_EVENTS=1"
    fi
  elif [[ -n "$FIX_KIND" ]]; then
    echo "ERROR: unrecognized HEV fix variant" >&2
    exit 2
  fi
elif [[ -n "$DIAGNOSTIC_KIND" ]]; then
  echo "ERROR: unrecognized HEV diagnostic variant" >&2
  exit 2
fi

# App identity routing is part of this pinned HEV variant, independent of
# optional diagnostics. It is always applied after the existing patch chain.
git apply --check "$ROOT_DIR/native/patches/hev-app-routing.patch"
git apply "$ROOT_DIR/native/patches/hev-app-routing.patch"
APPLIED_INPUTS+=( "native/patches/hev-app-routing.patch" )
python3 "$ROOT_DIR/native/patches/hev-tun-progress.py" "$SRC_DIR"
APPLIED_INPUTS+=( "native/patches/hev-tun-progress.py" )
git diff --check

# Exercise the actual fork's first-packet callback contract before publishing
# any new HEV core. Text-only tuple checks missed its two-pass UDP semantics.
HEV_SOURCE_DIR="$SRC_DIR" python3 "$ROOT_DIR/tests/hev_udp_first_packet_test.py"

# ── 交叉编译 ────────────────────────────────────────────────────────────────────────
# OHOS 是 aarch64 + musl。hev 的 Makefile 接受 CC/CFLAGS；先出静态库，再整体链成共享库。
# 注意：不要加 -D_GNU_SOURCE —— hev-task-system 的源码自己 `#define _GNU_SOURCE`，命令行再传
# 会因 hev 的 -Werror=macro-redefined 直接编译失败。
COMMON_FLAGS="--target=aarch64-linux-ohos --sysroot=${SYSROOT} -fPIC -O2${PATCH_FLAGS}"

make clean >/dev/null 2>&1 || true
# `make static` 产出 bin/libhev-socks5-tunnel.a（库目标，含 hev_socks5_tunnel_* 公共 API）。
# 用 OHOS 的 llvm-ar/llvm-ranlib 打包，避免 macOS 宿主 ranlib 处理交叉 .a 报「空 TOC」警告。
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
  CC="${CC_BIN}" \
  AR="${AR_BIN}" \
  RANLIB="${RANLIB_BIN}" \
  CFLAGS="${COMMON_FLAGS}" \
  static

# 收集全树所有静态库：主库 libhev-socks5-tunnel.a 在根 bin/（含公共 API + 内置 lwip/yaml），
# 但 hev-task-system 等子模块各自编进自己的 bin/，不在根 bin/。必须把它们一起链进来，否则
# .so 会留下 hev_task_*/hev_object_*/hev_malloc 等未解析符号，真机 dlopen 时报 "symbol not
# found"（共享库默认允许未定义符号，主机链接不报错——靠后面的自检兜底）。
MAIN_LIB=""
OTHER_LIBS=()
while IFS= read -r a; do
  case "${a}" in
    */libhev-socks5-tunnel.a) MAIN_LIB="${a}" ;;
    *) OTHER_LIBS+=( "${a}" ) ;;
  esac
done < <(find "${SRC_DIR}" -name '*.a' -type f)
if [[ -z "${MAIN_LIB}" ]]; then
  echo "ERROR: 未找到主静态库 libhev-socks5-tunnel.a；hev 的 make 目标/产物路径可能变了，需人工适配。" >&2
  exit 1
fi

# --whole-archive 主库（保留 hev_socks5_tunnel_* 导出，.so 自身不引用这些入口符号）；
# 其余静态库（hev-task-system…）正常链接，按需解析主库引用的内部符号。重复符号不会冲突：
# 普通归档只为满足未解析符号而拉取对象，已定义的（如主库内置的 lwip）不会被二次拉入。
# `${OTHER_LIBS[@]+...}` 是 bash 3.2（macOS 自带）下空数组 + set -u 的安全展开写法。
# musl 上 pthread 已并入 libc，-lpthread 可有可无，留着兼容。
"${CC_BIN}" ${COMMON_FLAGS} -shared \
  -o "${STAGE_DIR}/libhevsocks5tun.so" \
  -Wl,--whole-archive "${MAIN_LIB}" -Wl,--no-whole-archive \
  ${OTHER_LIBS[@]+"${OTHER_LIBS[@]}"} \
  -lpthread

# ── 自检：.so 不应再有未解析的 hev_/lwip 内部符号（漏链静态库的典型症状）─────────────
NM_BIN="${OHOS_NATIVE_HOME}/llvm/bin/llvm-nm"
[[ -x "${NM_BIN}" ]] || NM_BIN="nm"
LEFTOVER="$("${NM_BIN}" -D -u "${STAGE_DIR}/libhevsocks5tun.so" 2>/dev/null \
  | grep -iE '\b(hev_|lwip_|pbuf_|netif_)' || true)"
if [[ -n "${LEFTOVER}" ]]; then
  echo "ERROR: libhevsocks5tun.so 仍有未解析的内部符号（漏链了某个 bin/*.a）：" >&2
  echo "${LEFTOVER}" >&2
  exit 1
fi

EXPORT_RECEIPT="${WORK_DIR}/measured-hev-exports.txt"
"${NM_BIN}" -D "${STAGE_DIR}/libhevsocks5tun.so" 2>/dev/null \
  | grep ' hev_socks5_tunnel_' > "${EXPORT_RECEIPT}"
for symbol in hev_socks5_tunnel_main_from_str hev_socks5_tunnel_quit \
  hev_socks5_tunnel_stats hev_socks5_tunnel_set_app_route_callbacks; do
  if ! grep -q " ${symbol}$" "${EXPORT_RECEIPT}"; then
    echo "ERROR: staged HEV library does not export ${symbol}" >&2
    exit 1
  fi
done

echo "Built staged ${STAGE_DIR}/libhevsocks5tun.so (hev-socks5-tunnel ${HEV_PIN})"
echo "Export receipt: ${EXPORT_RECEIPT}"
git -C "${SRC_DIR}" rev-parse HEAD > "${WORK_DIR}/measured-hev-commit.txt"
git -C "${SRC_DIR}" submodule status > "${WORK_DIR}/measured-hev-submodules.txt"
printf '%s\n' "$DIAGNOSTIC_KIND" > "${WORK_DIR}/measured-hev-diagnostic-kind.txt"
printf '%s\n' "${CC_BIN}" > "${WORK_DIR}/measured-hev-cc.txt"
shasum -a 256 "${CC_BIN}" | awk '{print $1}' > "${WORK_DIR}/measured-hev-cc-sha256.txt"
"${CC_BIN}" --version | head -n 1 > "${WORK_DIR}/measured-hev-cc-version.txt"
printf '%s\n' "${COMMON_FLAGS}" > "${WORK_DIR}/measured-hev-cflags.txt"
printf '%s\n' "-shared -Wl,--whole-archive ${MAIN_LIB} -Wl,--no-whole-archive -lpthread" > "${WORK_DIR}/measured-hev-link-flags.txt"
shasum -a 256 "$ROOT_DIR/native/patches/hev-app-routing.patch" \
  | awk '{print $1}' > "${WORK_DIR}/measured-hev-app-routing-patch-sha256.txt"
shasum -a 256 "$ROOT_DIR/native/patches/app-flow-route.h" \
  | awk '{print $1}' > "${WORK_DIR}/measured-hev-app-flow-header-sha256.txt"
python3 -c 'import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
values={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sys.argv[3:]}
pathlib.Path(sys.argv[2]).write_text(json.dumps(values,indent=2,sort_keys=True)+"\n")' \
  "$ROOT_DIR" "${WORK_DIR}/measured-hev-patches.json" "${APPLIED_INPUTS[@]}"
shasum -a 256 "${STAGE_DIR}/libhevsocks5tun.so" \
  | awk '{print $1}' > "${WORK_DIR}/measured-hev-staged-so-sha256.txt"
