# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI NAT mode selector (Full Cone / Restricted / Symmetric)
LUCI_URL:=https://github.com/pbs05/ponwrt
LUCI_DEPENDS:=+luci-base +firewall4 +kmod-nft-fullcone +nftables-json
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage: feed scanner marker; luci.mk generates the package rules.
