#!/usr/bin/env bash
# ==================================================================
# 把 ClankerNPU 现编出的 NPU 固件包装成「可选插件」—— 即一个普通的
# OpenWrt 包，可以用 CONFIG_PACKAGE_<name>=y 在 .config / menuconfig
# 里勾选，例如：
#
#     CONFIG_PACKAGE_airoha-en7581-mt7916-npu-firmware=y
#
# 做三件事：
#   1) 对每个变体调用 build-npu-fw.sh 编译（SOC + WIFI）
#   2) 生成 package/custom/airoha-<soc>-<wifi>-npu-firmware/（Makefile + src/*.bin）
#   3) 把包名等信息写进 $WORK/npu-fw.env，供后续 workflow 步骤使用
#
# 用法（全部走环境变量）：
#   SOC=AN7581 WIFI=MT7916 ./scripts/gen-npu-fw-package.sh
#   SOC=AN7581 WIFI=all  NPU_DEFAULT_WIFI=MT7916  ./scripts/gen-npu-fw-package.sh
#
# 环境变量：
#   SOC              AN7552 / AN7581 / AN7583            （默认 AN7581）
#   WIFI             变体名，或 all = 把该 SoC 的所有变体都编成可选包
#   NPU_DEFAULT_WIFI WIFI=all 时，默认勾选哪个变体（默认 MT7916）
#   CLANKER          0=配 ponwrt/mainline 驱动  1=配 Clanker 自改 host driver
#   CLANKER_REF      ClankerNPU 源码 ref（main / tag / commit sha）
#   FW_PREFIX        固件文件名前缀（空 = 驱动默认名 en7581 / an7583）
#   WORK             工作目录，默认 ./.clanker-build
#   PKG_OUT_DIR      包输出目录，默认 ./package/custom
#   PONWRT_DIR       ponwrt 源码根目录，默认 .
#   FALLBACK_FILES   true = 同时把镜像拷进 files/lib/firmware/airoha（兜底覆盖）
#   SKIP_BUILD       1 = 不编译，直接用 $WORK/out 下已有的镜像（离线/复用）
# ==================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SOC="$(echo "${SOC:-AN7581}" | tr 'a-z' 'A-Z')"
WIFI="$(echo "${WIFI:-MT7916}" | tr 'a-z' 'A-Z')"
NPU_DEFAULT_WIFI="$(echo "${NPU_DEFAULT_WIFI:-MT7916}" | tr 'a-z' 'A-Z')"
CLANKER="${CLANKER:-0}"
CLANKER_REF="${CLANKER_REF:-main}"
FW_PREFIX="${FW_PREFIX:-}"

WORK="${WORK:-$REPO_DIR/.clanker-build}"
PKG_OUT_DIR="${PKG_OUT_DIR:-./package/custom}"
PONWRT_DIR="${PONWRT_DIR:-.}"
FALLBACK_FILES="${FALLBACK_FILES:-false}"
SKIP_BUILD="${SKIP_BUILD:-0}"
TEMPLATE="${TEMPLATE:-$REPO_DIR/packages/npu-clanker-template/Makefile.in}"

BUILD_SCRIPT="$SCRIPT_DIR/build-npu-fw.sh"

# ------------------------------------------------------------------
# 1) SoC -> 驱动默认固件前缀 / 包名里的 SoC 段 / 支持的 WiFi 变体
# ------------------------------------------------------------------
case "$SOC" in
  AN7581) DEF_PREFIX="en7581"; SOC_PKG="en7581"; VARIANTS="MT7916 MT7992 MT7996" ;;
  AN7583) DEF_PREFIX="an7583"; SOC_PKG="an7583"; VARIANTS="MT7916 MT7992 MT7993 MT7996 NOWIFI" ;;
  AN7552) DEF_PREFIX="en7581"; SOC_PKG="an7552"; VARIANTS="MT7916 MT7991 MT7993" ;;
  *) echo "::error::未知 SoC: $SOC（支持 AN7552 / AN7581 / AN7583）"; exit 1 ;;
esac

# linux-firmware 已经占用的包名，不能重名（否则两个包符号冲突）
RESERVED="airoha-en7581-npu-firmware airoha-en7581-mt7996-npu-firmware airoha-an7583-npu-firmware"

# 包名：airoha-<soc>-<wifi>-npu-firmware
# 与 linux-firmware 已占用的名字撞车时（如 AN7581+MT7996）加 -clanker 区分，
# 否则两个包符号重名，defconfig 会直接报错。
pkg_name() {
  local w="$1" n
  n="airoha-${SOC_PKG}-$(echo "$w" | tr 'A-Z' 'a-z')-npu-firmware"
  for r in $RESERVED; do
    if [ "$n" = "$r" ]; then
      n="airoha-${SOC_PKG}-$(echo "$w" | tr 'A-Z' 'a-z')-clanker-npu-firmware"
      break
    fi
  done
  printf '%s' "$n"
}

if [ "$WIFI" = "ALL" ]; then
  BUILD_LIST="$VARIANTS"
  [ -n "$FW_PREFIX" ] && echo "::warning::WIFI=all 时忽略 FW_PREFIX，各变体都用驱动默认名"
else
  BUILD_LIST="$WIFI"
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "::error::找不到包模板 $TEMPLATE"
  exit 1
fi
mkdir -p "$WORK" "$PKG_OUT_DIR"

# ------------------------------------------------------------------
# 2) 编译所有变体
# ------------------------------------------------------------------
declare -a PKG_NAMES=()
declare -a PKG_WIFIS=()

for v in $BUILD_LIST; do
  OUT="$WORK/out/${SOC}_${v}"
  if [ "$SKIP_BUILD" != "1" ] || [ ! -s "$OUT/${FW_PREFIX:-$DEF_PREFIX}_npu_rv32.bin" ]; then
    echo "=================================================="
    echo ">>> 编译变体 ${SOC}_${v}"
    echo "=================================================="
    SOC="$SOC" WIFI="$v" CLANKER="$CLANKER" CLANKER_REF="$CLANKER_REF" \
    FW_PREFIX="$FW_PREFIX" OUT_DIR="$OUT" WORK="$WORK" \
      bash "$BUILD_SCRIPT"
  else
    echo ">>> SKIP_BUILD=1，复用已有镜像: $OUT"
  fi
  # build-npu-fw.sh 每跑一次就重写 npu-fw.env，这里立刻读走
  [ -f "$WORK/npu-fw.env" ] && . "$WORK/npu-fw.env"
  PKG_WIFIS+=("$v")
  PKG_NAMES+=("$(pkg_name "$v")")
done

# ------------------------------------------------------------------
# 3) 逐个生成包目录
# ------------------------------------------------------------------
# 冲突列表：stock 三个包 + 本次生成的其他变体（它们装同名文件，必须互斥）
OTHERS=""
for n in "${PKG_NAMES[@]}"; do OTHERS="$OTHERS $n"; done

ENV_PKGS=""
SELECTED_PKG=""
SEL_RS=""; SEL_DS=""; SEL_REV=""; SEL_PREFIX=""

for i in "${!PKG_WIFIS[@]}"; do
  v="${PKG_WIFIS[$i]}"
  NAME="$(pkg_name "$v")"
  OUT="$WORK/out/${SOC}_${v}"
  PREFIX="${FW_PREFIX:-$DEF_PREFIX}"

  RV32="$OUT/${PREFIX}_npu_rv32.bin"
  DATA="$OUT/${PREFIX}_npu_data.bin"
  [ -s "$RV32" ] || { echo "::error::缺镜像 $RV32"; exit 1; }
  [ -s "$DATA" ] || { echo "::error::缺镜像 $DATA"; exit 1; }

  # 该变体的 gitrev / 体积：重新读一次对应变体的构建记录
  GITREV="$(git -C "$WORK/ClankerNPU" rev-parse --short HEAD 2>/dev/null || echo "${NPU_GITREV:-unknown}")"
  RS="$(stat -c%s "$RV32")"
  DS="$(stat -c%s "$DATA")"

  PKG_DIR="$PKG_OUT_DIR/$NAME"
  rm -rf "$PKG_DIR"
  mkdir -p "$PKG_DIR/src"
  cp "$RV32" "$PKG_DIR/src/${PREFIX}_npu_rv32.bin"
  cp "$DATA" "$PKG_DIR/src/${PREFIX}_npu_data.bin"

  # 冲突项：stock 三个 + 除自己以外的其他变体
  CONFLICTS=""
  for r in $RESERVED; do CONFLICTS="${CONFLICTS}	${r}\n"; done
  for o in $OTHERS; do
    [ "$o" = "$NAME" ] && continue
    CONFLICTS="${CONFLICTS}	${o}\n"
  done

  sed \
    -e "s|@PKG_NAME@|$NAME|g" \
    -e "s|@PKG_VERSION@|$GITREV|g" \
    -e "s|@SOC@|$SOC|g" \
    -e "s|@WIFI@|$v|g" \
    -e "s|@GITREV@|$GITREV|g" \
    -e "s|@FW_PREFIX@|$PREFIX|g" \
    -e "s|@TITLE@|Airoha ${SOC} NPU firmware (${v}, built from ClankerNPU)|g" \
    "$TEMPLATE" > "$PKG_DIR/Makefile.tmpl"
  # conflicts 是多行块，单独处理（sed 不好塞 \n）
  awk -v c="$(printf "$CONFLICTS")" '{ if ($0 == "@CONFLICTS@") printf "%s\n", c; else print }' \
    "$PKG_DIR/Makefile.tmpl" > "$PKG_DIR/Makefile"
  rm -f "$PKG_DIR/Makefile.tmpl"

  echo "✅ 生成可选包: $PKG_DIR"
  echo "   -> CONFIG_PACKAGE_${NAME}=y"
  echo "   -> src/${PREFIX}_npu_rv32.bin ($RS bytes)"
  echo "   -> src/${PREFIX}_npu_data.bin ($DS bytes)"

  ENV_PKGS="${ENV_PKGS}${NAME}|${SOC}|${v}|${PREFIX}|${GITREV}|${RS}|${DS}\n"

  # 记录「默认勾选变体」的元信息（Release 说明要用）
  if [ "$i" -eq 0 ]; then
    SELECTED_PKG="$NAME"; SEL_RS="$RS"; SEL_DS="$DS"; SEL_REV="$GITREV"; SEL_PREFIX="$PREFIX"
  fi
  if [ "$v" = "$NPU_DEFAULT_WIFI" ]; then
    SELECTED_PKG="$NAME"; SEL_RS="$RS"; SEL_DS="$DS"; SEL_REV="$GITREV"; SEL_PREFIX="$PREFIX"
  fi
done

# 变体里没有 NPU_DEFAULT_WIFI 时退回第一个
[ -z "$SELECTED_PKG" ] && SELECTED_PKG="${PKG_NAMES[0]}"

# ------------------------------------------------------------------
# 4) 兜底：可选地把镜像也铺进 files/（files/ 在 ipk 安装之后才铺，必然覆盖）
#    默认关 —— 关掉才能保证「包置 n 就真的没有固件」，保持可选语义。
# ------------------------------------------------------------------
if [ "$FALLBACK_FILES" = "true" ]; then
  SEL_PREFIX="${FW_PREFIX:-$DEF_PREFIX}"
  mkdir -p "$PONWRT_DIR/files/lib/firmware/airoha"
  cp "$WORK/out/${SOC}_${NPU_DEFAULT_WIFI}/${SEL_PREFIX}_npu_rv32.bin" \
     "$PONWRT_DIR/files/lib/firmware/airoha/" 2>/dev/null || \
  cp "$WORK/out/${SOC}_${PKG_WIFIS[0]}/${SEL_PREFIX}_npu_rv32.bin" \
     "$PONWRT_DIR/files/lib/firmware/airoha/"
  cp "$WORK/out/${SOC}_${NPU_DEFAULT_WIFI}/${SEL_PREFIX}_npu_data.bin" \
     "$PONWRT_DIR/files/lib/firmware/airoha/" 2>/dev/null || \
  cp "$WORK/out/${SOC}_${PKG_WIFIS[0]}/${SEL_PREFIX}_npu_data.bin" \
     "$PONWRT_DIR/files/lib/firmware/airoha/"
  echo "::warning::FALLBACK_FILES=true：镜像同时铺进 files/lib/firmware/airoha（包置 n 也会生效）"
fi

# ------------------------------------------------------------------
# 5) 写元信息供后续步骤使用
# ------------------------------------------------------------------
printf "$ENV_PKGS" > "$WORK/npu-fw-packages.txt"
cat > "$WORK/npu-fw.env" <<EOF
NPU_SOC=$SOC
NPU_WIFI=$NPU_DEFAULT_WIFI
NPU_CLANKER=$CLANKER
NPU_GITREV=$(git -C "$WORK/ClankerNPU" rev-parse --short HEAD 2>/dev/null || echo unknown)
NPU_FW_PREFIX=${FW_PREFIX:-$DEF_PREFIX}
NPU_PKG=$SELECTED_PKG
NPU_PKG_DIR=$PKG_OUT_DIR/$SELECTED_PKG
NPU_VARIANTS=$(echo "${PKG_WIFIS[@]}" | tr ' ' ',')
NPU_RV32_SIZE=$SEL_RS
NPU_DATA_SIZE=$SEL_DS
EOF

echo "=================================================="
echo "可选 NPU 固件包清单（$WORK/npu-fw-packages.txt）:"
cat "$WORK/npu-fw-packages.txt"
echo "--------------------------------------------------"
echo "默认勾选: CONFIG_PACKAGE_${SELECTED_PKG}=y"
echo "=================================================="
