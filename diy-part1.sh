#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

mkdir -p package/custom

# 科学插件
# Passwall
#rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
#git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/custom/passwall-packages
#rm -rf feeds/luci/applications/luci-app-passwall
#git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall.git package/custom/passwall
#git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git package/custom/passwall2

# OpenClash
#rm -rf feeds/luci/applications/luci-app-openclash
#git clone --depth=1 -b dev https://github.com/vernesong/OpenClash.git package/custom/openclash

# Nikki / Momo
#git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki.git package/custom/nikki
#git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-momo.git package/custom/momo

# Daed
#git clone --depth=1 -b kix https://github.com/QiuSimons/luci-app-daed.git package/custom/daed
# git clone --depth=1 -b master https://github.com/QiuSimons/luci-app-daed.git package/custom/daed
# 添加 vmlinux-btf 模块
#git clone --depth=1 https://github.com/QiuSimons/vmlinux-btf.git package/custom/vmlinux-btf

# SSR+
#git clone --depth=1 https://github.com/fw876/helloworld.git package/custom/ssrp

# 功能插件
#git clone --depth=1 https://github.com/sirpdboy/luci-app-poweroffdevice.git package/custom/poweroffdevice
#git clone --depth=1 https://github.com/isalikai/luci-app-owq-wol.git package/custom/owq-wol
#git clone --depth=1 https://github.com/gdy666/luci-app-lucky.git package/custom/lucky
#git clone --depth=1 https://github.com/sbwml/luci-app-openlist2.git package/custom/openlist2

#git clone --depth=1 https://github.com/stackia/rtp2httpd.git package/custom/rtp2httpd

#git clone --depth=1 https://github.com/sirpdboy/luci-app-watchdog.git package/custom/watchdog
#git clone --depth=1 https://github.com/sirpdboy/luci-app-taskplan.git package/custom/taskplan
#git clone --depth=1 https://github.com/iv7777/luci-app-authshield.git package/custom/authshield
#git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/custom/OpenAppFilter
#git clone --depth=1 https://github.com/janvanstiphout/luci-app-accesscontrol.git package/custom/accesscontrol


# VPN
#git clone --depth=1 https://github.com/EasyTier/luci-app-easytier.git package/custom/easytier
#git clone --depth=1 https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community.git package/custom/tailscale-community

# 主题
# 必须先删掉 feeds 自带版本，否则会与 package/custom 这份同名冲突，
# 导致 configs 里 CONFIG_PACKAGE_luci-theme-argon=y 编译时用哪一份不确定
#rm -rf feeds/luci/themes/luci-theme-argon
#rm -rf feeds/luci/applications/luci-app-argon-config
#git clone --depth=1 -b openwrt-25.12 https://github.com/sbwml/luci-theme-argon.git package/custom/luci-theme-argon
#git clone --depth=1 https://github.com/sbwml/luci-app-argon-config.git package/custom/luci-app-argon-config
# change the default theme:
sed -i 's/+luci-theme-bootstrap/+luci-theme-argon/g; s/default Bootstrap theme/Argon theme/g' feeds/luci/collections/luci-light/Makefile
