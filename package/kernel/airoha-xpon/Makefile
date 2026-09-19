# SPDX-License-Identifier: GPL-2.0-only
#
# XG2010G (Airoha EN7581) clean-room xPON driver package
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=airoha-xpon
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define KernelPackage/airoha-xpon
  SUBMENU:=Network Devices
  TITLE:=Airoha EN7581 xPON MAC driver (clean-room)
  DEPENDS:=@TARGET_airoha_an7581
  FILES:=$(PKG_BUILD_DIR)/airoha-xpon.ko
endef

define KernelPackage/airoha-xpon/description
  Clean-room xPON MAC driver for Airoha EN7581 (Gemtek XG2010G).
  Provides pon0 data netdev + omci0/oam0 raw-PDU channels.

  Not autoloaded on purpose: it claims the xPON MAC IRQs the BSP
  stack (kmod-airoha-xpon-en757x + airoha-pon-manager) also uses.
  Load manually with `modprobe airoha-xpon` after stopping the pon
  service when testing the clean-room path.
endef

define KernelPackage/airoha-en7572
  SUBMENU:=Network Devices
  TITLE:=Airoha EN7572 BOSA optical frontend driver (clean-room)
  DEPENDS:=@TARGET_airoha_an7581 +kmod-i2c-core +kmod-hwmon-core
  FILES:=$(PKG_BUILD_DIR)/airoha-en7572.ko
endef

define KernelPackage/airoha-en7572/description
  Clean-room driver for the EN7572 BoB optical frontend (I2C @0x50).
  Handles MD32 MCU firmware load, BoB calibration, DDM (optical power),
  LOS and burst-TX gating. Not autoloaded: load with
  `modprobe airoha-en7572` for DDM testing.
endef

define KernelPackage/airoha-en7572/install
	$(INSTALL_DIR) $(1)/lib/firmware/airoha/en7572
	$(INSTALL_DATA) ./files/airoha-en7572/A60993.elf.pm \
		$(1)/lib/firmware/airoha/en7572/A60993.elf.pm
	$(INSTALL_DATA) ./files/airoha-en7572/A60993.elf.dm \
		$(1)/lib/firmware/airoha/en7572/A60993.elf.dm
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)" \
		modules
endef

$(eval $(call KernelPackage,airoha-xpon))
$(eval $(call KernelPackage,airoha-en7572))
