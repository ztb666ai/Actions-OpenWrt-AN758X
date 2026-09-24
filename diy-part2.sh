#!/bin/bash
# diy-part2.sh —— 在 .config 载入之后、make defconfig 之前执行
#
# 做三类事：
#   1) 用文本方式强制开局 .config 里的开关（中文包、光器件、zoneinfo 等）
#   2) 改 package/base-files/files/bin/config_generate 本体，固化主机名与时区
#   3) 写 files/etc/uci-defaults/*，设备首次启动时固化时区 / LuCI 中文 / 硬件卸载
#
# ⚠ 重要：不要用 ./scripts/config —— 它是 kconfig 源码目录，不是可执行命令，
#       执行会报 "Is a directory" (exit 126)。这里一律用 sed 改 .config 文本，
#       最后由工作流里的 make defconfig 统一展开。
#
# ⚠ 时区只改 package/base-files/files/etc/config/system 无效：
#       首次启动 config_generate 会重新生成 /etc/config/system 并写回 UTC。
#       必须改 config_generate 本体。

set -e
CFG=".config"

# =================================================================
# 0. 工具函数：直接编辑 .config 文本
# =================================================================

# 强制开启（删除旧定义后追加 =y）
cfg_enable() {
    sed -i "/^$1=/d; /^# $1 is not set/d" "$CFG"
    echo "$1=y" >> "$CFG"
}

# 强制关闭（删除旧定义后追加 is not set）
cfg_disable() {
    sed -i "/^$1=/d; /^# $1 is not set/d" "$CFG"
    echo "# $1 is not set" >> "$CFG"
}

echo "=========================================="
echo "[diy-part2] 开始"
echo "=========================================="

# =================================================================
# 1. 主机名 —— 改 config_generate 本体
# =================================================================
CG="package/base-files/files/bin/config_generate"
if [ -f "$CG" ]; then
    sed -i 's/ImmortalWrt/PonWrt/g; s/OpenWrt/PonWrt/g' "$CG"
    sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
    echo "[diy-part2] 主机名已改为 PonWrt"
else
    echo "[diy-part2] 未找到 $CG，跳过主机名修改"
fi

# =================================================================
# 2. 时区 —— 改 config_generate 本体（关键）
# =================================================================
if [ -f "$CG" ]; then
    # uci set 写法（现代 OpenWrt / ImmortalWrt）
    sed -i "s/system\.@system\[-1\]\.timezone='UTC'/system.@system[-1].timezone='CST-8'/g" "$CG"
    sed -i "s/system\.@system\[-1\]\.zonename='UTC'/system.@system[-1].zonename='Asia\/Shanghai'/g" "$CG"
    # option 写法（部分版本）
    sed -i "s/option timezone 'UTC'/option timezone 'CST-8'/g" "$CG"
    sed -i "s/option zonename 'UTC'/option zonename 'Asia\/Shanghai'/g" "$CG"
    echo "[diy-part2] config_generate 时区已改为 CST-8 / Asia-Shanghai"
fi

# 兜底：base-files 自带的 /etc/config/system
SYS="package/base-files/files/etc/config/system"
if [ -f "$SYS" ]; then
    sed -i "s#option timezone 'UTC'#option timezone 'CST-8'#" "$SYS"
    sed -i "s#option zonename 'UTC'#option zonename 'Asia/Shanghai'#" "$SYS"
    echo "[diy-part2] base-files system 时区已改"
fi

# zoneinfo：没有 /usr/share/zoneinfo，Asia/Shanghai 解析不了
cfg_enable CONFIG_PACKAGE_zoneinfo-asia

# =================================================================
# 3. 中文语言包
#    现代 LuCI 的 i18n 包由 luci.mk 从 po/zh-cn/ 自动生成，
#    没有 luci-i18n-base-zh-cn 这种独立目录，所以查 po 目录才准。
# =================================================================
echo "===== 检查 LuCI 中文翻译源 (po/zh-cn) ====="
PO_DIRS=$(find feeds/luci package/feeds/luci -type d -name "zh-cn" 2>/dev/null || true)
PO_COUNT=$(printf '%s' "$PO_DIRS" | grep -c . || true)
echo "zh-cn 翻译目录数量：$PO_COUNT"
if [ "$PO_COUNT" -eq 0 ]; then
    echo "::warning::feeds/luci 里没有任何 po/zh-cn 目录，LuCI 界面不会有中文"
    echo "已存在的所有 luci 相关目录（前 20 个）："
    find feeds package -maxdepth 3 -type d -name "*luci*" 2>/dev/null | head -20 || true
else
    echo "$PO_DIRS" | head -10
fi

# 开启中文包（包名正确就生效，不对的 defconfig 会静默丢弃）
for p in luci-i18n-base-zh-cn \
         luci-i18n-firewall-zh-cn \
         luci-i18n-package-manager-zh-cn \
         luci-i18n-opkg-zh-cn \
         luci-i18n-pon-zh-cn \
         luci-i18n-iptv-zh-cn; do
    cfg_enable "CONFIG_PACKAGE_$p"
done

# =================================================================
# 4. 光器件驱动 —— 防止 defconfig 把 =y 重置回 =m
# =================================================================
DEVICE_NAME=$(grep -oE "^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_[A-Za-z0-9_-]+=y" "$CFG" \
              | head -1 | sed 's/.*DEVICE_//; s/=y$//')
echo "===== 目标机型：${DEVICE_NAME:-未指定} ====="

case "$DEVICE_NAME" in
    fiberhome_*)
        echo "烽火机型 -> GN28L95 / UX3363 (kmod-airoha-paged-bosa)"
        cfg_enable  CONFIG_PACKAGE_kmod-airoha-paged-bosa
        cfg_disable CONFIG_PACKAGE_kmod-airoha-en7572
        ;;
    *)
        echo "非烽火机型 -> EN7572 (kmod-airoha-en7572)"
        cfg_enable  CONFIG_PACKAGE_kmod-airoha-en7572
        cfg_disable CONFIG_PACKAGE_kmod-airoha-paged-bosa
        ;;
esac

# =================================================================
# 5. 其它易被 defconfig 重置为 =m 的模块，强制内置
#    =m 只产 ipk 不打进镜像，刷完机不会自带
# =================================================================
for m in kmod-mt7915e kmod-mt7916-firmware kmod-phy-airoha-en8811h \
         airoha-en8811h-firmware kmod-fs-ext4 kmod-fs-exfat kmod-fs-vfat \
         kmod-usb3 kmod-usb-storage kmod-usb-storage-uas; do
    if grep -qE "^(# )?CONFIG_PACKAGE_${m}( is not set|=)" "$CFG"; then
        cfg_enable "CONFIG_PACKAGE_$m"
    fi
done

# =================================================================
# 6. 首次启动固化（uci-defaults）
# =================================================================
mkdir -p files/etc/uci-defaults

cat > files/etc/uci-defaults/98-timezone <<'EOF'
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q commit system
exit 0
EOF

cat > files/etc/uci-defaults/99-luci-lang <<'EOF'
# LuCI 默认简体中文
# 语言代码是 zh_cn（下划线），不是 zh-cn
uci -q set luci.main=core
uci -q set luci.main.lang='zh_cn'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
EOF

cat > files/etc/uci-defaults/99-pon-offload <<'EOF'
# 硬件流卸载（AN7581 PPE / NPU）
uci -q set firewall.@defaults[0].flow_offloading=1
uci -q set firewall.@defaults[0].flow_offloading_hw=1
uci -q commit firewall
exit 0
EOF

chmod +x files/etc/uci-defaults/* 2>/dev/null || true

# ---------------------------------------------------------
# Remove legacy iptables dependencies from Docker (dockerd)
# ---------------------------------------------------------
DOCKER_MAKEFILE="feeds/packages/utils/dockerd/Makefile"

if [ -f "$DOCKER_MAKEFILE" ]; then
    echo "Patching Docker Makefile to remove legacy iptables dependencies..."
    # Remove iptables modules from the DEPENDS line
    sed -i 's/+iptables-mod-extra//g' "$DOCKER_MAKEFILE"
    sed -i 's/+iptables//g' "$DOCKER_MAKEFILE"
    sed -i 's/+ip6tables//g' "$DOCKER_MAKEFILE"
    sed -i 's/+kmod-ipt-nat6//g' "$DOCKER_MAKEFILE"
    sed -i 's/+kmod-ipt-nat//g' "$DOCKER_MAKEFILE"
    sed -i 's/+kmod-ipt-physdev//g' "$DOCKER_MAKEFILE"
    # Clean up any trailing double plusses or spaces left over from deletions
    sed -i 's/++/\+/g' "$DOCKER_MAKEFILE"
    sed -i 's/ \+/ /g' "$DOCKER_MAKEFILE"
else
    echo "Warning: Docker Makefile not found at $DOCKER_MAKEFILE"
fi

# Force Docker daemon to use nftables natively
mkdir -p files/etc/docker
cat <<EOF > files/etc/docker/daemon.json
{
  "iptables": false,
  "nftables": "enabled"
}
EOF

# =================================================================
# 7. 输出核对
# =================================================================
echo "===== 中文语言包开关 ====="
grep -E "^CONFIG_PACKAGE_luci-i18n.*zh-cn" "$CFG" || echo "::warning::没有任何 zh-cn 包"
echo "===== zoneinfo ====="
grep -E "^CONFIG_PACKAGE_zoneinfo" "$CFG" || echo "::warning::未开启 zoneinfo"
echo "===== 光器件驱动 ====="
grep -E "^CONFIG_PACKAGE_kmod-airoha-(en7572|paged-bosa)" "$CFG" || true

echo "[diy-part2] 完成"
