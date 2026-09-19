#!/bin/sh
# 严格调用设备原生命令；任一步失败立即退出，禁止静默失败。
OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
PONMGR=/userfs/bin/ponmgr
LOG=/tmp/xpon-auth-native.log
: > "$LOG"

run() {
	echo "+ $*" >> "$LOG"
	"$@" >> "$LOG" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || { echo "失败：exit_code=$rc" >> "$LOG"; exit "$rc"; }
}
run_secret() {
	label=$1
	shift
	echo "+ $*" >> "$LOG"
	"$@" >> "$LOG" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || { echo "失败：$label exit_code=$rc" >> "$LOG"; exit "$rc"; }
}
device_get() { uci -q get "xpon.device.$1"; }
get() {
	# restore-auth 已把持久配置镜像到 network；旧安装则可能只有 network。
	v=$(uci -q get "network.xpon_auth.$1")
	[ -n "$v" ] || v=$(device_get "$1")
	printf '%s' "$v"
}
identity_get() { get "$1"; }
device_first_get() {
	v=$(device_get "$1")
	[ -n "$v" ] || v=$(uci -q get "network.xpon_auth.$1")
	printf '%s' "$v"
}
credential_prefix() {
	[ "$mode" = EPON ] && printf '%s' epon || printf '%s' gpon
}
credential_get() {
	has_private_auth=$(device_get pon_mode)
	prefix=$(credential_prefix)
	field=$1
	v=$(device_get "${prefix}_${field}")
	if [ "$field" = loid_password ] && [ "$v" = '""' ]; then
		printf ''
		return 0
	fi
	if [ -n "$v" ]; then
		printf '%s' "$v"
		return 0
	fi
	if [ -n "$has_private_auth" ]; then
		printf ''
		return 0
	fi
	case "$field" in
		sn)
			if [ "$mode" = EPON ]; then
				v=
			else
				v=$(device_get sn)
				[ -n "$v" ] || v=$(device_get def_sn)
				[ -n "$v" ] || v=$(uci -q get network.xpon_auth.sn)
				[ -n "$v" ] || v=$(uci -q get network.xpon_auth.def_sn)
			fi
			;;
		loid)
			v=$(device_get loid)
			[ -n "$v" ] || v=$(uci -q get network.xpon_auth.loid)
			;;
		loid_password)
			v=$(device_get loid_password)
			[ -n "$v" ] || v=$(uci -q get network.xpon_auth.loid_password)
			[ "$v" = '""' ] && v=
			;;
	esac
	printf '%s' "$v"
}
omci_read() {
	$OMCI get "$1" 2>>"$LOG" | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}
oam_read() {
	$OAM get "$1" 2>>"$LOG" | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}
normalize_oam_hex() {
	printf '%s' "$1" | sed 's/^0[xX]//' | tr 'a-f' 'A-F'
}
require_oam_hex() {
	label=$1
	value=$2
	length=$3
	[ -z "$value" ] && return 0
	if [ "${#value}" -ne "$length" ]; then
		echo "EPON OAM 参数非法：$label='$value'，必须为 $length 位十六进制" >> "$LOG"
		exit 64
	fi
	case "$value" in
		*[!0-9A-F]*)
			echo "EPON OAM 参数非法：$label='$value'，只允许十六进制字符 0-9/A-F" >> "$LOG"
			exit 64
			;;
	esac
}
require_oam_ascii4() {
	label=$1
	value=$2
	[ -z "$value" ] && return 0
	if [ "${#value}" -ne 4 ] || ! printf '%s' "$value" | LC_ALL=C grep -q '^[ -~][ -~][ -~][ -~]$'; then
		echo "EPON OAM 参数非法：$label='$value'，必须为 4 字节可打印 ASCII" >> "$LOG"
		exit 64
	fi
}
verify() {
	attr=$1
	want=$2
	[ -n "$want" ] || return 0
	have=$(omci_read "$attr")
	cmp_have=$have
	cmp_want=$want
	case "$attr" in
		vendorId|sn|omccVersion) cmp_have=$(printf '%s' "$have" | tr 'a-f' 'A-F'); cmp_want=$(printf '%s' "$want" | tr 'a-f' 'A-F') ;;
	esac
	if [ "$cmp_have" != "$cmp_want" ]; then
		echo "回读校验失败：$attr want='$want' have='$have'" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：$attr='$have'" >> "$LOG"
}

verify_secret() {
	attr=$1
	want=$2
	have=$(omci_read "$attr")
	if [ "$have" != "$want" ]; then
		echo "回读校验失败：$attr want='$want' have='$have'" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：$attr='$have'" >> "$LOG"
}

verify_mac() {
	want=$(printf '%s' "$1" | tr 'a-f' 'A-F')
	[ -n "$want" ] || return 0
	have=$(cat /sys/class/net/pon/address 2>/dev/null | tr 'a-f' 'A-F')
	[ -n "$have" ] || have=$(ifconfig pon 2>/dev/null | sed -n 's/.*HWaddr[[:space:]]*\([0-9A-Fa-f:]*\).*/\1/p; s/.*ether[[:space:]]*\([0-9A-Fa-f:]*\).*/\1/p' | head -1 | tr 'a-f' 'A-F')
	if [ "$have" != "$want" ]; then
		echo "回读校验失败：pon_mac want='$want' have='$have'" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：pon_mac='$have'" >> "$LOG"
}

verify_oam() {
	attr=$1
	want=$2
	secret=$3
	[ -n "$want" ] || [ "$secret" = 1 ] || return 0
	have=$(oam_read "$attr")
	cmp_have=$have
	cmp_want=$want
	case "$attr" in
		localOui|localVenInfo|ctcOui)
			cmp_have=$(printf '%s' "$have" | sed 's/^0[xX]//' | tr 'a-f' 'A-F')
			cmp_want=$(printf '%s' "$want" | sed 's/^0[xX]//' | tr 'a-f' 'A-F')
			;;
	esac
	if [ "$cmp_have" != "$cmp_want" ]; then
		echo "回读校验失败：$attr want='$want' have='$have'" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：$attr='$have'" >> "$LOG"
}

auth=$(get auth_type_g)
auth_method=$(get auth_method_g)
auth_method=$(printf '%s' "$auth_method" | tr 'A-Z' 'a-z')
[ "$auth_method" = "password" ] && auth=SN
case "$auth" in password|PASSWORD|sn|SN) auth=SN ;; esac

# 启动重放只读取本次实际启动的 onu_type，绝不根据 UCI 改写 env。
# /proc/cmdline 是当前内核模式；仅在取不到时才读取 U-Boot env。
onu_type=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^onu_type=/) { print substr($i, 10); exit } }' /proc/cmdline 2>/dev/null)
case "$onu_type" in
	[0-9A-Fa-f][0-9A-Fa-f]) : ;;
	*) onu_type=$(/usr/sbin/fw_printenv -n onu_type 2>/dev/null) ;;
esac
case "$onu_type" in [0-9A-Fa-f][0-9A-Fa-f]) : ;; *) onu_type= ;; esac
onu_high=${onu_type%?}
case "$onu_high" in
	2|3|4|5|c|C) mode=EPON ;;
	1|6|7) mode=GPON ;;
	*)
		mode=$(uci -q get network.xpon_auth.pon_mode)
		[ "$mode" = "EPON" ] || mode=GPON
		echo "警告：无法从当前启动参数识别 onu_type='$onu_type'，仅沿用运行时引擎 $mode；未写 env" >> "$LOG"
		;;
esac
loid=$(credential_get loid); loidpw=$(credential_get loid_password); sn=$(credential_get sn)
[ "$loidpw" = '""' ] && loidpw=
equipment=$(identity_get equipment_id); onuver=$(identity_get onu_version); omcc=$(identity_get omcc_version)
spec=$(get omci_spec_ver)
if [ "$mode" = "EPON" ]; then
	pmac=$(device_first_get epon_pon_mac)
else
	pmac=$(get gpon_pon_mac)
fi
[ -n "$pmac" ] || pmac=$(get pon_mac)
[ -n "$pmac" ] || pmac=$(sed -n 's/^wan_mac=//p' /tmp/dsd.env 2>/dev/null | tr -d "'\"" | head -1)
regid=$(get sn_regid_password)
sn_type=$(get xpon_sn_auth_type); asciipw=$(get sn_ascii_password); hexpw=$(get sn_hex_password)
[ "$auth_method" = "password" ] && sn_type=regid
epon_oui=$(device_first_get epon_oui)
epon_ctc_oui=$(device_first_get epon_ctc_oui)
epon_ven=$(device_first_get epon_ven_info)
epon_onu_vendor=$(device_first_get epon_onu_vendor_id)
epon_serial=$(device_first_get epon_serial)
[ -n "$epon_ctc_oui" ] || epon_ctc_oui=111111

# localOui is the OAM form of the MPCP registration MAC OUI.  Re-derive it
# here as well as in LuCI so an old UCI value cannot drift from EPON devMac.
if [ "$mode" = "EPON" ]; then
	case "$pmac" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
			epon_oui=$(printf '%s' "$pmac" | tr -d ':' | cut -c 1-6 | tr 'a-f' 'A-F')
			;;
	esac
	epon_oui=$(normalize_oam_hex "$epon_oui")
	epon_ctc_oui=$(normalize_oam_hex "$epon_ctc_oui")
	epon_ven=$(normalize_oam_hex "$epon_ven")
	require_oam_hex localOui "$epon_oui" 6
	require_oam_hex ctcOui "$epon_ctc_oui" 6
	require_oam_hex localVenInfo "$epon_ven" 8
	require_oam_ascii4 onuVenID "$epon_onu_vendor"
fi

# PON SN 是唯一输入源；SDK 仍要求分别设置 ME 256 SN 与 ME 7 Vendor ID。
sn=$(printf '%s' "$sn" | tr -d '[:space:]' | tr 'a-z' 'A-Z')
valid_sn=
if [ "${#sn}" -eq 12 ]; then
	vendor_part=${sn%????????}
	serial_part=${sn#????}
	case "$vendor_part" in *[!A-Z0-9]*|'') : ;; *)
		case "$serial_part" in *[!0-9A-F]*|'') : ;; *) valid_sn=$sn ;; esac
		;;
	esac
fi
vendor=
[ -n "$valid_sn" ] && vendor=${valid_sn%????????}
if [ "$mode" != "EPON" ] && [ -z "$valid_sn" ]; then
	echo "PON SN 非法：读取值='$sn' 长度=${#sn}；必须为 4 位厂商代码 + 8 位十六进制序列号" >> "$LOG"
	exit 64
fi
if [ "$mode" = "EPON" ] && [ "${#loidpw}" -gt 12 ]; then
	echo "EPON LOID 密码过长：${#loidpw} 字节；oamcfgCmd loidPasswd0 最多接受 12 字节" >> "$LOG"
	exit 64
fi

# 一般留空字段跳过；LOID 密码例外，空字符串表示明确使用 LOID-only。
# ONU 形态/PON 技术只允许由显式的 `xpon-apply.sh ponmode` 写入 env。
if [ "$mode" = "EPON" ]; then
	[ -x "$OAM" ] || { echo "oamcfgCmd 不存在或不可执行" >> "$LOG"; exit 127; }
	run "$OAM" set mode 2
	[ -n "$loid" ] && run "$OAM" set loid0 "$loid"
	[ -n "$loid" ] && run_secret "oamcfgCmd set loidPasswd0" "$OAM" set loidPasswd0 "$loidpw"
	[ -n "$epon_oui" ] && run "$OAM" set localOui "$epon_oui"
	[ -n "$epon_ctc_oui" ] && run "$OAM" set ctcOui "$epon_ctc_oui"
	[ -n "$epon_ven" ] && run "$OAM" set localVenInfo "$epon_ven"
	[ -n "$epon_onu_vendor" ] && run "$OAM" set onuVenID "$epon_onu_vendor"
	[ -n "$epon_serial" ] && run /usr/bin/xpon-epon-sn.sh set "$epon_serial"
	verify_oam loid0 "$loid" 0
	[ -n "$loid" ] && verify_oam loidPasswd0 "$loidpw" 1
	verify_oam localOui "$epon_oui" 0
	verify_oam ctcOui "$epon_ctc_oui" 0
	verify_oam localVenInfo "$epon_ven" 0
	verify_oam onuVenID "$epon_onu_vendor" 0
	# The stock process otherwise keeps several OAM identity values only in
	# RAM.  cmdType=24 is the vendor's TCAPI_SAVE/update-config notification;
	# it is best-effort here because this OpenWrt image has no stock TCAPI
	# persistence service. UCI plus boot-time replay is the durable path.
	if /usr/bin/xpon-epon-oam-save.sh >>"$LOG" 2>&1; then
		echo "EPON OAM 原厂配置同步通知已发送；持久源仍为 UCI" >>"$LOG"
	else
		echo "警告：EPON OAM 原厂配置同步通知不可用；继续使用 UCI 持久配置和启动重放" >>"$LOG"
	fi
else
	[ -x "$OMCI" ] || { echo "omcicfgCmd 不存在或不可执行" >> "$LOG"; exit 127; }
	echo "GPON identity: auth=$auth auth_method=${auth_method:-none} sn=$valid_sn vendor_id=$vendor onu_version=${onuver:-skip}" >> "$LOG"
	[ -n "$valid_sn" ] && run "$OMCI" set sn "$valid_sn"
	# 部分固件路径在接受 SN 时会刷新 Vendor ID；最后写 vendorId，
	# 确保 omcicfgCmd get vendorId 等于配置 SN 的前四位。
	[ -n "$vendor" ] && run "$OMCI" set vendorId "$vendor"
	case "$auth" in
		LOID|loid)
			[ -n "$loid" ] && run "$OMCI" set loid "$loid"
			run_secret "omcicfgCmd set loidPasswd" "$OMCI" set loidPasswd "$loidpw"
			;;
	esac
	[ -n "$equipment" ] && run "$OMCI" set equipmentId "$equipment"
	[ -n "$onuver" ] && run "$OMCI" set onuVersion "$onuver"
	[ -n "$omcc" ] && run "$OMCI" set omccVersion "$omcc"
	[ -n "$spec" ] && run "$OMCI" set specVer "$spec"

	# 命令返回 0 不足以证明共享配置已更新；重启前必须核对当前生效值。
	verify sn "$valid_sn"
	verify vendorId "$vendor"
	case "$auth" in
		LOID|loid) verify loid "$loid"; verify_secret loidPasswd "$loidpw" ;;
	esac
	verify equipmentId "$equipment"
	verify onuVersion "$onuver"
	verify omccVersion "$omcc"
	verify specVer "$spec"

	case "$auth" in
		SN|sn)
			case "$sn_type" in
				hex) [ -n "$hexpw" ] && run_secret "ponmgr gpon set passwd hex" "$PONMGR" gpon set passwd hex "$hexpw" ;;
				regid) [ -n "$regid" ] && run_secret "ponmgr gpon set passwd regid" "$PONMGR" gpon set passwd regid "$regid" ;;
				*) [ -n "$asciipw" ] && run_secret "ponmgr gpon set passwd ascii" "$PONMGR" gpon set passwd ascii "$asciipw" ;;
			esac
			;;
	esac
fi

[ -n "$pmac" ] && run ifconfig pon hw ether "$pmac"
verify_mac "$pmac"

echo "全部设备参数写入成功" >> "$LOG"
exit 0
