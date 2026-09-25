# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI PON optics status (overview card)
LUCI_URL:=https://github.com/pbs05/openwrt-pon-userspace
LUCI_DEPENDS:=+luci-base +luci-mod-status +airoha-ponctl +jsonfilter
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage: feed scanner marker; luci.mk generates the package rules.
