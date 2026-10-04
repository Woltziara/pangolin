#!/bin/zsh
set -euo pipefail
# 华为 CBG 调试签名：解密 DevEco 密文密码，调用 hap-sign-tool。
# 材料默认在仓库 .runtime/huawei-cbg/（含 cer/p7b/p12 与 material/），不入库。
if [[ "${TONGDAO_R1_PUBLISH:-0}" != "1" ]]; then
  echo "huawei-sign-hap.sh is not a publish entry; use scripts/r1-build.sh" >&2
  exit 2
fi
if [[ -z "${TONGDAO_SIGN_PERMIT:-}" || ! -f "${TONGDAO_SIGN_PERMIT}" ]]; then
  echo "direct sign sealed; missing TONGDAO_SIGN_PERMIT from r1-build.sh" >&2
  exit 2
fi
if [[ -z "${TONGDAO_SIGN_TICKET:-}" || ${#TONGDAO_SIGN_TICKET} -lt 32 ]]; then
  echo "direct sign sealed; missing TONGDAO_SIGN_TICKET" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${NODE:-/usr/local/bin/node}"
PROFILE="${PROFILE:-$ROOT/build-profile.json5}"
MATERIAL_DIR="${MATERIAL_DIR:-$ROOT/.runtime/huawei-cbg}"
IN_FILE="${1:-}"
OUT_FILE="${2:-}"
if [[ -z "$IN_FILE" || -z "$OUT_FILE" ]]; then
  echo "usage: $0 unsigned.hap signed.hap" >&2
  exit 2
fi
WANT_HASH="$(awk '{print $1; exit}' "${TONGDAO_SIGN_PERMIT}")"
WANT_TICKET="$(awk '{print $2; exit}' "${TONGDAO_SIGN_PERMIT}")"
GOT_HASH="$(shasum -a 256 "$IN_FILE" | awk '{print $1}')"
if [[ -z "$WANT_HASH" || "$WANT_HASH" != "$GOT_HASH" ]]; then
  echo "sign permit hash mismatch" >&2
  exit 2
fi
if [[ -z "$WANT_TICKET" || "$WANT_TICKET" != "${TONGDAO_SIGN_TICKET}" ]]; then
  echo "sign permit ticket mismatch" >&2
  exit 2
fi
# 部分沙箱会对 /Users/... 做 realpath 失败；拷到进程独占临时文件再跑。
TMP_JS="$(mktemp /tmp/huawei-sign-hap.XXXXXX.js)"
trap 'rm -f "$TMP_JS"' EXIT
cp "$ROOT/scripts/huawei-sign-hap.js" "$TMP_JS"
"$NODE" "$TMP_JS" \
  --profile "$PROFILE" \
  --in "$IN_FILE" \
  --out "$OUT_FILE" \
  --material-dir "$MATERIAL_DIR"
