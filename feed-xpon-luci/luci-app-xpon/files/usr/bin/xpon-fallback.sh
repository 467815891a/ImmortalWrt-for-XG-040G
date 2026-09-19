#!/bin/sh
# xpon-fallback.sh [once]
#
# OLT 未通过 OMCI 自动下发 GEM/ponvlan 规则时兜底补表（含组播 M-VLAN 白名单登记）。
# 安全红线（防重复/防风暴）：
#   * 只加不删；同 gemPort/同 VID 已存在（含 OLT 下发）则跳过；
#   * 手工规则一律使用 gemPort >= xpon.fallback.gem_base（默认 10），
#     避开 OLT 自动分配的 gemPort；
#   * 默认关闭（xpon.fallback.enable='0'），需在 LuCI“VLAN 表”页显式开启。
# 无参数 = 守护模式（每 60s 检查一次）；once = 单次检查后退出。

CONF=/etc/config/xpon
[ -f "$CONF" ] || exit 0
[ "$(uci -q get xpon.fallback.enable)" = "1" ] || exit 0

GEM_BASE=$(uci -q get xpon.fallback.gem_base)
GEM_BASE=${GEM_BASE:-10}
[ "$GEM_BASE" -lt 10 ] 2>/dev/null && GEM_BASE=10

# showGemPortRule 结果由内核 printk 打到 dmesg（stdout 为空），
# 这里执行前记行数、执行后取增量（与 LuCI klog_show 同法）。
show_rules() {
	local before
	before=$(dmesg 2>/dev/null | wc -l)
	gponmapcmd showGemPortRule >/dev/null 2>&1
	dmesg 2>/dev/null | tail -n +$((before + 1)) | sed 's/^\[ *[0-9][0-9]*\.[0-9][0-9]*\] //'
}

# 表头：tagFlag uni vid dscp pbit gemPort
gem_used() { # $1=gemPort -> 0 已占用（避免同端口多条规则）
	show_rules | awk -v g="$1" '
		$1 ~ /^[0-9]+$/ && $NF == g { found=1 }
		END { exit (found ? 0 : 1) }'
}

# $1=vid -> 0 已被覆盖（精确 VID 或 vid=N/A 通配，含 OLT 下发——命中则跳过，防重复/风暴）
vid_covered() {
	show_rules | awk -v v="$1" '
		$1 ~ /^[0-9]+$/ && ($3 == v || $3 == "N/A") { found=1 }
		END { exit (found ? 0 : 1) }'
}

add_service_rules() {
	local svc gem vid pbit ifmask
	for svc in tr069 internet iptv voice; do
		[ "$(uci -q get xpon.$svc.enable)" = "1" ] || continue
		vid=$(uci -q get xpon.$svc.vlan)
		[ -n "$vid" ] || continue
		# OLT 已下发（精确 VID 或 vid=N/A 通配）则跳过
		vid_covered "$vid" && continue
		gem=$GEM_BASE
		while gem_used "$gem"; do gem=$((gem + 1)); done
		pbit=$(uci -q get xpon.$svc.pbit); pbit=${pbit:-0}
		ifmask=$(uci -q get xpon.$svc.ifmask); ifmask=${ifmask:-0x0f}
		# tagCtl=0xb(压 802.1p) tagFlag=1(打 VLAN 标签) userPort=3(VEIP)
		gponmapcmd addGemPortRule tagCtl 0xb tagFlag 1 userPort 3 vid "$vid" dscp 0 pbit "$pbit" gemPort "$gem" >/dev/null 2>&1
		gponmapcmd addDownRule "$gem" "$ifmask" 0 0 1 1 >/dev/null 2>&1
		GEM_BASE=$((gem + 1))
	done
}

# 组播 M-VLAN 白名单重放：xpon_ani_pass_mvlan(vid)（xpon_igmp_core.c）要求下行
# 组播帧的 VID 已登记，否则丢帧。OLT 经 OMCI 下发的无需处理；无下发时本地登记。
# 幂等：先删后加（与 xpon-iptv.sh 同法），只加不删，无风暴风险。
add_mvlan_rules() {
	local svc mvid
	for svc in tr069 internet iptv voice; do
		[ "$(uci -q get xpon.$svc.enable)" = "1" ] || continue
		mvid=$(uci -q get xpon.$svc.mcast_vlan)
		[ -n "$mvid" ] || continue
		case "$mvid" in
			''|*[!0-9]*) continue ;;
		esac
		[ "$mvid" -ge 1 ] 2>/dev/null && [ "$mvid" -le 4094 ] 2>/dev/null || continue
		/userfs/bin/xponigmpcmd mvlan del "$mvid" >/dev/null 2>&1
		/userfs/bin/xponigmpcmd mvlan add "$mvid" >/dev/null 2>&1
	done
}

case "${1:-daemon}" in
	once) add_service_rules; add_mvlan_rules ;;
	*)
		while :; do
			add_service_rules
			add_mvlan_rules
			sleep 60
		done
		;;
esac

exit 0
