#!/bin/sh
# Bind the Airoha FE default WAN to the selected vendor nasX_Y interface.

PROC_FE_DEFAULT=/proc/tc3162/fe_default_wan_itf
PROC_PON_BRIDGE=/proc/tc3162/pon_bridge_wanIf
LOG=/tmp/xg2010g-tlsfix.log
STATE=/tmp/xg2010g-tlsfix.state
STAMP=/tmp/xg2010g-tlsfix.stamp
DEBOUNCE=120

log_msg() {
	logger -t xg2010g-tlsfix "$*" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null
}

is_vendor_wan_device() {
	local device="$1" bank
	case "$device" in
		nas[1-9]*_[0-7])
			bank="${device#nas}"; bank="${bank%_*}"
			case "$bank" in *[!0-9]*) return 1 ;; esac
			[ -r "/sys/class/net/$device/ifindex" ]
			;;
		*) return 1 ;;
	esac
}

configured_default() {
	local iface
	iface="$(uci -q get xpon.ppe.default_wan_itf 2>/dev/null)"
	case "$iface" in nas[1-9]*_[0-7]) ;; *) return 1 ;; esac
	[ "$(uci -q get "network.$iface.xpon_managed" 2>/dev/null)" = 1 ] || return 1
	[ "$(uci -q get "network.$iface.proto" 2>/dev/null)" = pppoe ] || return 1
	printf '%s\n' "$iface"
}

ifstatus_device() {
	local iface="$1" data device
	data="$(ifstatus "$iface" 2>/dev/null)" || return 1
	device="$(printf '%s\n' "$data" | jsonfilter -e '@["device"]' 2>/dev/null)"
	[ -n "$device" ] || device="$(printf '%s\n' "$data" | sed -n 's/.*"device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	[ -n "$device" ] && printf '%s\n' "$device"
}

pppd_vendor_device() {
	local cmdline program device
	for cmdline in /proc/[0-9]*/cmdline; do
		[ -r "$cmdline" ] || continue
		program="$(tr '\000' '\n' < "$cmdline" 2>/dev/null | head -n1)"
		[ "${program##*/}" = pppd ] || continue
		device="$(tr '\000' '\n' < "$cmdline" 2>/dev/null | awk '
			previous == "ifname" && $0 ~ /^nas[1-9][0-9]*_[0-7]$/ { print; exit }
			{ previous=$0 }
		')"
		is_vendor_wan_device "$device" && { printf '%s\n' "$device"; return 0; }
	done
	return 1
}

find_wan_device() {
	local requested_iface="$1" requested_device="$2" preferred iface device key

	preferred="$(configured_default 2>/dev/null || true)"
	if [ -n "$preferred" ]; then
		is_vendor_wan_device "$preferred" && { printf '%s\n' "$preferred"; return 0; }
		return 1
	fi

	for device in "$requested_device" "$requested_iface"; do
		is_vendor_wan_device "$device" && { printf '%s\n' "$device"; return 0; }
	done

	for iface in "$requested_iface" wan; do
		[ -n "$iface" ] || continue
		for key in pppname device ifname; do
			device="$(uci -q get "network.$iface.$key" 2>/dev/null)"
			is_vendor_wan_device "$device" && { printf '%s\n' "$device"; return 0; }
		done
		device="$(ifstatus_device "$iface" 2>/dev/null || true)"
		is_vendor_wan_device "$device" && { printf '%s\n' "$device"; return 0; }
	done

	device="$(pppd_vendor_device 2>/dev/null || true)"
	is_vendor_wan_device "$device" && { printf '%s\n' "$device"; return 0; }

	for device in /sys/class/net/nas[1-9]*_[0-7]; do
		[ -r "$device/ifindex" ] || continue
		device="$(basename "$device")"
		is_vendor_wan_device "$device" && { printf '%s\n' "$device"; return 0; }
	done
	return 1
}

apply_fix() {
	local iface="$1" requested_device="$2" device ifindex old state new_state now last
	device="$(find_wan_device "$iface" "$requested_device")" || {
		log_msg "no live configured nasX_Y WAN device found for iface=${iface:-unknown}"
		return 1
	}
	ifindex="$(cat "/sys/class/net/$device/ifindex" 2>/dev/null)"
	case "$ifindex" in ''|*[!0-9]*) log_msg "invalid ifindex '$ifindex' for $device"; return 1 ;; esac

	new_state="$device $ifindex"
	state="$(cat "$STATE" 2>/dev/null || true)"
	if [ "$state" = "$new_state" ] && [ -s "$STAMP" ]; then
		now="$(date +%s 2>/dev/null || echo 0)"
		last="$(cat "$STAMP" 2>/dev/null || echo 0)"
		case "$now:$last" in
			*[!0-9:]*|0:*) ;;
			*) [ $((now - last)) -lt "$DEBOUNCE" ] && return 0 ;;
		esac
	fi

	if [ -e "$PROC_FE_DEFAULT" ]; then
		old="$(cat "$PROC_FE_DEFAULT" 2>/dev/null || true)"
		printf '%s\n' "$device" > "$PROC_FE_DEFAULT" 2>/dev/null && {
			log_msg "set fe_default_wan_itf=$device ifindex=$ifindex old=${old:-unknown}"
		} || {
			log_msg "failed to set fe_default_wan_itf=$device ifindex=$ifindex"
			return 1
		}
	else
		log_msg "$PROC_FE_DEFAULT missing; cannot bind PPE default WAN"
		return 1
	fi
	[ -e "$PROC_PON_BRIDGE" ] && printf '%s\n' "bridge pon" > "$PROC_PON_BRIDGE" 2>/dev/null
	printf '%s\n' "$new_state" > "$STATE" 2>/dev/null
	date +%s > "$STAMP" 2>/dev/null
	return 0
}

status_fix() {
	local device ifindex current
	device="$(find_wan_device "$1" "" 2>/dev/null || true)"
	[ -n "$device" ] && ifindex="$(cat "/sys/class/net/$device/ifindex" 2>/dev/null)"
	[ -e "$PROC_FE_DEFAULT" ] && current="$(cat "$PROC_FE_DEFAULT" 2>/dev/null || true)"
	printf 'device=%s\nifindex=%s\nfe_default_wan_itf=%s\n' "${device:-}" "${ifindex:-}" "${current:-missing}"
}

case "${1:-apply}" in
	apply) shift; apply_fix "$@" ;;
	status) shift; status_fix "$@" ;;
	*) echo "Usage: $0 [apply [interface [device]]|status [interface]]" >&2; exit 2 ;;
esac
