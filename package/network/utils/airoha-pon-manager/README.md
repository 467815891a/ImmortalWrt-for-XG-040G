# Airoha PON Manager

This package provides an OpenWrt management layer for the collection-based
Airoha EN7581/AN7583 xPON driver stack under
`add/airoha-collection-main/airoha-pon`:

- creates `/dev/pon` and `/dev/epon_mac`;
- loads the BSP, PHY and GPON/EPON-capable MAC module chain in order;
- passes `/etc/config/pon` `mode` to `xpon_10g mode=<n>`;
- brings `pon`, `pon0`, `omci` and `oam` links up when the driver creates them;
- exposes `ponctl status` for `/proc/xgpon`, `/proc/gpon`, `/proc/epon` and
  `/proc/pon_phy` diagnostics.

The `mode` names map to the vendor `XMCSIF_WanDetectionMode_t` order in
`src/bsp/include/global_inc/xpon_public_const.h`: `auto=0`, `gpon=1`,
`epon=2`, `xgpon=6`, `xgspon=7`, and the 10G/NGPON2 EPON variants in between.
The loaded value is visible with `ponctl modules` when `/sys/module/xpon_10g`
exposes the parameter.

`/etc/config/pon` separates generic xPON startup, GPON identity fields and EPON
management fields. These values are intentionally reported as
`ioctl-helper-pending` rather than written to the driver. The relevant vendor
entry points are present in the collection source (`xmcs_if.c`
`IO_IOS_WAN_DETECTION_MODE` / `IO_IOS_WAN_LINK_START`, and `epon_ioctl.c`
`EPON_IOCTL_*`), but applying credentials, GEM/T-CONT or LLID state needs a C
userspace helper with structures verified against the driver ABI.
