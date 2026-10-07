#!/usr/bin/env bash
# ==================================================================
# 给机型 DTS 补 NPU 节点内容（在 ponwrt 源码根目录执行）
#
# 做两件事，都由调用方用环境变量控制：
#   1. 引入 WiFi 卸载必需的保留内存区（pkt / tx-pkt / tx-bufid / ba）
#      airoha_npu 驱动的 airoha_npu_wlan_init_memory() 按名字查这三块，
#      缺一个 WiFi 卸载初始化就失败；只做有线 PPE/HWNAT 卸载不需要。
#   2. 当固件名不是驱动默认名时，写 firmware-name 属性（rv32 在前、data 在后）
#
#   ADD_WLAN_MEM=false|true    是否补内存区（默认 true）
#   SOC      an7581|an7583     （默认 an7581）
#   PROFILE  机型 profile       （用于挑要改哪个 dts / dtsi）
#   WIFI     MT7916|...         （NOWIFI 时跳过）
#   FW_PREFIX                  固件名前缀，非默认才写 firmware-name
#   PONWRT_DIR                 源码根目录，默认 .
# ==================================================================
set -euo pipefail

PONWRT_DIR="${PONWRT_DIR:-.}"
SOC="${SOC:-an7581}"
PROFILE="${PROFILE:-}"
WIFI="${WIFI:-MT7916}"
ADD_WLAN_MEM="${ADD_WLAN_MEM:-true}"
FW_PREFIX="${FW_PREFIX:-}"

case "$(echo "$SOC" | tr 'a-z' 'A-Z')" in
  AN7581) DEF_PREFIX="en7581"; SOC_LC="an7581" ;;
  AN7583) DEF_PREFIX="an7583"; SOC_LC="an7583" ;;
  *)      DEF_PREFIX="$SOC";   SOC_LC="$SOC" ;;
esac
FW_PREFIX="${FW_PREFIX:-$DEF_PREFIX}"

DTS_DIR="$PONWRT_DIR/target/linux/airoha/dts"
[ -d "$DTS_DIR" ] || { echo "::error::找不到 $DTS_DIR，检查 PONWRT_DIR"; exit 1; }

if [ "$ADD_WLAN_MEM" != "true" ]; then
  echo ">>> ADD_WLAN_MEM=false，跳过 DTS 修改"
  exit 0
fi

if [ "$WIFI" = "NOWIFI" ]; then
  echo ">>> WIFI=NOWIFI，不需要 WiFi 卸载内存区，跳过"
  exit 0
fi

if [ "$SOC_LC" != "an7581" ]; then
  echo "::warning::ponwrt 目前只有 an7581-npu-wlan.dtsi（an7583 的内存区布局不同），跳过 DTS 修改"
  echo "::warning::若你的 an7583 机型确实需要，请参照 an7581-npu-wlan.dtsi 自行补一份"
  exit 0
fi

# ------------------------------------------------------------------
# 机型 -> 要改的 dts / dtsi
#   MT7916 机型（烽火 HG5585F-CT/CU、兆能 ZN515XG-D、ZN504XG-D）共用
#   一份 common.dtsi，改一处即可覆盖 CT/CU 与 ZN50x 两个机型。
# ------------------------------------------------------------------
case "$PROFILE" in
  fiberhome_hg5585f-ct|fiberhome_hg5585f-cu) TARGETS="an7581-fiberhome-hg5585f-common.dtsi" ;;
  znxt_zn515xg-d|znxt_zn504xg-d)             TARGETS="an7581-znxt-zn50xg-d-common.dtsi" ;;
  fiberhome_hg5382a)                          TARGETS="an7581-fiberhome-hg5382a.dts" ;;
  gemtek_xg2010g)                             TARGETS="an7581-gemtek-xg2010g.dts" ;;
  unionman_ung00a)                            TARGETS="an7581-unionman-ung00a.dts" ;;
  nokia_xg-040g-md-ubi)                       TARGETS="an7581-nokia_xg-040g-md-common.dtsi" ;;
  nokia_xg-040g-tf-ubi)                       TARGETS="an7581-nokia_xg-040g-tf-common.dtsi" ;;
  h3c_hm2004-du)                              TARGETS="an7581-h3c-hm2004-du.dts" ;;
  all|"")
    echo "::warning::profile=${PROFILE:-空} 无法定位要改的 DTS，跳过（可先手动确认机型 dts 名后改 TARGETS）"
    exit 0 ;;
  *) TARGETS="an7581-${PROFILE}.dts" ;;
esac

# ------------------------------------------------------------------
# 生成 dtsi
# ------------------------------------------------------------------
DTSI="$DTS_DIR/an7581-npu-clanker.dtsi"
{
  echo '// SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)'
  echo '/* 由 apply-npu-dts.sh 生成：NPU WiFi 卸载保留内存区 + 可选固件名 */'
  echo ''
  echo '#include "an7581-npu-wlan.dtsi"'
  echo ''
  if [ "$FW_PREFIX" != "$DEF_PREFIX" ]; then
    echo '&npu {'
    echo "	firmware-name = \"airoha/${FW_PREFIX}_npu_rv32.bin\","
    echo "			\"airoha/${FW_PREFIX}_npu_data.bin\";"
    echo '};'
  else
    echo "/* FW_PREFIX=$FW_PREFIX 即驱动默认名，无需 firmware-name */"
  fi
} > "$DTSI"
echo ">>> 生成 $DTSI"
sed -n '1,20p' "$DTSI"

# ------------------------------------------------------------------
# 插进机型 dts（放在 #include "an7581.dtsi" 之后）
# ------------------------------------------------------------------
for t in $TARGETS; do
  f="$DTS_DIR/$t"
  if [ ! -f "$f" ]; then
    echo "::warning::DTS 不存在，跳过: $f"
    continue
  fi
  if grep -q 'an7581-npu-clanker.dtsi' "$f"; then
    echo ">>> 已包含，跳过: $t"
    continue
  fi
  if grep -q '#include "an7581.dtsi"' "$f"; then
    sed -i 's|#include "an7581\.dtsi"|#include "an7581.dtsi"\n#include "an7581-npu-clanker.dtsi"|' "$f"
    echo "✅ 已给 $t 加上 an7581-npu-clanker.dtsi"
  else
    echo "::warning::$t 里没找到 #include \"an7581.dtsi\"，请手动插入 #include \"an7581-npu-clanker.dtsi\""
  fi
done
