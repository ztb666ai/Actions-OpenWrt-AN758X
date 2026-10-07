#!/usr/bin/env bash
# ==================================================================
# 用 ClankerConstruction/ClankerNPU 编译 Airoha NPU 固件
#
# 产物命名按内核驱动 drivers/net/ethernet/airoha/airoha_npu.c 的约定：
#   rv32 -> airoha/<FW_PREFIX>_npu_rv32.bin  （≤ 0x200000，加载进 npu_binary @0x84000000）
#   data -> airoha/<FW_PREFIX>_npu_data.bin  （≤ 0x10000， 加载进 NPU 本地 SRAM）
#   FW_PREFIX 用各 SoC 的驱动默认名时无需改 DTS：
#       AN7581 -> en7581   （驱动默认 airoha/en7581_npu_rv32.bin，注意是 EN 不是 AN）
#       AN7583 -> an7583
#   自定义前缀则由 apply-npu-dts.sh 写 DTS firmware-name 属性指定。
#
# 产物默认落在 files/lib/firmware/airoha/（历史行为：files/ 会覆盖进 rootfs）。
#
# ⚠️ 现在推荐走「可选插件包」：由 scripts/gen-npu-fw-package.sh 调用本脚本，
#    再把镜像包成 package/custom/airoha-<soc>-<wifi>-npu-firmware/，
#    于是可以用 CONFIG_PACKAGE_airoha-en7581-mt7916-npu-firmware=y 勾选。
#    配套两步（缺一不可）：
#      · scripts/strip-default-npu-fw.sh 摘掉 DEFAULT_PACKAGES 里的 stock 固件
#      · 生成包后 re-index custom feed，否则 CONFIG_PACKAGE_xxx 符号不存在
#
# 用法（全部走环境变量，便于 GitHub Actions 直接传）：
#   SOC=AN7581 WIFI=MT7916 ./scripts/build-npu-fw.sh
#   SOC=AN7583 WIFI=MT7993 CLANKER=1 FW_PREFIX=an7583_mt7993 ./scripts/build-npu-fw.sh
# ==================================================================
set -euo pipefail

SOC="${SOC:-AN7581}"
WIFI="${WIFI:-MT7916}"
# 0 = 适配 ponwrt / mainline 自带的 airoha_npu 驱动（推荐）
# 1 = 适配 Clanker 自己改过的 host driver（换固件的同时必须换驱动）
CLANKER="${CLANKER:-0}"
REPO="${CLANKER_REPO:-https://github.com/ClankerConstruction/ClankerNPU}"
# 源码 ref：默认跟 main 最新；也可以填 commit sha / tag / 分支名钉死版本
CLANKER_REF="${CLANKER_REF:-main}"
XPACK_VER="${XPACK_VER:-14.2.0-3}"

# 固件前缀：未指定时按 SoC 用驱动默认名
case "$SOC" in
  AN7581) DEF_PREFIX="en7581" ;;
  AN7583) DEF_PREFIX="an7583" ;;
  AN7552) DEF_PREFIX="en7581" ;;
  *)      DEF_PREFIX="$(echo "$SOC" | tr 'A-Z' 'a-z')" ;;
esac
FW_PREFIX="${FW_PREFIX:-$DEF_PREFIX}"

OUT_DIR="${OUT_DIR:-$(pwd)/files/lib/firmware/airoha}"
WORK="${WORK:-$(pwd)/.clanker-build}"

RV32_MAX=$((0x200000))
DATA_MAX=$((0x10000))

# ------------------------------------------------------------------
# 0) 变体白名单校验：ClankerNPU 只有这 11 个组合，写错直接早失败
# ------------------------------------------------------------------
valid=0
for v in AN7552_MT7916 AN7552_MT7991 AN7552_MT7993 \
         AN7581_MT7916 AN7581_MT7992 AN7581_MT7996 \
         AN7583_MT7916 AN7583_MT7992 AN7583_MT7993 AN7583_MT7996 AN7583_NOWIFI; do
  [ "${SOC}_${WIFI}" = "$v" ] && valid=1
done
if [ "$valid" -ne 1 ]; then
  echo "::error::$SOC + $WIFI 不是 ClankerNPU 支持的变体（共 11 个：AN7552/AN7581/AN7583 × MT7916/MT7991/MT7992/MT7993/MT7996/NOWIFI）"
  exit 1
fi

mkdir -p "$WORK" "$OUT_DIR"

# ------------------------------------------------------------------
# 1) 裸机 RISC-V 工具链
#    必须是 riscv*-*-elf（newlib）：固件用 -march=rv32imc_zicsr_zifencei -mabi=ilp32 编，
#    Ubuntu 源里的 riscv64-linux-gnu 编不了这种裸机目标。
# ------------------------------------------------------------------
TC_DIR="$WORK/xpack-riscv-none-elf-gcc-$XPACK_VER"
if [ ! -x "$TC_DIR/bin/riscv-none-elf-gcc" ]; then
  echo ">>> 下载 xpack riscv-none-elf-gcc $XPACK_VER"
  curl -fsSL -o "$WORK/xpack.tar.gz" \
    "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${XPACK_VER}/xpack-riscv-none-elf-gcc-${XPACK_VER}-linux-x64.tar.gz"
  mkdir -p "$TC_DIR"
  tar -xf "$WORK/xpack.tar.gz" -C "$TC_DIR" --strip-components=1
  rm -f "$WORK/xpack.tar.gz"
fi
export PATH="$TC_DIR/bin:$PATH"
echo ">>> $(riscv-none-elf-gcc --version | head -1)"

# ------------------------------------------------------------------
# 2) 拉固件源码
# ------------------------------------------------------------------
SRC="$WORK/ClankerNPU"
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$REPO"
fi
# CLANKER_REF 可以是分支名(main)、tag 或 commit sha。
# 浅拉后统一 checkout FETCH_HEAD —— 分支名和 sha 都能解析，
# 而 git fetch <branch> 不会创建本地分支引用，直接 checkout <branch> 会失败。
if git -C "$SRC" fetch -q --depth 1 origin "$CLANKER_REF" 2>/dev/null; then
  git -C "$SRC" checkout -q FETCH_HEAD
else
  echo ">>> 按 ref 浅拉失败，改为全量拉取后按名字 checkout"
  git -C "$SRC" fetch -q origin
  git -C "$SRC" checkout -q "$CLANKER_REF" || git -C "$SRC" checkout -q FETCH_HEAD
fi
GITREV="$(git -C "$SRC" rev-parse --short HEAD)"
echo ">>> ClankerNPU @ $GITREV  (ref=$CLANKER_REF, ${SOC}_${WIFI})"

# ------------------------------------------------------------------
# 3) 编译
# ------------------------------------------------------------------
echo ">>> make SOC=$SOC WIFI=$WIFI CLANKER=$CLANKER"
make -C "$SRC" \
  CROSS=riscv-none-elf- \
  SOC="$SOC" WIFI="$WIFI" CLANKER="$CLANKER" \
  GITREV="$GITREV"

BIN="$SRC/build/${SOC}_${WIFI}/npu_rv32.bin"
DATA="$SRC/build/${SOC}_${WIFI}/npu_data.bin"
if [ ! -s "$BIN" ] || [ ! -s "$DATA" ]; then
  echo "::error::编译产物缺失: $BIN / $DATA"
  exit 1
fi

# ------------------------------------------------------------------
# 4) 体积自检：超过驱动上限会被 -E2BIG 拒绝，NPU 直接起不来
# ------------------------------------------------------------------
rs=$(stat -c%s "$BIN")
ds=$(stat -c%s "$DATA")
echo ">>> npu_rv32.bin ${rs} bytes (上限 ${RV32_MAX})"
echo ">>> npu_data.bin ${ds} bytes (上限 ${DATA_MAX})"
if [ "$rs" -gt "$RV32_MAX" ]; then
  echo "::error::npu_rv32.bin 超过驱动上限 ${RV32_MAX} 字节"
  exit 1
fi
if [ "$ds" -gt "$DATA_MAX" ]; then
  echo "::error::npu_data.bin 超过驱动上限 ${DATA_MAX} 字节"
  exit 1
fi

# ------------------------------------------------------------------
# 5) 落位 + 写元信息（后续步骤/Release 说明要用）
# ------------------------------------------------------------------
cp "$BIN"  "$OUT_DIR/${FW_PREFIX}_npu_rv32.bin"
cp "$DATA" "$OUT_DIR/${FW_PREFIX}_npu_data.bin"
( cd "$OUT_DIR" && sha256sum "${FW_PREFIX}_npu_rv32.bin" "${FW_PREFIX}_npu_data.bin" )

cat > "$WORK/npu-fw.env" <<EOF
NPU_SOC=$SOC
NPU_WIFI=$WIFI
NPU_CLANKER=$CLANKER
NPU_GITREV=$GITREV
NPU_FW_PREFIX=$FW_PREFIX
NPU_RV32_SIZE=$rs
NPU_DATA_SIZE=$ds
EOF
echo ">>> 完成: $OUT_DIR"
