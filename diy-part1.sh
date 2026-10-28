#!/bin/bash
# ================================================================
# diy-part1.sh —— 只做一件事：拉取可选插件到 package/custom
# 运行目录: ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
#
# 用法：把需要的插件开关改成 true，再到 configs/<机型>.config 里
#       把对应 "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
# ================================================================

echo "=========================================="
echo "拉取可选插件 (diy-part1.sh)"
echo "=========================================="

PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

# ---------------------------------------------------------
# 插件开关
# 默认开启：Airoha SoC 状态页（config 里已 =y，必须拉否则 defconfig 会剔除）
#
# 温度不再用 luci-app-temp-status —— 由 autocore 的 /sbin/tempinfo 提供，
# 见 files/sbin/tempinfo（概览页「温度」行：CPU / WiFi / PON 温度 + 光功率）
# ---------------------------------------------------------
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）

ADD_PASSWALL=false     # luci-app-passwall（含依赖源）
ADD_OPENCLASH=false    # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
ADD_MOSDNS=false       # luci-app-mosdns + v2ray-geodata
ADD_LUCKY=false        # luci-app-lucky（DDNS + socat）
ADD_TAILSCALE=false    # luci-app-tailscale
ADD_OPENLIST=false     # luci-app-openlist2（alist/openlist 挂载）
ADD_SMARTDNS=false     # luci-app-smartdns

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  if [ -d "$dir" ]; then
    echo "✅ 克隆成功: $dir"
    return 0
  fi
  echo "::error::克隆失败: $url"
  return 1
}

# --- Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）---
# 包名由目录名决定（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），
# 目录必须是 luci-app-airoha-npu，否则 config 里的符号对不上。
#
# 源用 luanmuc/luci-app-airoha-npu（rchen14b 的 fork 改进版）：
#   - 自带 po/zh_Hans 完整中文翻译（48 条）
#   - 无 rchen14b 那种「根目录 + 同名子目录」重复结构，feed 索引不会中断
#   - 修了 luci.mk 的 include 路径、加了独立 CPU 温度与 PLL 备用频率
if [ "$ADD_AIROHA_NPU" = "true" ]; then
  if ! clone https://github.com/luanmuc/luci-app-airoha-npu "$PKG_DIR/luci-app-airoha-npu" main; then
    echo "::error::luci-app-airoha-npu 拉取失败，后续 defconfig 会静默剔除该包"
    exit 1
  fi

  # 包名校验：Makefile 必须存在，否则 buildroot 扫不到这个包
  if [ ! -f "$PKG_DIR/luci-app-airoha-npu/Makefile" ]; then
    echo "::error::$PKG_DIR/luci-app-airoha-npu/Makefile 不存在，包无法被索引"
    exit 1
  fi
  echo "   版本: $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-airoha-npu/Makefile" 2>/dev/null)"
fi

# --- passwall ---
if [ "$ADD_PASSWALL" = "true" ]; then
  clone https://github.com/xiaorouji/openwrt-passwall-packages "$PKG_DIR/openwrt-passwall-packages" main
  clone https://github.com/xiaorouji/openwrt-passwall "$PKG_DIR/openwrt-passwall" main
  rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2" 2>/dev/null
fi

# --- mosdns ---
if [ "$ADD_MOSDNS" = "true" ]; then
  clone https://github.com/sbwml/luci-app-mosdns "$PKG_DIR/luci-app-mosdns" v5
  clone https://github.com/sbwml/v2ray-geodata "$PKG_DIR/v2ray-geodata" master
fi

# --- lucky ---
if [ "$ADD_LUCKY" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-lucky "$PKG_DIR/luci-app-lucky" main
fi

# --- tailscale ---
if [ "$ADD_TAILSCALE" = "true" ]; then
  clone https://github.com/asvow/luci-app-tailscale "$PKG_DIR/luci-app-tailscale" main
fi

# --- openlist2 ---
if [ "$ADD_OPENLIST" = "true" ]; then
  clone https://github.com/sbwml/luci-app-openlist2 "$PKG_DIR/luci-app-openlist2" main
fi

# --- smartdns ---
if [ "$ADD_SMARTDNS" = "true" ]; then
  clone https://github.com/pymumu/luci-app-smartdns "$PKG_DIR/luci-app-smartdns" master
  clone https://github.com/pymumu/smartdns "$PKG_DIR/smartdns" master
fi

# ---------------------------------------------------------
# 校验：默认开启的两个插件必须拉到，否则 defconfig 会静默剔除，
#       编出来的固件缺少状态页还不易察觉
# ---------------------------------------------------------
if [ "$ADD_AIROHA_NPU" = "true" ] && [ ! -d "$PKG_DIR/luci-app-airoha-npu" ]; then
  echo "::error::luci-app-airoha-npu 未拉到，config 里的 =y 会被 defconfig 剔除"
  exit 1
fi

# natmode / pon-status 来自 qwe3017/luci-app（config 里也是 =y）
for p in luci-app-natmode luci-app-pon-status; do
  if [ "$ADD_LUCI_APP" = "true" ] && [ ! -d "$PKG_DIR/$p" ]; then
    echo "::error::$p 未拉到，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
done

# ---------------------------------------------------------
# 清理重复嵌套目录
# rchen14b/luci-app-airoha-npu 这个仓库有问题：包在根目录放了一份，
# 又在同名子目录 luci-app-airoha-npu/ 里放了完整一份（含 Makefile）。
# feeds 扫描会把两层都当成独立包，内层 dump 失败（报
# "feeds/custom/luci-app-airoha-npu/luci-app-airoha-npu"）会中断整个
# custom feed 的索引，导致 package/feeds/custom 压根不生成，
# 所有包符号都不存在。
# ---------------------------------------------------------
echo "--- 检查重复嵌套目录 ---"
for d in "$PKG_DIR"/*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -d "$d/$n" ] && [ -f "$d/$n/Makefile" ]; then
    rm -rf "$d/$n"
    echo "✅ 已移除重复嵌套目录: $n/$n"
  fi
done

# ---------------------------------------------------------
# 让新包进入索引
#
#   ⚠️ 判据是 tmp/.packageinfo，不是 package/feeds/custom
#
#   OpenWrt 的 prepare-tmpinfo 直接扫 package/ 目录树：
#     include/scan.mk:  find -L package -mindepth 1 -maxdepth 5 -name Makefile
#   package/custom/<pkg>/Makefile 深度只有 3，本来就会被扫到，
#   **根本不需要注册 feed**。
#
#   以前那套 src-link custom feed 有两个问题：
#     ① feeds/custom 指向 package/custom，而 feeds/base 已经指向 ../package，
#        同一批 Makefile 被扫两遍，package-metadata.pl 按 Override 挑一个，
#        行为随扫描顺序漂移；
#     ② scripts/feeds 的 install_src() 里，$installed{$name} 已经非空
#        （就是 ① 扫出来的那份），于是直接 return 0，压根不建
#        package/feeds/custom/<pkg> 符号链接 ——
#        所以「package/feeds/custom 不存在」是**正常现象**，不是索引失败。
#        拿它当判据必然误报。
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then

  # =========================================================
  # 强制重建索引
  #   只删 tmp/.packageinfo 是不够的：prepare-tmpinfo 有 scan_unchanged
  #   优化（拿 tmp/info/.scan-*.stamp 比 mtime），stamp 还在且没有更新的
  #   Makefile 时它会跳过扫描 —— 结果 .packageinfo 被删了却没人重建，
  #   索引反而空了。所以 stamp 也要一起删。
  # =========================================================
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/.config-package.in tmp/.config-target.in

  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true

  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  echo "package/custom 内容："
  INDEX_MISS=""
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if [ ! -f "$d/Makefile" ]; then
      echo "  -  $n（无根 Makefile，视为源仓库/子包容器，跳过）"
      continue
    fi
    # 目录名即包名：buildroot 约定 PKG_NAME ?= $(notdir ${CURDIR})
    if grep -qx "Package: $n" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n"
    else
      echo "  ❌ $n —— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $n"
      # 真实错误在这里（scan.mk 落盘路径 logs/<SCAN_DIR>/<相对目录>/dump.txt）
      for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
        [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
      done
    fi
  done
  echo "------------------------------------------"
  echo "luci.mk: $([ -f feeds/luci/luci.mk ] && echo '✓' || echo '✗ 缺失（luci app 无法解析）')"
  echo "tmp/.packageinfo 包总数: $(grep -c '^Package: ' tmp/.packageinfo 2>/dev/null || echo 0)"
  echo "=========================================="

  # 必装插件（config 里是 =y 的那几个）必须进索引，否则 defconfig 会静默剔除
  REQUIRED=""
  [ "$ADD_AIROHA_NPU" = "true" ] && REQUIRED="$REQUIRED luci-app-airoha-npu"
  if [ "$ADD_LUCI_APP" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status"
  fi
  HARD_MISS=""
  for r in $REQUIRED; do
    grep -qx "Package: $r" tmp/.packageinfo 2>/dev/null || HARD_MISS="$HARD_MISS $r"
  done
  if [ -n "$HARD_MISS" ]; then
    echo "::error::以下必装插件未进入 tmp/.packageinfo，defconfig 会把 .config 里的 =y 静默剔除:$HARD_MISS"
    echo "  已索引缺失清单:$INDEX_MISS"
    exit 1
  fi
  [ -n "$INDEX_MISS" ] && echo "::warning::部分可选包未进入索引（不影响必装插件）:$INDEX_MISS"
else
  echo "未启用任何第三方插件"
fi

# https://github.com/QiuSimons/luci-app-dae
rm -rf feeds/luci/applications/luci-app-dae
git clone https://github.com/QiuSimons/luci-app-dae feeds/luci/applications/luci-app-dae

# Daed
git clone --depth=1 https://github.com/kenzok8/openwrt-honk.git package/custom/daed-honk
# git clone --depth=1 https://github.com/QiuSimons/luci-app-honk.git package/custom/daed-honk
# git clone --depth=1 https://github.com/breeze303/openwrt-honk.git package/custom/daed-honk
#git clone --depth=1 https://github.com/kenzok8/openwrt-daede.git package/custom/daede

echo "🎉 diy-part1.sh 执行完毕"
