#!/bin/sh
# xpon-mvlan.sh —— 重放 network.wan_vlan 段内的组播 M-VLAN 白名单（开机/应用时调用）
#
# 下行组播帧 VID 必须先通过 xponigmpcmd mvlan add 登记，否则会在 ANI 入口丢弃。该表为内存表，
# 重启丢失，必须重放。设备 CLI 只支持 mvlan add/del/show。

IGMP=/userfs/bin/xponigmpcmd
[ -x "$IGMP" ] || exit 0

uci show network 2>/dev/null | awk -F'[.=]' '/\.mcast_vlan=/ {print $2}' | sort -u | while read -r sec; do
	[ -n "$sec" ] || continue
	v=$(uci -q get "network.$sec.mcast_vlan") || continue
	IFS=','
	for m in $v; do
		[ -n "$m" ] || continue
		case "$m" in
			''|*[!0-9]*) continue ;;
		esac
		[ "$m" -ge 1 ] 2>/dev/null && [ "$m" -le 4094 ] 2>/dev/null || continue
		"$IGMP" mvlan del "$m" >/dev/null 2>&1
		"$IGMP" mvlan add "$m" >/dev/null 2>&1
	done
done

# 后台刷新“驱动实际登记”快照（供 LuCI 只读展示）
/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1 &

exit 0
