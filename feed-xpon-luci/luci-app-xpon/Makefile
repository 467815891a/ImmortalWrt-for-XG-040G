# SPDX-License-Identifier: GPL-2.0-only
#
# Wraps https://github.com/naoki66/airoha-xpon-luci (xpon-luci 2.9, 2026-08-31)
# as an OpenWrt feed package. The upstream repo ships a rootfs overlay
# (etc/lib/usr/www) meant for tar-over-device installs, so the tree is vendored
# under files/ and installed verbatim.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xpon
PKG_VERSION:=2.9
PKG_RELEASE:=1
PKG_MAINTAINER:=naoki66
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-xpon
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Airoha xPON management (auth/OMCI/services/DDM)
  DEPENDS:=+luci-compat +luci-lib-nixio
endef

define Package/luci-app-xpon/description
  LuCI application for the Airoha EN7581/EN7572 xPON driver stack: GPON/XGPON/
  EPON authentication (LOID/SN/password), OMCI/OAM debugging, PON VLAN and
  IPTV multicast management, optical DDM status monitoring.

  Kernel side (/dev/pon, pon/omci/oam interfaces) comes from
  kmod-airoha-xpon-en757x; module loading and ponctl CLI from
  airoha-pon-manager. Authentication apply additionally needs the vendor
  tools under /userfs/bin (omcicfgCmd/oamcfgCmd/xponigmpcmd), provided on
  ImmortalWrt by airoha-xpon-vendor-tools.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/files/. $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-xpon/install
	$(INSTALL_DIR) $(1)
	$(CP) $(PKG_BUILD_DIR)/. $(1)/
	chmod 755 $(1)/etc/init.d/* $(1)/etc/uci-defaults/* \
		$(1)/etc/hotplug.d/iface/* $(1)/lib/preinit/* \
		$(1)/usr/bin/* $(1)/usr/libexec/*
endef

$(eval $(call BuildPackage,luci-app-xpon))
