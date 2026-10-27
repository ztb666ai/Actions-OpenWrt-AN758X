#!/bin/bash
# ================================================================
# diy-part.sh (for no WIFI) —— 默认值定制（.config 加载之后、defconfig 之前运行）
# 运行目录: ponwrt 源码根目录（由 build-ponwrt.yml 步骤 8 cd 进来调用）
#
# 功能清单：
#   [7.7]  USB 自动挂载到 /opt（mount-opt + hotplug + uci-defaults）
#   [7.9]  /etc/sysctl.conf 内核调优（AN7583 / 512MB / 无Zram）
#   [10]   默认 LAN IP=192.168.2.1、hostname=PonWrt、时区 Asia/Shanghai
#   [10.5] uci-defaults 强制中国时区（保配置升级也生效）
#   原有:  zoneinfo-asia / 固件版本后缀 / 自定义包开关
#
# ⚠ 本脚本不做 make defconfig —— defconfig 由 build-ponwrt.yml 步骤 9
#   统一执行（唯一一次），这里只写好 .config 和 files/ overlay。
# ================================================================
set -euo pipefail

# ---- 可调参数（均有默认值，可用环境变量覆盖，不必改代码）----
LAN_IP="${LAN_IP:-192.168.2.1}"                     # [10] 默认 LAN IP
LAN_HOSTNAME="${LAN_HOSTNAME:-ZtbWrt}"              # [10] 默认主机名
ENABLE_USB_OPT_MOUNT="${ENABLE_USB_OPT_MOUNT:-1}"   # [7.7] USB 自动挂载 /opt 开关
ENABLE_SYSCTL_TUNING="${ENABLE_SYSCTL_TUNING:-1}"   # [7.9] sysctl 调优开关

echo "=========================================="
echo "默认值定制 (diy-part2NoWiFi.sh)"
echo "  LAN_IP       = ${LAN_IP}"
echo "  LAN_HOSTNAME = ${LAN_HOSTNAME}"
echo "  USB /opt     = ${ENABLE_USB_OPT_MOUNT}"
echo "  sysctl 调优  = ${ENABLE_SYSCTL_TUNING}"
echo "=========================================="

# ================================================================
# [7.7] USB 自动挂载到 /opt（移植自 build-mf-NoOC 步骤 7.7）
# 依赖的 kmod（usb-storage/uas/fs-ext4/vfat/exfat/block-mount 等）
# 由机型 diffconfig 第 16 段 + 下方自定义包开关兜底提供。
# ================================================================
if [ "${ENABLE_USB_OPT_MOUNT}" = "1" ]; then
  mkdir -p files/usr/bin files/etc/hotplug.d/block files/etc/uci-defaults

  # ---- 1) 挂载/卸载辅助脚本 ----
  cat > files/usr/bin/mount-opt <<'EOF'
#!/bin/sh
# 将第一个未挂载的 USB/SD 分区挂载到 /opt
MOUNT_POINT="/opt"

do_mount() {
    local dev
    mkdir -p "$MOUNT_POINT"
    # /opt 已被占用则不重复挂
    grep -qs " ${MOUNT_POINT} " /proc/mounts && return 0
    for dev in /dev/sd[a-z][0-9]* /dev/mmcblk[0-9]p[0-9]*; do
        [ -b "$dev" ] || continue
        grep -qs "^${dev} " /proc/mounts && continue
        logger -t mount-opt "mounting ${dev} -> ${MOUNT_POINT}"
        mount -o rw,noatime "$dev" "$MOUNT_POINT" && return 0
    done
    return 1
}

do_umount() {
    local dev="${1}"
    grep -qs "^${dev} ${MOUNT_POINT} " /proc/mounts && umount "$MOUNT_POINT"
}

case "$1" in
    mount)  do_mount ;;
    umount) do_umount "$2" ;;
    *)      echo "usage: $0 mount|umount [dev]" ;;
esac
EOF
  chmod +x files/usr/bin/mount-opt

  # ---- 2) hotplug: 开机冷插拔 + 运行期热插拔 ----
  cat > files/etc/hotplug.d/block/40-mount-opt <<'EOF'
case "$ACTION" in
    add)
        case "$DEVNAME" in
            sd[a-z][0-9]*|mmcblk[0-9]p[0-9]*)
                # 后台执行避免阻塞 hotplug 队列; 等 1s 让设备节点就绪
                ( sleep 1; /usr/bin/mount-opt mount ) &
                ;;
        esac
        ;;
    remove)
        case "$DEVNAME" in
            sd[a-z][0-9]*|mmcblk[0-9]p[0-9]*)
                /usr/bin/mount-opt umount "/dev/$DEVNAME"
                ;;
        esac
        ;;
esac
EOF

  # ---- 3) 首次开机: 禁用 blockd, 并提前完成挂载 ----
  cat > files/etc/uci-defaults/99-mount-opt <<'EOF'
# blockd 会把 U 盘自动挂到 /mnt/sda1, 与 /opt 冲突, 禁用之
[ -x /etc/init.d/blockd ] && /etc/init.d/blockd disable
mkdir -p /opt
# S10 时 kmodloader 已加载 usb-storage, 稍等设备枚举后挂载
(
    n=0
    while [ "$n" -lt 10 ] && ! /usr/bin/mount-opt mount; do
        sleep 1
        n=$((n+1))
    done
) &
exit 0
EOF
  chmod +x files/etc/uci-defaults/99-mount-opt
  echo "✅ [7.7] USB auto-mount overlay generated (mount-opt / hotplug / uci-defaults)"
fi

# ================================================================
# [7.9] /etc/sysctl.conf 内核调优（移植自 build-mf-NoOC 步骤 7.9）
# 整体覆盖 base-files 自带文件；开机由 procd 执行 sysctl -p 加载。
# 内核不认识的 key 只会有 warning，不会阻塞启动。
# ================================================================
if [ "${ENABLE_SYSCTL_TUNING}" = "1" ]; then
  mkdir -p files/etc
  cat > files/etc/sysctl.conf <<'EOF'
# ===========================================
# XD-040-MF (AN7583 双核AES / 512MB / 无Zram) + OpenClash
# 场景：游戏 UDP 保活 / 2.5G 有线回程 / IPTV / 内存敏感型调优
# ===========================================

#### 1. 内存管理 (512MB 无 Zram 安全策略) ####
vm.swappiness = 0

# 应急水位 32MB (6.25%)：给 PPE/DMA 突发申请留足余量，防网络卡顿
vm.min_free_kbytes = 32768

# 0 = 启发式模式(默认)。保持 0；设 2 会禁止过量提交，Clash 下会导致 malloc 失败
vm.overcommit_memory = 0

# 低内存机器：加速 dentry/inode 缓存回收，给应用腾内存
vm.vfs_cache_pressure = 150
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# 内核 panic (含 OOM 死锁) 10 秒后自动重启自愈，512MB 无人值守必备
kernel.panic = 10

#### 2. 网络核心缓冲区 (2.5G 吞吐 + 512MB 平衡) ####
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 131072
net.core.wmem_default = 131072

# 开 HNAT 硬件卸载时 2000 够用；纯软转发跑满 2.5G 出现丢包则回调 4000
net.core.netdev_max_backlog = 2000

# ★ 补：NAPI 时间片预算，与 budget 配对
net.core.netdev_budget = 600
#net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 4096

#### 3. 游戏 UDP 保活 ####
net.netfilter.nf_conntrack_udp_timeout = 90
net.netfilter.nf_conntrack_udp_timeout_stream = 180

#### 4. TCP 协议栈 ####
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# 32/48/64MB 三级水位
net.ipv4.tcp_mem = 8192 12288 16384
net.ipv4.tcp_rmem = 4096 131072 4194304
net.ipv4.tcp_wmem = 4096 131072 4194304

# ★ 新增：限制 TIME_WAIT 总量，防 BT 场景积累吃内存
net.ipv4.tcp_max_tw_buckets = 16384

# ★ 新增：显式开启 syncookie 防洪
net.ipv4.tcp_syncookies = 1

# ★ 新增：代理链路 PMTU 黑洞自动探测
net.ipv4.tcp_mtu_probing = 1

# 可选：固件带 BBR 时取消注释（基座已编 kmod-tcp-bbr，此处无需 opkg）
# net.ipv4.tcp_congestion_control = bbr
# net.core.default_qdisc = fq

#### 5. UDP 协议栈水位 (★ 新增，游戏/OpenClash UDP 关键) ####
# 单位：页(4KB)，32/48/64MB，与 tcp_mem 对齐
net.ipv4.udp_mem = 8192 12288 16384
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

#### 6. 连接追踪 ####
# 65536 条 ≈ 20MB，家庭 + BT 足够；报 full 再临时提 131072 观察
net.netfilter.nf_conntrack_max = 65536

# ★ 新增：hash 桶 = max/4，降低冲突（若内核只读此项则删掉此行）
net.netfilter.nf_conntrack_buckets = 16384
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60

#### 7. 端口 / ARP / 文件句柄 ####
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
fs.file-max = 65536

#### 8. 路由器安全加固 (★ 新增) ####
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

#### 9. IPTV (原样保留) ####
net.ipv4.conf.all.force_igmp_version = 2
net.ipv4.conf.default.force_igmp_version = 2
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
  echo "✅ [7.9] files/etc/sysctl.conf overlay generated"
fi

# ================================================================
# [10] 默认 LAN IP / hostname / 时区（移植自 build-mf-NoOC 步骤 10）
# ponwrt(ImmortalWrt master) 的 config_generate 是
# `set system.@system[-1].xxx='...'` 格式，不是 uci 的 `option xxx` 格式，
# 旧版 sed 匹配不到（无声失效）。这里改用 python 精确替换，
# 匹配失败直接报错（fail fast），@system[[-0-9]+] 兼容新旧写法。
# ================================================================
CFG="package/base-files/files/bin/config_generate"
if [ -f "$CFG" ]; then
  LAN_IP="$LAN_IP" LAN_HOSTNAME="$LAN_HOSTNAME" python3 - "$CFG" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
lan_ip = os.environ.get("LAN_IP", "192.168.2.1")
hostname = os.environ.get("LAN_HOSTNAME", "PonWrt")

def must_replace(pattern, repl, label):
    global s
    s2, n = re.subn(pattern, repl, s, count=1)
    if n != 1:
        raise SystemExit(f"ERROR: config_generate patch failed: {label}")
    s = s2

must_replace(
    r'lan\) ipad=\$\{ipaddr:-"192\.168\.1\.1"\} ;;',
    'lan) ipad=${ipaddr:-"' + lan_ip + '"} ;;',
    "lan ip",
)
must_replace(
    r"(set system\.@system\[-?\d+\]\.hostname=)'[^']*'",
    "\\g<1>'" + hostname + "'",
    "hostname",
)
must_replace(
    r"(set system\.@system\[-?\d+\]\.timezone=)'[^']*'",
    "\\g<1>'CST-8'",
    "timezone",
)
must_replace(
    r"(set system\.@system\[-?\d+\]\.zonename=)'[^']*'",
    "\\g<1>'Asia/Shanghai'",
    "zonename",
)
open(p, "w", encoding="utf-8").write(s)
print("config_generate patched OK: LAN=" + lan_ip
      + " hostname=" + hostname + " TZ=Asia/Shanghai (CST-8)")
PY
  # 回显确认（python 已保证替换必然成功；|| true 防 set -e 误杀 grep）
  echo "--- patch result ---"
  grep -n "$LAN_IP" "$CFG" || true
  grep -n "$LAN_HOSTNAME" "$CFG" || true
  grep -n "CST-8" "$CFG" || true
else
  echo "::warning::未找到 $CFG，跳过默认 LAN/主机名/时区修改"
fi

# ================================================================
# [10.5] uci-defaults 强制中国时区（移植自 build-mf-NoOC 步骤 10.5）
# 保留旧配置升级/恢复出厂后也强制刷回中国时区。
# ================================================================
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
# Force China timezone (UTC+8) on every flash / keep-settings upgrade
[ -s /etc/config/system ] || exit 0
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q set system.@system[0].timezone='CST-8'
uci -q commit system
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ [10.5] uci-defaults 99-timezone-cn 已写入"

# ================================================================
# zoneinfo-asia —— 亚洲时区数据库（LuCI 时区显示/切换需要）
# ================================================================
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  # 亚洲时区数据库（中国时区需要）。注意：不要把注释写在 =y 同一行，
  # kconfig 解析 .config 时行内注释有被当成值一部分的风险。
  echo "CONFIG_PACKAGE_zoneinfo-asia=y" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"
fi

# ================================================================
# 固件版本后缀（LuCI 概览页显示 · 作者 · 构建时间）
# ================================================================
[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"
VER_CODE="$(sed -n 's/^CONFIG_VERSION_CODE="\(.*\)"$/\1/p' .config 2>/dev/null || true)"
if [ -n "$VER_CODE" ]; then
  DESC_BODY='%D %V %C'
else
  DESC_BODY='%D %V'
fi
[ -z "$FW_DESC_SUFFIX" ] && FW_DESC_SUFFIX="· ${FW_AUTHOR} · ${FW_BUILD_TIME}"

RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"
# 用 perl + 环境变量传替换文本：作者名/后缀里带 / | # & 都不会搞坏语法
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE

if [ -f "$RELEASE_TPL" ]; then
  perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$RELEASE_TPL"
  echo "✅ 固件版本模板 -> $FW_DESC_LINE"
else
  echo "::warning::未找到 $RELEASE_TPL，固件版本不会带构建信息"
fi

if [ -f "$OSREL_TPL" ]; then
  perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$OSREL_TPL"
  echo "✅ os-release 同步 -> $OSREL_LINE"
fi

# ================================================================
# 自定义包开关 —— defconfig 前最后一手
# （第三方包需 diy-part1.sh 先拉源，否则 defconfig 会静默剔除）
# ================================================================
if [ -f .config ]; then
  cat >> .config <<'EOF'

# ==== build-mf-NoOC 12. Custom configuration (diy-part2 port) ====
# --- 附加应用 ---
CONFIG_PACKAGE_udpxy=y
CONFIG_PACKAGE_acme-acmesh-dnsapi=y
CONFIG_PACKAGE_luci-app-acme=y
CONFIG_PACKAGE_luci-ssl-openssl=y
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_luci-app-uhttpd=y
CONFIG_PACKAGE_msmtp=y
CONFIG_PACKAGE_msmtp-mta=y
CONFIG_PACKAGE_mutt=y
CONFIG_PACKAGE_vim-fuller=y
CONFIG_PACKAGE_luci-app-dae=y
#CONFIG_PACKAGE_luci-app-honk=y
#CONFIG_PACKAGE_luci-app-openclash=y
#CONFIG_PACKAGE_luci-compat=y #for openclash
# --- 基础工具 ---
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_htop=y
# 让 usb-power(regulator-output) 节点有驱动认领，防止 usb-5v 被
# regulator late-cleanup 关闭（U 盘开机 ~34s 断电问题，等价 10.6 的防护）
CONFIG_PACKAGE_kmod-regulator-userspace-consumer=y
# EIP93 硬件加速（配合 10.7 内核补丁再开更好）
CONFIG_PACKAGE_kmod-crypto-hw-eip93=y
CONFIG_PACKAGE_kmod-cryptodev=y
CONFIG_PACKAGE_kmod-sched-bpf=y
CONFIG_PACKAGE_kmod-sched-cake=y
CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
CONFIG_PACKAGE_libopenssl-devcrypto=y
CONFIG_PACKAGE_bpftool=y

# --- 关闭默认包的模板 ---
# 普通包：# CONFIG_PACKAGE_xxx is not set
# CONFIG_PACKAGE_luci-theme-bootstrap is not set
# DEFAULT_PACKAGES 里的包要三前缀一起关；NPU 包禁止写这里（步骤 9 会 exit 1）
# CONFIG_PACKAGE_xxx is not set
# CONFIG_DEFAULT_xxx is not set
# CONFIG_MODULE_DEFAULT_xxx is not set
# add 2026/10/15 to remove i2c tools
# CONFIG_MODULE_DEFAULT_i2c-tools is not set
# CONFIG_PACKAGE_libi2c is not set
# CONFIG_PACKAGE_i2c-tools is not set
EOF
fi

# Change 默认Luci的主题为Argon
sed -i 's/+luci-theme-bootstrap/+luci-theme-argon/g; s/default Bootstrap theme/Argon theme/g' feeds/luci/collections/luci-light/Makefile

# Remove LuCI menus: System > Plugins, Network > Diagnostics
python3 - <<'PY' || exit 1
import json
menus = {
    'feeds/luci/modules/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json': 'admin/system/plugins',
    'feeds/luci/modules/luci-mod-network/root/usr/share/luci/menu.d/luci-mod-network.json': 'admin/network/diagnostics',
}
for path, node in menus.items():
    with open(path) as f:
        data = json.load(f)
    data.pop(node)
    with open(path, 'w') as f:
        json.dump(data, f, indent='\t')
PY
rm -f feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/plugins.js
rm -f feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/view/network/diagnostics.js

## Clean Go build cache and mod cache to resolve ddns-go compilation errors
#echo "=== Starting Go Environment and Cache Cleanup ==="

## 1. Clear any conflicting local Go environment caches
#go clean -modcache
#go clean -cache

## 2. Force reset Go Proxy to a stable mirror to avoid network download corruption
#export GOPROXY=https://goproxy.io,direct

## 3. Navigate to the ddns-go source directory (if downloaded via feeds) and force tidy
#if [ -d "feeds/packages/net/ddns-go" ]; then
#    echo "Tidying up ddns-go package dependencies..."
#    cd feeds/packages/net/ddns-go
#    # Force Git to reset any local uncommitted patch corruption if present
#    [ -d ".git" ] && git reset --hard HEAD
#    cd -
#fi

#echo "=== Go Environment and Cache Cleanup Complete ==="


echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"
