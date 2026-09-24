#!/bin/bash
# ================================================================
# diy-part2.sh —— 只做一件事：把默认时区改成中国（Asia/Shanghai, CST-8）
# 运行目录: ponwrt 源码根目录（加载 .config 之后）
# ================================================================

echo "=========================================="
echo "设置时区为中国 (diy-part2.sh)"
echo "=========================================="

# ---------------------------------------------------------
# 1. 修改 config_generate 的默认值（首次开机生成的 /etc/config/system）
# ---------------------------------------------------------
CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
  # 原值形如：set system.@system[-1].timezone='UTC'
  sed -i "s/option timezone.*/option timezone 'CST-8'/" "$CFG"
  sed -i "s/option zonename.*/option zonename 'Asia\/Shanghai'/" "$CFG"
 # 修改默认 IP (192.168.30.1)
  sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
  sed -i 's/hostname='.*'/hostname='PonWrt'/g' package/base-files/files/bin/config_generate

  echo "✅ config_generate 默认时区 -> CST-8 / Asia/Shanghai"
else
  echo "::warning::未找到 $CFG，跳过默认值修改"
fi

# ---------------------------------------------------------
# 2. uci-defaults：即使保留了旧配置也强制刷成中国时区
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
uci -q batch <<'UCI'
set system.@system[0].zonename='Asia/Shanghai'
set system.@system[0].timezone='CST-8'
commit system
UCI
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ uci-defaults 时区脚本已写入"

# ---------------------------------------------------------
# 3. 补上亚洲时区数据库包（LuCI 显示与时区切换需要）
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y    # 亚洲时区数据库（中国时区需要）" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"
fi

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

# 修复Rust本地编译LLVM
RUST_FILE="feeds/packages/lang/rust/Makefile"

if [ -f "$RUST_FILE" ]; then
  sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$RUST_FILE"
  echo "✅ Rust 已设置为本地编译 LLVM"
else
  RUST_FILE=$(find feeds/ -type f -name "Makefile" -path "*/lang/rust/*" | head -1)
  if [ -n "$RUST_FILE" ]; then
    sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$RUST_FILE"
    echo "✅ Rust 已设置为本地编译 LLVM (路径: $RUST_FILE)"
  else
    echo "⚠️ 未找到 Rust Makefile，跳过"
  fi
fi

echo "🎉 diy-part2.sh 执行完毕"
