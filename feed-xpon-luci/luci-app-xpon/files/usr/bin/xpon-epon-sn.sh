#!/bin/sh
# Read or override the 6-byte ONU ID carried inside CTC OAM ONUSN.
# This ECONET epon_oam build keeps it in a private, non-PIE BSS object and
# exposes no oamcfgCmd setter. Refuse unknown binaries before touching memory.

BIN=/userfs/bin/epon_oam
EXPECTED_SHA256=7d0d3ef68528a35a93bc4487eda57f88c4221ebb36a7ee8385a3c8ffc2a75415
ONUSN_ADDR=4520363

fail() {
	echo "$*" >&2
	exit 1
}

normalize_mac() {
	printf '%s' "$1" | tr 'a-f' 'A-F' | tr -d ':-'
}

format_mac() {
	printf '%s' "$1" | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)$/\1:\2:\3:\4:\5:\6/'
}

check_binary() {
	[ -r "$BIN" ] || fail "epon_oam 不可读：$BIN"
	command -v sha256sum >/dev/null 2>&1 || fail "缺少 sha256sum，无法安全识别 epon_oam"
	have=$(sha256sum "$BIN" | awk '{print $1}')
	[ "$have" = "$EXPECTED_SHA256" ] || fail "不支持的 epon_oam：sha256=$have"
}

find_pid() {
	pid=$(pidof epon_oam 2>/dev/null | awk '{print $1}')
	[ -n "$pid" ] || fail "epon_oam 未运行"
	[ -r "/proc/$pid/mem" ] || fail "无法访问 /proc/$pid/mem"
}

read_hex() {
	dd if="/proc/$pid/mem" bs=1 skip="$ONUSN_ADDR" count=6 2>/dev/null |
		hexdump -v -e '1/1 "%02X"'
}

write_hex() {
	hex=$1
	i=1
	while [ "$i" -le 11 ]; do
		byte=$(printf '%s' "$hex" | cut -c "$i-$((i + 1))")
		printf "\\$(printf '%03o' "$((0x$byte))")"
		i=$((i + 2))
	done
}

oam_value() {
	/userfs/bin/oamcfgCmd get "$1" 2>/dev/null |
		sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}

normalize_oui() {
	printf '%s' "$1" | sed 's/^0[xX]//' | tr 'a-f' 'A-F'
}

auth_get() {
	has_private_auth=$(uci -q get xpon.device.pon_mode)
	case "$1" in
		loid)
			v=$(uci -q get xpon.device.epon_loid)
			[ -n "$v" ] || [ -n "$has_private_auth" ] || v=$(uci -q get xpon.device.loid)
			[ -n "$v" ] || [ -n "$has_private_auth" ] || v=$(uci -q get network.xpon_auth.loid)
			;;
		loid_password)
			v=$(uci -q get xpon.device.epon_loid_password)
			[ "$v" = '""' ] && { printf ''; return; }
			[ -n "$v" ] || [ -n "$has_private_auth" ] || v=$(uci -q get xpon.device.loid_password)
			[ -n "$v" ] || [ -n "$has_private_auth" ] || v=$(uci -q get network.xpon_auth.loid_password)
			;;
		epon_oui)
			mac=$(uci -q get xpon.device.epon_pon_mac)
			[ -n "$mac" ] || mac=$(uci -q get network.xpon_auth.epon_pon_mac)
			[ -n "$mac" ] || mac=$(sed -n 's/^wan_mac=//p' /tmp/dsd.env 2>/dev/null | tr -d "'\"" | head -1)
			case "$mac" in
				[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
					v=$(printf '%s' "$mac" | tr -d ':' | cut -c 1-6 | tr 'a-f' 'A-F')
					;;
				*)
					v=$(uci -q get xpon.device.epon_oui)
					[ -n "$v" ] || v=$(uci -q get network.xpon_auth.epon_oui)
					;;
			 esac
			;;
		epon_ctc_oui|epon_serial|epon_ven_info|epon_onu_vendor_id)
			v=$(uci -q get "xpon.device.$1")
			[ -n "$v" ] || v=$(uci -q get "network.xpon_auth.$1")
			;;
		*)
			v=$(uci -q get "network.xpon_auth.$1")
			[ -n "$v" ] || v=$(uci -q get "xpon.device.$1")
			;;
	esac
	printf '%s' "$v"
}

repair_runtime_drift() {
	repaired=
	failed=0
	needs_persist=0

	desired_local=$(auth_get epon_oui)
	if [ -n "$desired_local" ]; then
		have_local=$(oam_value localOui)
		if [ "$(normalize_oui "$have_local")" != "$(normalize_oui "$desired_local")" ]; then
			if /userfs/bin/oamcfgCmd set localOui "$desired_local" >/dev/null 2>&1 &&
			   [ "$(normalize_oui "$(oam_value localOui)")" = "$(normalize_oui "$desired_local")" ]; then
				repaired="$repaired localOui"
				needs_persist=1
			else
				failed=1
			fi
		fi
	fi

	desired_ctc=$(auth_get epon_ctc_oui)
	desired_ctc=${desired_ctc:-111111}
	have_ctc=$(oam_value ctcOui)
	if [ "$(normalize_oui "$have_ctc")" != "$(normalize_oui "$desired_ctc")" ]; then
		if /userfs/bin/oamcfgCmd set ctcOui "$desired_ctc" >/dev/null 2>&1 &&
		   [ "$(normalize_oui "$(oam_value ctcOui)")" = "$(normalize_oui "$desired_ctc")" ]; then
			repaired="$repaired ctcOui"
			needs_persist=1
		else
			failed=1
		fi
	fi

	desired_onu_vendor=$(auth_get epon_onu_vendor_id)
	if [ -n "$desired_onu_vendor" ]; then
		have_onu_vendor=$(oam_value onuVenID)
		if [ "$have_onu_vendor" != "$desired_onu_vendor" ]; then
			if /userfs/bin/oamcfgCmd set onuVenID "$desired_onu_vendor" >/dev/null 2>&1 &&
			   [ "$(oam_value onuVenID)" = "$desired_onu_vendor" ]; then
				repaired="$repaired onuVenID"
				needs_persist=1
			else
				failed=1
			fi
		fi
	fi

	desired_ven=$(auth_get epon_ven_info)
	if [ -n "$desired_ven" ]; then
		have_ven=$(oam_value localVenInfo)
		if [ "$(normalize_oui "$have_ven")" != "$(normalize_oui "$desired_ven")" ]; then
			if /userfs/bin/oamcfgCmd set localVenInfo "$desired_ven" >/dev/null 2>&1 &&
			   [ "$(normalize_oui "$(oam_value localVenInfo)")" = "$(normalize_oui "$desired_ven")" ]; then
				repaired="$repaired localVenInfo"
				needs_persist=1
			else
				failed=1
			fi
		fi
	fi

	desired_loid=$(auth_get loid)
	if [ -n "$desired_loid" ]; then
		desired_password=$(auth_get loid_password)
		[ "$desired_password" = '""' ] && desired_password=
		password_valid=1
		if [ "${#desired_password}" -gt 12 ]; then
			logger -t xpon "EPON OAM 漂移修复跳过：LOID 密码为 ${#desired_password} 字节，超过 loidPasswd0 的 12 字节限制"
			failed=1
			password_valid=0
		fi
		have_password=$(oam_value loidPasswd0)
		if [ "$password_valid" -eq 1 ] && [ "$have_password" != "$desired_password" ]; then
			logger -t xpon "EPON OAM 漂移：loidPasswd0 want='$desired_password' have='$have_password'"
			if /userfs/bin/oamcfgCmd set loidPasswd0 "$desired_password" >/dev/null 2>&1 &&
			   [ "$(oam_value loidPasswd0)" = "$desired_password" ]; then
				repaired="$repaired loidPasswd0='$desired_password'"
				needs_persist=1
			else
				failed=1
			fi
		fi
	fi

	if [ "$failed" -eq 0 ] && [ "$needs_persist" -eq 1 ]; then
		# This IPC is only a best-effort vendor runtime notification. A missing
		# stock TCAPI service must not turn a successful OAM repair into a
		# failure; UCI is the durable source and boot replay is authoritative.
		if /usr/bin/xpon-epon-oam-save.sh >/dev/null 2>&1; then
			repaired="$repaired OAM_CONFIG_SYNC"
		else
			repaired="$repaired OAM_CONFIG_SYNC_UNAVAILABLE"
		fi
	fi

	desired_serial=$(auth_get epon_serial)
	if [ -n "$desired_serial" ]; then
		desired_hex=$(normalize_mac "$desired_serial")
		case "$desired_hex" in
			????????????) case "$desired_hex" in *[!0-9A-F]*) desired_hex= ;; esac ;;
			*) desired_hex= ;;
		esac
		if [ -n "$desired_hex" ]; then
			have_serial=$("$0" get 2>/dev/null)
			if [ "$(normalize_mac "$have_serial")" != "$desired_hex" ]; then
				if "$0" set "$desired_serial" >/dev/null 2>&1; then
					repaired="$repaired ONUSN"
				else
					failed=1
				fi
			fi
		fi
	fi

	if [ "$failed" -ne 0 ]; then
		drift_failures=$((drift_failures + 1))
		if [ "$drift_failures" -eq 1 ] || [ $((drift_failures % 20)) -eq 0 ]; then
			logger -t xpon "EPON OAM 运行态漂移修复失败，详见当前 ctcOui/onuVenID/loidPasswd0/ONUSN 回读"
		fi
		return 1
	fi
	drift_failures=0
	[ -z "$repaired" ] || logger -t xpon "已轻量修复 EPON OAM 运行态漂移：${repaired# }"
	return 0
}

settle_runtime_identity() {
	settle_try=0
	while [ "$settle_try" -lt 12 ]; do
		# epon_oam can restore its built-in MTKc/default fields shortly after
		# the IPC endpoint becomes readable. Keep checking during that window.
		sleep 1
		if repair_runtime_drift >/dev/null 2>&1; then
			return 0
		fi
		settle_try=$((settle_try + 1))
	done
	return 1
}

watch_identity() {
	interval=${1:-5}
	case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
	[ "$interval" -ge 1 ] 2>/dev/null || interval=1
	pidfile=/var/run/xpon-epon-sn-watch.pid
	oldpid=$(cat "$pidfile" 2>/dev/null)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		fail "EPON OAM 身份守护已运行：pid=$oldpid"
	fi
	echo $$ > "$pidfile" || fail "无法创建守护 pidfile：$pidfile"
	cleanup_watch() {
		[ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"
	}
	trap 'cleanup_watch' 0
	trap 'cleanup_watch; exit 0' 1 2 15

	last_pid=
	check_elapsed=30
	replay_failures=0
	drift_failures=0
	while :; do
		sleep "$interval"
		mode=$(cat /proc/tc3162/sys_xpon_mode 2>/dev/null)
		case "$mode" in 2|3|4|5|12) ;; *) last_pid=; continue ;; esac
		pid=$(pidof epon_oam 2>/dev/null | awk '{print $1}')
		[ -n "$pid" ] || { last_pid=; continue; }

		if [ "$pid" != "$last_pid" ]; then
			# Wait until the new process has attached its shared state before replay.
			/userfs/bin/oamcfgCmd get mode >/dev/null 2>&1 || continue
			if /usr/bin/xpon-auth-native.sh >/dev/null 2>&1; then
				if settle_runtime_identity; then
					logger -t xpon "EPON OAM pid=$pid 启动后已稳定重放完整身份（含 onuVenID/CTC ONUSN）"
					last_pid=$pid
					check_elapsed=0
					replay_failures=0
				else
					replay_failures=$((replay_failures + 1))
					logger -t xpon "EPON OAM pid=$pid 身份重放后仍发生漂移，继续重试，详见 /tmp/xpon-auth-native.log"
				fi
			else
				replay_failures=$((replay_failures + 1))
				if [ "$replay_failures" -eq 1 ] || [ $((replay_failures % 12)) -eq 0 ]; then
					logger -t xpon "EPON OAM pid=$pid 身份自动重放失败，详见 /tmp/xpon-auth-native.log"
				fi
			fi
			continue
		fi

		# netifd/vendor control paths can overwrite shared OAM fields without
		# replacing the process. Read infrequently and repair only changed fields.
		check_elapsed=$((check_elapsed + interval))
		[ "$check_elapsed" -ge 5 ] || continue
		check_elapsed=0
		repair_runtime_drift
	done
}

case "${1:-get}" in
	get)
		check_binary
		find_pid
		hex=$(read_hex)
		[ "${#hex}" -eq 12 ] || fail "读取 CTC ONUSN ONU ID 失败"
		format_mac "$hex"
		;;
	set)
		hex=$(normalize_mac "$2")
		case "$hex" in
			????????????) case "$hex" in *[!0-9A-F]*) fail "EPON 序列号格式错误" ;; esac ;;
			*) fail "EPON 序列号必须为 6 字节 MAC 格式" ;;
		esac
		check_binary
		find_pid
		resumed=0
		resume_oam() {
			[ "$resumed" = 1 ] || kill -CONT "$pid" 2>/dev/null
			resumed=1
		}
		trap 'resume_oam' 0
		trap 'resume_oam; exit 130' 1 2 15
		kill -STOP "$pid" 2>/dev/null || fail "无法暂停 epon_oam"
		write_hex "$hex" | dd of="/proc/$pid/mem" bs=1 seek="$ONUSN_ADDR" count=6 conv=notrunc 2>/dev/null || fail "写入 CTC ONUSN ONU ID 失败"
		kill -CONT "$pid" 2>/dev/null || fail "无法恢复 epon_oam"
		resumed=1
		have=$(read_hex)
		[ "$have" = "$hex" ] || fail "CTC ONUSN ONU ID 回读失败：want=$hex have=$have"
		format_mac "$have"
		;;
	watch)
		watch_identity "${2:-5}"
		;;
	*)
		fail "用法：$0 get | set XX:XX:XX:XX:XX:XX | watch [秒]"
		;;
esac
