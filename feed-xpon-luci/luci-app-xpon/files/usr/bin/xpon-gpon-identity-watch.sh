#!/bin/sh
# Keep GPON runtime-only OMCI identity fields aligned after omci restarts.

OMCI=/userfs/bin/omcicfgCmd
PIDFILE=/var/run/xpon-gpon-identity-watch.pid

fail() {
	echo "$*" >&2
	exit 1
}

current_pon_mode() {
	local sys_mode onu_type onu_high
	sys_mode=$(cat /proc/tc3162/sys_xpon_mode 2>/dev/null)
	case "$sys_mode" in
		1|6|7) printf '%s' GPON; return 0 ;;
		2|3|4|5|12) printf '%s' EPON; return 0 ;;
	esac
	onu_type=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^onu_type=/) { print substr($i, 10); exit } }' /proc/cmdline 2>/dev/null)
	case "$onu_type" in
		[0-9A-Fa-f][0-9A-Fa-f]) : ;;
		*) onu_type=$(fw_printenv -n onu_type 2>/dev/null) ;;
	esac
	case "$onu_type" in [0-9A-Fa-f][0-9A-Fa-f]) : ;; *) return 1 ;; esac
	onu_high=${onu_type%?}
	case "$onu_high" in
		1|6|7) printf '%s' GPON ;;
		2|3|4|5|c|C) printf '%s' EPON ;;
		*) return 1 ;;
	esac
}

gpon_sn() {
	local has_private v
	has_private=$(uci -q get xpon.device.pon_mode)
	v=$(uci -q get xpon.device.gpon_sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get xpon.device.sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get xpon.device.def_sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get network.xpon_auth.sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get network.xpon_auth.def_sn)
	printf '%s' "$v" | tr -d '[:space:]' | tr 'a-z' 'A-Z'
}

gpon_credential_get() {
	local field has_private v
	field=$1
	has_private=$(uci -q get xpon.device.pon_mode)
	v=$(uci -q get "xpon.device.gpon_${field}")
	if [ "$field" = loid_password ] && [ "$v" = '""' ]; then
		printf ''
		return 0
	fi
	if [ -n "$v" ]; then
		printf '%s' "$v"
		return 0
	fi
	if [ -n "$has_private" ]; then
		printf ''
		return 0
	fi
	v=$(uci -q get "xpon.device.${field}")
	[ -n "$v" ] || v=$(uci -q get "network.xpon_auth.${field}")
	[ "$field" = loid_password ] && [ "$v" = '""' ] && v=
	printf '%s' "$v"
}

gpon_uses_loid() {
	local method auth
	method=$(uci -q get network.xpon_auth.auth_method_g)
	[ -n "$method" ] || method=$(uci -q get xpon.device.auth_method_g)
	auth=$(uci -q get network.xpon_auth.auth_type_g)
	[ -n "$auth" ] || auth=$(uci -q get xpon.device.auth_type_g)
	method=$(printf '%s' "$method" | tr 'A-Z' 'a-z')
	auth=$(printf '%s' "$auth" | tr 'A-Z' 'a-z')
	[ "$method" = "password" ] && return 1
	[ "$method" = "loid" ] && return 0
	[ "$auth" = "loid" ] && return 0
	return 1
}

valid_pon_sn() {
	[ "${#1}" -eq 12 ] || return 1
	vendor=${1%????????}
	serial=${1#????}
	case "$vendor" in *[!A-Z0-9]*|'') return 1 ;; esac
	case "$serial" in *[!0-9A-F]*|'') return 1 ;; esac
	return 0
}

omci_value() {
	"$OMCI" get "$1" 2>/dev/null |
		sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}

repair_runtime_drift() {
	local sn vendor have_sn have_vendor want_loid want_loidpw have_loid have_loidpw
	local want_onuver want_omcc have_onuver have_omcc need_sn need_loid need_identity repaired
	need_sn=0
	need_loid=0
	need_identity=0
	sn=$(gpon_sn)
	if valid_pon_sn "$sn"; then
		vendor=${sn%????????}
		have_sn=$(omci_value sn | tr -d '[:space:]' | tr 'a-z' 'A-Z')
		have_vendor=$(omci_value vendorId | tr -d '[:space:]' | tr 'a-z' 'A-Z')
		[ "$have_sn" = "$sn" ] && [ "$have_vendor" = "$vendor" ] || need_sn=1
	fi
	if gpon_uses_loid; then
		want_loid=$(gpon_credential_get loid)
		want_loidpw=$(gpon_credential_get loid_password)
		[ "$want_loidpw" = '""' ] && want_loidpw=
		if [ -n "$want_loid" ]; then
			have_loid=$(omci_value loid)
			have_loidpw=$(omci_value loidPasswd)
			[ "$have_loid" = "$want_loid" ] && [ "$have_loidpw" = "$want_loidpw" ] || need_loid=1
		fi
	fi
	# These OMCI identity attributes live in shared memory and are lost when
	# omci/ponmgr is restarted. Keep them aligned with the durable xpon.device
	# values instead of only repairing SN/Vendor ID.
	want_onuver=$(uci -q get xpon.device.onu_version)
	want_omcc=$(uci -q get xpon.device.omcc_version)
	if [ -n "$want_onuver" ] || [ -n "$want_omcc" ]; then
		have_onuver=$(omci_value onuVersion)
		have_omcc=$(omci_value omccVersion)
		[ -z "$want_onuver" ] || [ "$have_onuver" = "$want_onuver" ] || need_identity=1
		[ -z "$want_omcc" ] || [ "$(printf '%s' "$have_omcc" | tr 'a-f' 'A-F')" = "$(printf '%s' "$want_omcc" | tr 'a-f' 'A-F')" ] || need_identity=1
	fi
	if [ "$need_sn" -eq 0 ] && [ "$need_loid" -eq 0 ] && [ "$need_identity" -eq 0 ]; then
		return 0
	fi
	if [ "$need_identity" -eq 1 ]; then
		[ -z "$want_onuver" ] || "$OMCI" set onuVersion "$want_onuver" >/dev/null 2>&1
		[ -z "$want_omcc" ] || "$OMCI" set omccVersion "$want_omcc" >/dev/null 2>&1
		repaired="$repaired onuVersion/omccVersion"
	fi
	if [ "$need_sn" -eq 1 ]; then
		"$OMCI" set sn "$sn" >/dev/null 2>&1
		"$OMCI" set vendorId "$vendor" >/dev/null 2>&1
		repaired="$repaired sn/vendorId"
	fi
	if [ "$need_loid" -eq 1 ]; then
		"$OMCI" set loid "$want_loid" >/dev/null 2>&1
		"$OMCI" set loidPasswd "$want_loidpw" >/dev/null 2>&1
		repaired="$repaired loid/loidPasswd"
	fi
	if [ "$need_identity" -eq 1 ]; then
		[ -z "$want_onuver" ] || [ "$(omci_value onuVersion)" = "$want_onuver" ] || {
			logger -t xpon "GPON OMCI ONU Version 漂移修复失败 want='$want_onuver' have='$(omci_value onuVersion)'"
			return 1
		}
		[ -z "$want_omcc" ] || [ "$(printf '%s' "$(omci_value omccVersion)" | tr 'a-f' 'A-F')" = "$(printf '%s' "$want_omcc" | tr 'a-f' 'A-F')" ] || {
			logger -t xpon "GPON OMCI OMCC Version 漂移修复失败 want='$want_omcc' have='$(omci_value omccVersion)'"
			return 1
		}
	fi
	if [ "$need_sn" -eq 1 ]; then
		[ "$(omci_value sn | tr -d '[:space:]' | tr 'a-z' 'A-Z')" = "$sn" ] || {
			logger -t xpon "GPON OMCI SN 漂移修复失败 want='$sn' have='$(omci_value sn)'"
			return 1
		}
		[ "$(omci_value vendorId | tr -d '[:space:]' | tr 'a-z' 'A-Z')" = "$vendor" ] || {
			logger -t xpon "GPON OMCI Vendor ID 漂移修复失败 want='$vendor' have='$(omci_value vendorId)'"
			return 1
		}
	fi
	if [ "$need_loid" -eq 1 ]; then
		[ "$(omci_value loid)" = "$want_loid" ] || {
			logger -t xpon "GPON OMCI LOID 漂移修复失败 want='$want_loid' have='$(omci_value loid)'"
			return 1
		}
		[ "$(omci_value loidPasswd)" = "$want_loidpw" ] || {
			logger -t xpon "GPON OMCI LOID 密码漂移修复失败 want='$want_loidpw' have='$(omci_value loidPasswd)'"
			return 1
		}
	fi
	logger -t xpon "GPON OMCI 身份漂移已自动修复：${repaired# }（此前 sn=${have_sn:-空} vendorId=${have_vendor:-空} loid=${have_loid:-空} loidPasswd=${have_loidpw:-空}）"
	return 0
}

watch_identity() {
	local interval oldpid last_pid pid check_elapsed replay_failures drift_failures mode
	interval=${1:-5}
	case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
	[ "$interval" -ge 2 ] 2>/dev/null || interval=2
	oldpid=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		fail "GPON OMCI 身份守护已运行：pid=$oldpid"
	fi
	echo $$ > "$PIDFILE" || fail "无法创建守护 pidfile：$PIDFILE"
	cleanup_watch() {
		[ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"
	}
	trap 'cleanup_watch' 0
	trap 'cleanup_watch; exit 0' 1 2 15

	last_pid=
	check_elapsed=30
	replay_failures=0
	drift_failures=0
	while :; do
		sleep "$interval"
		mode=$(current_pon_mode 2>/dev/null)
		[ "$mode" = GPON ] || { last_pid=; continue; }
		pid=$(pidof omci 2>/dev/null | awk '{print $1}')
		[ -n "$pid" ] || { last_pid=; continue; }

		if [ "$pid" != "$last_pid" ]; then
			"$OMCI" get sn >/dev/null 2>&1 || continue
			if /usr/bin/xpon-auth-native.sh >/dev/null 2>&1; then
				logger -t xpon "GPON OMCI pid=$pid 启动后已自动重放 SN/Vendor ID/设备信息"
				last_pid=$pid
				check_elapsed=0
				replay_failures=0
			else
				replay_failures=$((replay_failures + 1))
				if [ "$replay_failures" -eq 1 ] || [ $((replay_failures % 12)) -eq 0 ]; then
					logger -t xpon "GPON OMCI pid=$pid 身份自动重放失败，详见 /tmp/xpon-auth-native.log"
				fi
			fi
			continue
		fi

		check_elapsed=$((check_elapsed + interval))
		[ "$check_elapsed" -ge 30 ] || continue
		check_elapsed=0
		if repair_runtime_drift; then
			drift_failures=0
		else
			drift_failures=$((drift_failures + 1))
			if [ "$drift_failures" -eq 1 ] || [ $((drift_failures % 10)) -eq 0 ]; then
				logger -t xpon "GPON OMCI 身份漂移修复连续失败 $drift_failures 次"
			fi
		fi
	done
}

case "${1:-watch}" in
	watch) watch_identity "${2:-5}" ;;
	check) repair_runtime_drift ;;
	*) fail "用法：$0 watch [秒] | check" ;;
esac
