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

# ---------------------------------------------------------
# 本地包：CI 仓库自带的包（不在任何 feed 里），拷进 package/custom
# 当前两个：
#   luci-app-pon-status —— PON 光模块卡片，概览页「系统」下一格
#                          （文件名 15_pon.js 决定位置）
#   luci-app-natmode    —— NAT 类型三选一，菜单「网络 → NAT 类型」
# ---------------------------------------------------------
LOCAL_PKG_DIR="${GITHUB_WORKSPACE}/packages"
if [ -d "$LOCAL_PKG_DIR" ]; then
  for p in "$LOCAL_PKG_DIR"/*; do
    [ -d "$p" ] || continue
    # 目录名必须等于包名（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})）
    rm -rf "$PKG_DIR/$(basename "$p")"
    cp -r "$p" "$PKG_DIR/"
    echo "✅ 本地包: $(basename "$p")"
  done

  # git checkout / zip 传输可能丢掉 exec bit，导致 rpcd 无法 exec、
  # init.d 无法启动。这里统一补回来（另有 uci-defaults 开机兜底）。
  find "$PKG_DIR" -type f \
    \( -path "*/usr/sbin/*" -o -path "*/etc/init.d/*" -o -path "*/usr/libexec/*" \) \
    -exec chmod +x {} \; 2>/dev/null
fi

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

  # =========================================================
  # 关键：po 文件名必须改成 airoha-npu.po
  #
  # luci.mk 的 i18n install 规则：
  #   po2lmo $(po) → $(LUCI_LIBRARYDIR)/i18n/$(basename $(notdir $(po))).$(lang).lmo
  # 即 lmo 名取自 po 文件主名。而运行时按
  #   LUCI_BASENAME = $(patsubst luci-app-%,%,luci-app-airoha-npu) = airoha-npu
  # 查找 lmo。上游两份 po 都叫 luci-app-airoha-npu.po，
  # 会生成 luci-app-airoha-npu.zh-cn.lmo，前端找不到 → 中文不生效。
  # 官方 app 都是 basename 命名（firewall.po / package-manager.po / pon.po）。
  # =========================================================
  PODIR="$PKG_DIR/luci-app-airoha-npu/po"
  if [ -f "$PODIR/zh_Hans/luci-app-airoha-npu.po" ]; then
    # 确保 Language 头是 zh_Hans（上游头部缺该字段时 po2lmo 可能识别异常）
    grep -q '^"Language:' "$PODIR/zh_Hans/luci-app-airoha-npu.po" || \
      sed -i 's/^msgstr ""$/msgstr ""\n"Language: zh_Hans\\n"/' "$PODIR/zh_Hans/luci-app-airoha-npu.po"
    mv "$PODIR/zh_Hans/luci-app-airoha-npu.po" "$PODIR/zh_Hans/airoha-npu.po"
    echo "✅ po 改名: luci-app-airoha-npu.po -> airoha-npu.po（luci.mk 按 LUCI_BASENAME 查找）"
  fi
  if [ -f "$PODIR/es/luci-app-airoha-npu.po" ]; then
    mv "$PODIR/es/luci-app-airoha-npu.po" "$PODIR/es/airoha-npu.po"
  fi
  echo "   po/zh_Hans: $(ls -1 "$PODIR/zh_Hans/" 2>/dev/null | tr '\n' ' ')"
fi

# --- passwall ---
if [ "$ADD_PASSWALL" = "true" ]; then
  clone https://github.com/xiaorouji/openwrt-passwall-packages "$PKG_DIR/openwrt-passwall-packages" main
  clone https://github.com/xiaorouji/openwrt-passwall "$PKG_DIR/openwrt-passwall" main
  rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2" 2>/dev/null
fi

# --- openclash ---
if [ "$ADD_OPENCLASH" = "true" ]; then
  echo "::warning::OpenClash 会触发 Ruby/Rust 编译，耗时极长"
  clone https://github.com/vernesong/OpenClash "$PKG_DIR/OpenClash" master
  mv "$PKG_DIR/OpenClash/luci-app-openclash" "$PKG_DIR/luci-app-openclash" 2>/dev/null
  rm -rf "$PKG_DIR/OpenClash"
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
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then

  # =========================================================
  # 关键：把 package/custom 注册为 feed（src-link）
  # 否则 buildroot 的 metadata.pl 不会扫描这个目录，
  # 包符号压根不会生成，defconfig 就会把 .config 里
  # "CONFIG_PACKAGE_xxx=y" 当作无效符号静默删除 —— 不报错，
  # 表现为 clone 成功、目录存在，但固件里没有这个包。
  # =========================================================
  if ! grep -qE "^src-link[[:space:]]+custom" feeds.conf.default; then
    echo "src-link custom $PWD/package/custom" >> feeds.conf.default
    echo "✅ 已注册 feed: src-link custom $PWD/package/custom"
  else
    echo "feed 已注册: $(grep -E '^src-link[[:space:]]+custom' feeds.conf.default)"
  fi

  # 强制重建包索引，避免沿用旧的 tmp/.packageinfo
  rm -f tmp/.packageinfo tmp/.targetinfo 2>/dev/null

  ./scripts/feeds update custom 2>&1 | tail -3
  ./scripts/feeds install -a >/dev/null 2>&1 || true

  echo "=========================================="
  echo "package/custom 内容："
  ls -1 "$PKG_DIR"
  echo "------------------------------------------"
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    echo "  $(basename "$d") : $([ -f "$d/Makefile" ] && echo 'Makefile ✓' || echo 'Makefile ✗ 缺失')"
  done
  echo "------------------------------------------"
  echo "feeds 符号链接 package/feeds/custom/ :"
  ls -1 package/feeds/custom/ 2>/dev/null || echo "  ⚠ package/feeds/custom 不存在（索引可能失败）"
  echo "------------------------------------------"
  echo "luci.mk: $([ -f feeds/luci/luci.mk ] && echo '✓' || echo '✗ 缺失（luci app 无法解析）')"
  echo "=========================================="

  # =========================================================
  # 索引失败兜底 + 真实错误输出
  # feeds 脚本只说"详情见 dump.txt"，那个文件在日志里看不到，
  # 这里把它打印出来，并尝试回退方案：直接塞进已安装的 luci feed
  # =========================================================
  if [ ! -d package/feeds/custom ] || [ -z "$(ls -A package/feeds/custom 2>/dev/null)" ]; then
    echo "::warning::custom feed 索引未生成，打印真实错误："
    for f in logs/feeds/custom/*/*/dump.txt logs/feeds/custom/*/dump.txt; do
      [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
    done 2>/dev/null

    echo ""
    echo "--- 尝试回退：拷入 feeds/luci/applications ---"
    if [ -d feeds/luci/applications ]; then
      for d in "$PKG_DIR"/*; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        rm -rf "feeds/luci/applications/$n"
        cp -r "$d" "feeds/luci/applications/$n"
        echo "  已拷贝: $n"
      done
      ./scripts/feeds install -a >/dev/null 2>&1 || true
      echo "  回退后 package/feeds/luci/ :"
      ls -1 package/feeds/luci/ 2>/dev/null | grep -E "airoha-npu|pon-status|natmode" || echo "    ⚠ 仍未出现"
    fi
  fi
else
  echo "未启用任何第三方插件"
fi

# change the default theme:
sed -i 's/+luci-theme-bootstrap/+luci-theme-argon/g; s/default Bootstrap theme/Argon theme/g' feeds/luci/collections/luci-light/Makefile
./scripts/feeds install -a

echo "🎉 diy-part1.sh 执行完毕"
