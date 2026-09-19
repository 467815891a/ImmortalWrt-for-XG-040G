#!/bin/sh
# Replay settings only after netifd has started the OMCI/OAM engine. Patched
# S00 restores network.xpon_auth first; S11 provides the old-firmware fallback.
# This helper handles runtime/shared-memory-only attributes.

OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
tries=0
mac_applied=0

current_pon_mode() {
	local onu_type onu_high
	onu_type=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^onu_type=/) { print substr($i, 10); exit } }' /proc/cmdline 2>/dev/null)
	case "$onu_type" in
		[0-9A-Fa-f][0-9A-Fa-f]) : ;;
		*) onu_type=$(fw_printenv -n onu_type 2>/dev/null) ;;
	esac
	case "$onu_type" in [0-9A-Fa-f][0-9A-Fa-f]) : ;; *) return 1 ;; esac
	onu_high=${onu_type%?}
	case "$onu_high" in
		2|3|4|5|c|C) printf '%s' EPON ;;
		1|6|7) printf '%s' GPON ;;
		*) return 1 ;;
	esac
}

# 当前启动参数决定实际认证引擎；network 只用于缺少启动参数时的兼容回退。
configured_mode=$(uci -q get network.xpon_auth.pon_mode)
mode=$(current_pon_mode 2>/dev/null)
if [ -z "$mode" ]; then
	mode=$configured_mode
	[ "$mode" = EPON ] || mode=GPON
elif [ -n "$configured_mode" ] && [ "$configured_mode" != "$mode" ]; then
	logger -t xpon "replay: network pon_mode=$configured_mode 与当前 onu_type 引擎=$mode 不一致，以当前引擎为准"
fi

while [ "$tries" -lt 90 ]; do
	# GPON 系列的 PON MAC 只是 pon 业务接口地址，不必等待 OMCI。
	# 接口一出现就先应用一次；OMCI 就绪后严格重放还会再次回读确认。
	if [ "$mode" != "EPON" ] && [ "$mac_applied" = 0 ] && [ -e /sys/class/net/pon/address ]; then
		/usr/bin/xpon-apply.sh mac >/dev/null 2>&1 && mac_applied=1
	fi
	if [ "$mode" = "EPON" ]; then
		pidof epon_oam >/dev/null 2>&1 && "$OAM" get loid0 >/dev/null 2>&1 && break
	else
		pidof omci >/dev/null 2>&1 && "$OMCI" get sn >/dev/null 2>&1 && break
	fi
	tries=$((tries + 1))
	sleep 1
done

if [ "$tries" -ge 90 ]; then
	[ "$mode" = "EPON" ] || [ "$mac_applied" = 1 ] || /usr/bin/xpon-apply.sh mac >/dev/null 2>&1
	logger -t xpon "replay: OMCI 90 秒内未就绪，跳过本次重放"
	exit 1
fi

# Let ponmgr/OMCI/OAM finish their own shared-memory initialization first.
sleep 2
if [ "$mode" = "EPON" ]; then
	# apply auth 会先重启 epon_oam，再对新进程重放并回读全部 OAM 身份。
	if ! /usr/bin/xpon-apply.sh auth; then
		logger -t xpon "replay: EPON OAM 重启后身份（含 CTC ONUSN）重放失败，详见 /tmp/xpon-auth-native.log"
		exit 1
	fi
else
	if ! /usr/bin/xpon-auth-native.sh; then
		logger -t xpon "replay: 设备参数严格下发或回读失败，详见 /tmp/xpon-auth-native.log"
		exit 1
	fi
	# GPON 严格脚本负责逐项写入与回读，apply auth 触发 OMCI reconfig。
	/usr/bin/xpon-apply.sh auth || exit 1
fi
/usr/bin/xpon-apply.sh mac
/usr/bin/xpon-apply.sh iptv
/usr/bin/xpon-mvlan.sh
/usr/bin/pon-multicast apply-all
/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1 &
logger -t xpon "replay: 认证引擎就绪后身份与设备信息已重放"
