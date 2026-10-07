# ==================================================================
# airoha-npu-clanker-firmware
#   Airoha NPU (RISC-V) 固件，由 ClankerConstruction/ClankerNPU 现场编译，
#   产物由 scripts/build-npu-fw.sh 放进 files/lib/firmware/airoha/。
#
#   目录名必须等于包名（buildroot 约定 PKG_NAME ?= $(notdir ${CURDIR})），
#   拷进 package/custom 时不要改名。
# ==================================================================
include $(TOPDIR)/rules.mk

PKG_NAME:=airoha-npu-clanker-firmware
PKG_VERSION:=1.0
PKG_RELEASE:=1

# 与 linux-firmware 提供的官方固件装的是同一批文件名，运行时必须互斥
Package/airoha-npu-clanker-firmware/conflicts = \
	airoha-en7581-npu-firmware \
	airoha-en7581-mt7996-npu-firmware \
	airoha-an7583-npu-firmware

include $(INCLUDE_DIR)/package.mk

define Package/airoha-npu-clanker-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Airoha NPU firmware built from ClankerNPU
  DEPENDS:=@TARGET_airoha
  MAINTAINER:=qwe3017
endef

define Package/airoha-npu-clanker-firmware/description
  Bare-metal firmware for the RISC-V NPU inside the Airoha AN75xx SoC,
  cross-built from ClankerConstruction/ClankerNPU instead of shipping the
  linux-firmware copy. Installs /lib/firmware/airoha/<prefix>_npu_rv32.bin
  and <prefix>_npu_data.bin, the file names the airoha_npu host driver
  requests (en7581_* for AN7581, an7583_* for AN7583 by default).
endef

# 纯二进制包：没有源码要解，也没有东西要编
define Build/Prepare
endef

define Build/Compile
endef

define Package/airoha-npu-clanker-firmware/install
	$(INSTALL_DIR) $(1)/lib/firmware/airoha
	$(CP) ./files/lib/firmware/airoha/. $(1)/lib/firmware/airoha/
endef

$(eval $(call BuildPackage,airoha-npu-clanker-firmware))
