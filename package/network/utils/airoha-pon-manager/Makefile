# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=airoha-pon-manager
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/airoha-pon-manager
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Airoha xPON management helpers
  DEPENDS:=+kmod-airoha-xpon-en757x +ip-full +uci
endef

define Package/airoha-pon-manager/description
 Init script and CLI helpers for Airoha EN7581/AN7583 GPON and EPON drivers.
endef

define Build/Compile
endef

define Package/airoha-pon-manager/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/pon $(1)/etc/config/pon
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/pon $(1)/etc/init.d/pon
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/ponctl $(1)/usr/sbin/ponctl
endef

$(eval $(call BuildPackage,airoha-pon-manager))
