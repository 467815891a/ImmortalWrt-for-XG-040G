#!/bin/sh
# xpon-apply.sh {restore-auth|auth|network|mac|leds|iptv|ponmode <hex>|all}
#
# 读 UCI -> omcicfgCmd/oamcfgCmd 下发 -> 重启 OMCI -> reload network
# 按设备原生认证流程执行：
#   GPON SN  : set sn + ponmgr gpon set passwd ascii|hex <pwd>
#   GPON LOID: set sn <gpon_sn> + set loid + set loidPasswd
#   /tmp/load_process 存在则只发 `omci set reconfig`，否则重启 omci/ponmgr_cfg

OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
PONMGR=/userfs/bin/ponmgr_cfg
PONMGRCLI=/userfs/bin/ponmgr
OMCID=/userfs/bin/omci
EPON_OAM=/userfs/bin/epon_oam

uci_get() { uci -q get "$1"; }

credential_prefix() {
	[ "$1" = EPON ] && printf '%s' epon || printf '%s' gpon
}

mode_credential_get() {
	local mode prefix field v has_private_auth
	mode=$1
	field=$2
	prefix=$(credential_prefix "$mode")
	has_private_auth=$(uci_get xpon.device.pon_mode)
	v=$(uci_get "xpon.device.${prefix}_${field}")
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
				v=$(uci_get xpon.device.sn)
				[ -n "$v" ] || v=$(uci_get xpon.device.def_sn)
				[ -n "$v" ] || v=$(uci_get network.xpon_auth.sn)
				[ -n "$v" ] || v=$(uci_get network.xpon_auth.def_sn)
			fi
			;;
		loid)
			v=$(uci_get xpon.device.loid)
			[ -n "$v" ] || v=$(uci_get network.xpon_auth.loid)
			;;
		loid_password)
			v=$(uci_get xpon.device.loid_password)
			[ -n "$v" ] || v=$(uci_get network.xpon_auth.loid_password)
			[ "$v" = '""' ] && v=
			;;
	esac
	printf '%s' "$v"
}

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

omci_value() {
	"$OMCI" get "$1" 2>/dev/null |
		sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}

reassert_gpon_loid_after_reconfig() {
	local want_loid want_pw try have_loid have_pw
	want_loid=$1
	want_pw=$2
	[ -n "$want_loid" ] || return 0
	try=0
	while [ "$try" -lt 5 ]; do
		sleep 1
		$OMCI set loid "$want_loid" >/dev/null 2>&1
		$OMCI set loidPasswd "$want_pw" >/dev/null 2>&1
		have_loid=$(omci_value loid)
		have_pw=$(omci_value loidPasswd)
		if [ "$have_loid" = "$want_loid" ] && [ "$have_pw" = "$want_pw" ]; then
			logger -t xpon "apply_auth: GPON LOID reconfig 后已复写 loidPasswd='${want_pw}'"
			return 0
		fi
		try=$((try + 1))
	done
	logger -t xpon "apply_auth: GPON LOID reconfig 后复写失败 want_loid='$want_loid' want_passwd='$want_pw' have_loid='$have_loid' have_passwd='$have_pw'"
	return 1
}

reassert_gpon_identity_after_reconfig() {
	local want_sn want_vendor want_serial try have_sn have_vendor
	want_sn=$(printf '%s' "$1" | tr -d '[:space:]' | tr 'a-z' 'A-Z')
	[ "${#want_sn}" -eq 12 ] || return 0
	want_vendor=${want_sn%????????}
	want_serial=${want_sn#????}
	case "$want_vendor" in *[!A-Z0-9]*|'') return 0 ;; esac
	case "$want_serial" in *[!0-9A-F]*|'') return 0 ;; esac
	try=0
	while [ "$try" -lt 5 ]; do
		sleep 1
		$OMCI set sn "$want_sn" >/dev/null 2>&1
		$OMCI set vendorId "$want_vendor" >/dev/null 2>&1
		have_sn=$(omci_value sn | tr -d '[:space:]' | tr 'a-z' 'A-Z')
		have_vendor=$(omci_value vendorId | tr -d '[:space:]' | tr 'a-z' 'A-Z')
		if [ "$have_sn" = "$want_sn" ] && [ "$have_vendor" = "$want_vendor" ]; then
			logger -t xpon "apply_auth: GPON reconfig 后已复写 sn='$want_sn' vendorId='$want_vendor'"
			return 0
		fi
		try=$((try + 1))
	done
	logger -t xpon "apply_auth: GPON reconfig 后 SN/Vendor ID 复写失败 want_sn='$want_sn' want_vendor='$want_vendor' have_sn='$have_sn' have_vendor='$have_vendor'"
	return 1
}

# 开机恢复：新版 S00xponconfig 在驱动初始化阶段直接调用本函数；旧固件
# 仍由 S11xpon-app 在 S20network/netifd 读取配置前调用。两条路径都从
# LuCI 持久源 /etc/config/xpon（auth 类型段 device）镜像 network.xpon_auth，
# 避免原厂脚本使用 DSD fsan 覆盖用户保存的 SN/LOID。
# xpon.device.pon_mode 只由 LuCI 认证页成功保存时写入，并作为“用户已保存”标志。
# EPON 走 OAM（oamcfgCmd loid0），GPON 走 OMCI（omcicfgCmd）。
restore_auth() {
	local t p pt k v read_v factory_sn legacy_sn legacy_vendor legacy_serial
	local old_loid old_loidpw old_type old_method old_sn_type old_password old_loid_auth onu_type onu_high method
	local mode_sn mode_loid mode_loidpw
	# env 是 ONU 形态/PON 技术的唯一权威来源。优先采用本次实际启动参数，
	# 只有 /proc/cmdline 缺失时才读取 env；此函数永远不反写两者。
	onu_type=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^onu_type=/) { print substr($i, 10); exit } }' /proc/cmdline 2>/dev/null)
	case "$onu_type" in
		[0-9A-Fa-f][0-9A-Fa-f]) : ;;
		*) onu_type=$(fw_printenv -n onu_type 2>/dev/null) ;;
	esac
	case "$onu_type" in [0-9A-Fa-f][0-9A-Fa-f]) : ;; *) onu_type= ;; esac
	onu_high=${onu_type%?}
	case "$onu_high" in
		1) p=GPON; pt=GPON ;;
		2) p=EPON; pt=EPON ;;
		3) p=EPON; pt=EPON_10G_1G ;;
		4) p=EPON; pt=EPON_10G_10G ;;
		5) p=EPON; pt=EPON_1G_1G ;;
		6) p=GPON; pt=XGPON ;;
		7) p=GPON; pt=XGSPON ;;
		c|C) p=EPON; pt=EPON_TURBO ;;
		*)
			logger -t xpon "restore-auth: 无法识别 env onu_type=$onu_type，保留现有 PON 引擎且不写 env"
			p=$(uci_get network.xpon_auth.pon_mode); [ "$p" = EPON ] || p=GPON
			pt=$(uci_get network.xpon_auth.pon_tech)
			;;
	esac
	if ! uci -q get xpon.device.pon_mode >/dev/null; then
		# 旧包/覆盖安装没有“已保存”标志时，不把模板默认冒充用户配置。
		# 认证类型优先取 network 旧配置，再取 xpon.device；不能只靠 LOID
		# 是否存在猜测，否则 PASSWORD 残留 mtk1111 会被误当成 LOID。
		factory_sn=$(sed -n "s/^fsan='\(.*\)'/\1/p" /tmp/dsd.env 2>/dev/null | head -1)
		legacy_sn=$(uci_get network.xpon_auth.sn)
		[ -n "$legacy_sn" ] || legacy_sn=$(uci_get xpon.device.sn)
		old_loid=$(uci_get network.xpon_auth.loid)
		[ -n "$old_loid" ] || old_loid=$(uci_get xpon.device.loid)
		[ "$old_loid" = mtk1111 ] && old_loid=
		old_loidpw=$(uci_get network.xpon_auth.loid_password)
		[ -n "$old_loidpw" ] || old_loidpw=$(uci_get xpon.device.loid_password)
		[ "$old_loidpw" = '""' ] && old_loidpw=
		old_type=$(uci_get network.xpon_auth.auth_type_g)
		old_method=$(uci_get network.xpon_auth.auth_method_g)
		old_sn_type=$(uci_get network.xpon_auth.xpon_sn_auth_type)
		[ -n "$old_type" ] || old_type=$(uci_get xpon.device.auth_type_g)
		[ -n "$old_method" ] || old_method=$(uci_get xpon.device.auth_method_g)
		[ -n "$old_sn_type" ] || old_sn_type=$(uci_get xpon.device.xpon_sn_auth_type)
		old_type=$(printf '%s' "$old_type" | tr 'a-z' 'A-Z')
		old_method=$(printf '%s' "$old_method" | tr 'A-Z' 'a-z')
		old_sn_type=$(printf '%s' "$old_sn_type" | tr 'A-Z' 'a-z')
		old_password=
		old_loid_auth=
		if [ "$old_method" = password ] || [ "$old_type" = PASSWORD ] || \
		   { [ "$old_type" = SN ] && [ "$old_sn_type" = regid ]; }; then
			old_password=1
		fi
		uci set network.xpon_auth='xpon_auth'
		uci set network.xpon_auth.pon_mode="$p"
		[ -n "$pt" ] && uci set network.xpon_auth.pon_tech="$pt"
		legacy_sn=$(printf '%s' "$legacy_sn" | tr -d '[:space:]' | tr 'a-z' 'A-Z')
		if [ "${#legacy_sn}" -ne 12 ]; then
			legacy_sn=
		else
			legacy_vendor=${legacy_sn%????????}
			legacy_serial=${legacy_sn#????}
			case "$legacy_vendor" in *[!A-Z0-9]*|'') legacy_sn= ;; esac
			case "$legacy_serial" in *[!0-9A-F]*|'') legacy_sn= ;; esac
		fi
		[ -n "$legacy_sn" ] || legacy_sn=$factory_sn
		[ "${#legacy_sn}" -eq 12 ] && {
			uci set network.xpon_auth.sn="$legacy_sn"
			uci set network.xpon_auth.def_sn="$legacy_sn"
		}
		if [ "$p" = EPON ]; then
			old_loid_auth=1
			uci set network.xpon_auth.auth_type_e='LOID'
			uci -q delete network.xpon_auth.auth_type_g
			uci -q delete network.xpon_auth.auth_method_g
		elif [ "$old_password" = 1 ]; then
			uci set network.xpon_auth.auth_type_g='sn'
			uci set network.xpon_auth.auth_method_g='password'
			uci -q delete network.xpon_auth.auth_type_e
		elif [ "$old_method" = loid ] || [ "$old_type" = LOID ]; then
			old_loid_auth=1
			uci set network.xpon_auth.auth_type_g='LOID'
			uci set network.xpon_auth.auth_method_g='loid'
			uci -q delete network.xpon_auth.auth_type_e
		elif [ "$old_method" = sn ] || [ "$old_type" = SN ]; then
			uci set network.xpon_auth.auth_type_g='sn'
			uci set network.xpon_auth.auth_method_g='sn'
			uci -q delete network.xpon_auth.auth_type_e
		elif [ -n "$old_loid" ]; then
			old_loid_auth=1
			uci set network.xpon_auth.auth_type_g='LOID'
			uci set network.xpon_auth.auth_method_g='loid'
			uci -q delete network.xpon_auth.auth_type_e
		else
			uci set network.xpon_auth.auth_type_g='sn'
			uci set network.xpon_auth.auth_method_g='sn'
			uci -q delete network.xpon_auth.auth_type_e
		fi
		if [ "$old_loid_auth" = 1 ]; then
			[ -n "$old_loid" ] && uci set network.xpon_auth.loid="$old_loid"
			if [ -n "$old_loidpw" ]; then
				uci set network.xpon_auth.loid_password="$old_loidpw"
			else
				uci set 'network.xpon_auth.loid_password=""'
			fi
		else
			uci -q delete network.xpon_auth.loid
			uci -q delete network.xpon_auth.loid_password
		fi
		if [ "$p" = EPON ]; then
			for k in epon_oui epon_ctc_oui epon_ven_info epon_onu_vendor_id epon_serial epon_pon_mac; do
				v=$(uci_get network.xpon_auth.$k)
				[ -n "$v" ] || v=$(uci_get xpon.device.$k)
				[ -n "$v" ] && uci set network.xpon_auth.$k="$v"
			done
			uci -q delete network.xpon_auth.xpon_sn_auth_type
			uci -q delete network.xpon_auth.sn_ascii_password
			uci -q delete network.xpon_auth.sn_hex_password
			uci -q delete network.xpon_auth.sn_regid_password
		else
			for k in xpon_sn_auth_type sn_ascii_password sn_hex_password sn_regid_password; do
				v=$(uci_get network.xpon_auth.$k)
				[ -n "$v" ] || v=$(uci_get xpon.device.$k)
				[ -n "$v" ] && uci set network.xpon_auth.$k="$v"
			done
			for k in epon_oui epon_ctc_oui epon_ven_info epon_onu_vendor_id epon_serial epon_pon_mac; do
				uci -q delete network.xpon_auth.$k
			done
		fi
		uci commit network
		logger -t xpon "restore-auth: 未找到已保存标志，按旧配置恢复 pon_mode=$p auth_type=$(uci_get network.xpon_auth.auth_type_g) sn=$(uci_get network.xpon_auth.sn)"
		return 0
	fi
	t=$(uci_get xpon.device.auth_type_g)
	method=$(uci_get xpon.device.auth_method_g)
	method=$(printf '%s' "$method" | tr 'A-Z' 'a-z')
	[ "$method" = "password" ] && t=sn
	mode_sn=$(mode_credential_get "$p" sn | tr -d '[:space:]' | tr 'a-z' 'A-Z')
	mode_loid=$(mode_credential_get "$p" loid)
	mode_loidpw=$(mode_credential_get "$p" loid_password)
	[ "$mode_loidpw" = '""' ] && mode_loidpw=
	if [ "$p" = "EPON" ]; then
		[ -n "$mode_loid" ] || {
			logger -t xpon "restore-auth: pon_mode=EPON 但 epon_loid 为空，跳过覆盖"
			return 0
		}
	else
		[ -n "$t" ] || return 0
		case "$t" in
			loid|LOID)
				[ -n "$mode_loid" ] || {
					logger -t xpon "restore-auth: auth_type_g=$t 但 gpon_loid 为空，跳过覆盖"
					return 0
				}
				;;
			sn|SN|password|PASSWORD) t=sn ;;
			*) logger -t xpon "restore-auth: 未知 auth_type_g=$t，跳过"; return 0 ;;
		esac
	fi

	uci set network.xpon_auth='xpon_auth'
	uci set network.xpon_auth.pon_mode="$p"
	[ -n "$pt" ] && uci set network.xpon_auth.pon_tech="$pt"
	if [ "$p" = "EPON" ]; then
		te=$(uci_get xpon.device.auth_type_e); te=${te:-LOID}
		uci set network.xpon_auth.auth_type_e="$te"
		uci -q delete network.xpon_auth.auth_type_g
		uci -q delete network.xpon_auth.auth_method_g
	else
		uci set network.xpon_auth.auth_type_g="$t"
		if [ -n "$method" ]; then
			uci set network.xpon_auth.auth_method_g="$method"
		else
			uci -q delete network.xpon_auth.auth_method_g
		fi
		uci -q delete network.xpon_auth.auth_type_e
	fi
	if [ -n "$mode_sn" ]; then
		uci set network.xpon_auth.sn="$mode_sn"
		uci set network.xpon_auth.def_sn="$mode_sn"
	else
		uci -q delete network.xpon_auth.sn
		uci -q delete network.xpon_auth.def_sn
	fi
	if [ "$p" = EPON ]; then
		uci -q delete network.xpon_auth.xpon_sn_auth_type
		uci -q delete network.xpon_auth.sn_ascii_password
		uci -q delete network.xpon_auth.sn_hex_password
		uci -q delete network.xpon_auth.sn_regid_password
	else
		for k in xpon_sn_auth_type sn_ascii_password sn_hex_password sn_regid_password; do
			v=$(uci_get xpon.device.$k)
			[ -n "$v" ] && uci set network.xpon_auth.$k="$v"
		done
	fi
	if [ "$p" = EPON ] || [ "$t" = LOID ] || [ "$t" = loid ]; then
		[ -n "$mode_loid" ] && uci set network.xpon_auth.loid="$mode_loid"
		# libuci 不保留真正的空字符串。字面值 "" 对 UCI 是已配置值，
		# netifd 拼接原生命令后则由 shell 解析为空参数，避免回退到 ECONET。
		if [ -n "$mode_loidpw" ]; then
			uci set network.xpon_auth.loid_password="$mode_loidpw"
		else
			uci set 'network.xpon_auth.loid_password=""'
		fi
	else
		uci -q delete network.xpon_auth.loid
		uci -q delete network.xpon_auth.loid_password
	fi
	if [ "$p" = EPON ]; then
		for k in epon_oui epon_ctc_oui epon_ven_info epon_onu_vendor_id epon_serial epon_pon_mac; do
			v=$(uci_get xpon.device.$k)
			if [ -n "$v" ]; then
				uci set network.xpon_auth.$k="$v"
			else
				uci -q delete network.xpon_auth.$k
			fi
		done
		uci -q delete network.xpon_auth.gpon_pon_mac
	else
		v=$(uci_get xpon.device.gpon_pon_mac)
		if [ -n "$v" ]; then
			uci set network.xpon_auth.gpon_pon_mac="$v"
		else
			uci -q delete network.xpon_auth.gpon_pon_mac
		fi
		for k in epon_oui epon_ctc_oui epon_ven_info epon_onu_vendor_id epon_serial epon_pon_mac; do
			uci -q delete network.xpon_auth.$k
		done
	fi
	uci commit network || {
		logger -t xpon "restore-auth: network 提交失败，持久认证未恢复"
		return 1
	}
	if [ -n "$mode_sn" ]; then
		for k in sn def_sn; do
			read_v=$(uci_get network.xpon_auth.$k)
			[ "$read_v" = "$mode_sn" ] || {
				logger -t xpon "restore-auth: $k 回读失败 want='$mode_sn' have='$read_v'"
				return 1
			}
		done
	fi
	if [ "$p" = EPON ] || [ "$t" = LOID ] || [ "$t" = loid ]; then
		read_v=$(uci_get network.xpon_auth.loid)
		[ "$read_v" = "$mode_loid" ] || {
			logger -t xpon "restore-auth: loid 回读失败 want='$mode_loid' have='$read_v'"
			return 1
		}
	fi
	logger -t xpon "restore-auth: 按 env onu_type=$onu_type 恢复 pon_mode=$p pon_tech=$pt auth_type=$([ "$p" = EPON ] && echo EPON-LOID || echo "$t")（loid=$(uci_get network.xpon_auth.loid) sn=$(uci_get network.xpon_auth.sn)）"
}

apply_auth() {
	local mode configured_mode auth auth_method sn_type loid loidpw sn apwd hexpwd regpwd identity_sn identity_vendor
	local epon_oui epon_ctc_oui epon_ven epon_onu_vendor tries
	local equipment_val onuver_val omcc_val
	identity_get() {
		iv=$(uci_get network.xpon_auth.$1)
		[ -n "$iv" ] || iv=$(uci_get xpon.device.$1)
		printf '%s' "$iv"
	}
	configured_mode=$(uci_get network.xpon_auth.pon_mode)
	mode=$(current_pon_mode 2>/dev/null)
	if [ -z "$mode" ]; then
		mode=$configured_mode; [ "$mode" = EPON ] || mode=GPON
	elif [ -n "$configured_mode" ] && [ "$configured_mode" != "$mode" ]; then
		logger -t xpon "apply_auth: network pon_mode=$configured_mode 与当前 onu_type 引擎=$mode 不一致，以当前引擎为准"
	fi
	auth=$(uci_get network.xpon_auth.auth_type_g); [ -z "$auth" ] && auth=LOID
	auth_method=$(uci_get network.xpon_auth.auth_method_g)
	[ -n "$auth_method" ] || auth_method=$(uci_get xpon.device.auth_method_g)
	auth_method=$(printf '%s' "$auth_method" | tr 'A-Z' 'a-z')
	[ "$auth_method" = "password" ] && auth=sn
	case "$auth" in
		loid|LOID) auth=loid ;;
		sn|SN|password|PASSWORD) auth=sn ;;
	esac
	sn=$(mode_credential_get "$mode" sn)
	sn=$(printf '%s' "$sn" | tr 'a-z' 'A-Z')
	loid=$(mode_credential_get "$mode" loid)
	loidpw=$(mode_credential_get "$mode" loid_password)
	[ "$loidpw" = '""' ] && loidpw=
	sn_type=$(uci_get network.xpon_auth.xpon_sn_auth_type); [ -z "$sn_type" ] && sn_type=ascii
	[ "$auth_method" = "password" ] && sn_type=regid
	apwd=$(uci_get network.xpon_auth.sn_ascii_password)
	hexpwd=$(uci_get network.xpon_auth.sn_hex_password)
	regpwd=$(uci_get network.xpon_auth.sn_regid_password)
	equipment_val=$(identity_get equipment_id)
	onuver_val=$(identity_get onu_version)
	omcc_val=$(identity_get omcc_version)
	valid_pon_sn() {
		[ "${#1}" -eq 12 ] || return 1
		vpart=${1%????????}
		spart=${1#????}
		case "$vpart" in *[!A-Z0-9]*|'') return 1 ;; esac
		case "$spart" in *[!0-9A-F]*|'') return 1 ;; esac
		return 0
	}

	# omcicfgCmd 对参数有长度校验（如 SN 必须 12 字节、loid ≤24 字节），
	# 空值/非法长度一律跳过并记日志——避免误覆盖出厂 SN（NoNumber 8 字节会被拒）。
	set_sn() { # $1=sn
		[ -n "$1" ] || return 0
		if valid_pon_sn "$1"; then
			$OMCI set sn "$1" >/dev/null 2>&1
		else
			logger -t xpon "skip set sn '$1'（须为 4 位厂商代码 + 8 位 hex，保持出厂 SN）"
		fi
	}

	if [ "$mode" = "GPON" ]; then
		if [ "$auth" = "loid" ]; then
			set_sn "$sn"
			[ -n "$loid" ] && $OMCI set loid "$loid" >/dev/null 2>&1
			# 空字符串是有效配置，表示 LOID-only；不能保留 netifd 的 ECONET 默认值。
			logger -t xpon "apply_auth: $OMCI set loidPasswd '$loidpw'"
			$OMCI set loidPasswd "$loidpw" >/dev/null 2>&1
		else
			set_sn "$sn"
			# SN 密码：本固件 omcicfgCmd 无 passwdAscii/passwdHex 子命令
			# （netifd 会调用，但被 omcicfgCmd 静默拒绝），
			# 实际生效入口是 ponmgr：`gpon set passwd <ascii|hex|regid> <值>`
			#   ascii ≤10 字符、hex ≤20 位（=10 字节的十六进制编码）、regid ≤36（移动 Password / 电信注册码）
			# 按 xpon_sn_auth_type 三选一（hex->hex，regid->regid，其它->ascii）
			if [ "$sn_type" = "hex" ]; then
				[ -n "$hexpwd" ] && {
					logger -t xpon "apply_auth: $PONMGRCLI gpon set passwd hex '$hexpwd'"
					$PONMGRCLI gpon set passwd hex "$hexpwd" >/dev/null 2>&1
				}
			elif [ "$sn_type" = "regid" ]; then
				[ -n "$regpwd" ] && {
					logger -t xpon "apply_auth: $PONMGRCLI gpon set passwd regid '$regpwd'"
					$PONMGRCLI gpon set passwd regid "$regpwd" >/dev/null 2>&1
				}
			else
				[ -n "$apwd" ] && {
					logger -t xpon "apply_auth: $PONMGRCLI gpon set passwd ascii '$apwd'"
					$PONMGRCLI gpon set passwd ascii "$apwd" >/dev/null 2>&1
				}
			fi
		fi
		# 厂商信息（netifd 引擎不管）。pon_mode 同时作为认证页已成功保存标志；
		# 没有标志时不能把旧安装包的模板默认当成用户配置下发。
		# 固件 omcicfgCmd 的 set/get 参数名是 camelCase：
		# vendorId / equipmentId / onuVersion / omccVersion / specVer。
		if [ -n "$(uci_get xpon.device.pon_mode)" ]; then
			identity_sn=$sn
			identity_vendor=
			if valid_pon_sn "$identity_sn"; then
				identity_vendor=${identity_sn%????????}
			fi
			logger -t xpon "apply_auth: GPON identity auth=$auth sn=$identity_sn vendor_id=$identity_vendor onu_version=${onuver_val:-skip}"
			[ -n "$identity_vendor" ] && $OMCI set vendorId "$identity_vendor" >/dev/null 2>&1
			[ -n "$equipment_val" ] && $OMCI set equipmentId "$equipment_val" >/dev/null 2>&1
			[ -n "$onuver_val" ] && $OMCI set onuVersion "$onuver_val" >/dev/null 2>&1
			[ -n "$omcc_val" ] && $OMCI set omccVersion "$omcc_val" >/dev/null 2>&1
			# 记录实际回读值，区分 UCI 保存成功与 OMCI 下发成功。
			for pair in vendor_id:vendorId equipment_id:equipmentId onu_version:onuVersion omcc_version:omccVersion; do
				uci_attr=${pair%%:*}
				omci_attr=${pair#*:}
				want=$(identity_get "$uci_attr")
				[ "$uci_attr" = vendor_id ] && want=$identity_vendor
				[ -n "$want" ] || continue
				have=$($OMCI get "$omci_attr" 2>/dev/null | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1)
				[ "$have" = "$want" ] || logger -t xpon "apply_auth: $uci_attr 下发不一致 want='$want' have='$have'"
			done
		else
			# 未保存状态采用 DSD/网络 SN 的前四字节，避免旧模板 MTKG 与 AXON SN 不一致。
			factory_vendor=${sn%????????}
			[ "${#sn}" -eq 12 ] && [ "${#factory_vendor}" -eq 4 ] && \
				$OMCI set vendorId "$factory_vendor" >/dev/null 2>&1
		fi
		# OMCI 消息交互协议版本（spec_version，uint8；与 G.988 标准 2 字节版本的映射需真机验证）
		[ -n "$(uci_get xpon.device.omci_spec_ver)" ] && $OMCI set specVer "$(uci_get xpon.device.omci_spec_ver)" >/dev/null 2>&1
	elif [ "$mode" = "EPON" ]; then
		# EPON（onu_type bits[7:4]=2/3/4/5/C）统一走 OAM 认证。
		# 按 stock netifd 的 EPON 激活流程执行：
		#   oamcfgCmd set mode 2（LINK_MODE_EPON）
		#   oamcfgCmd set loid0 <loid> / set loidPasswd0 <pwd>
		# 具体速率模式必须与 OLT 端口能力一致。
		if [ "${#loidpw}" -gt 12 ]; then
			logger -t xpon "apply_auth: EPON LOID 密码为 ${#loidpw} 字节，超过 oamcfgCmd loidPasswd0 的 12 字节限制"
			return 1
		fi
		$OAM set mode 2 >/dev/null 2>&1
		[ -n "$loid" ] && $OAM set loid0 "$loid" >/dev/null 2>&1
		[ -n "$loid" ] && {
			logger -t xpon "apply_auth: $OAM set loidPasswd0 '$loidpw'"
			$OAM set loidPasswd0 "$loidpw" >/dev/null 2>&1
		}
		# OAM 身份均为运行态；这里先写只是兼容旧引擎，重启后的新进程
		# 还必须由 xpon-auth-native.sh 再写一次并逐项回读。
		epon_oui=$(uci_get xpon.device.epon_oui)
		epon_ctc_oui=$(uci_get xpon.device.epon_ctc_oui); epon_ctc_oui=${epon_ctc_oui:-111111}
		epon_ven=$(uci_get xpon.device.epon_ven_info)
		epon_onu_vendor=$(uci_get xpon.device.epon_onu_vendor_id)
		[ -n "$epon_oui" ] && $OAM set localOui "$epon_oui" >/dev/null 2>&1
		[ -n "$epon_ctc_oui" ] && $OAM set ctcOui "$epon_ctc_oui" >/dev/null 2>&1
		[ -n "$epon_ven" ] && $OAM set localVenInfo "$epon_ven" >/dev/null 2>&1
		[ -n "$epon_onu_vendor" ] && $OAM set onuVenID "$epon_onu_vendor" >/dev/null 2>&1
	fi

	# 让共享内存配置生效。
	if [ "$mode" = "EPON" ]; then
		# XEPON/EPON：重启 OAM 引擎
		killall epon_oam >/dev/null 2>&1
		rm -f /tmp/epon_oam.pid
		sleep 1
		killall ponmgr_cfg >/dev/null 2>&1
		$PONMGR &
		$EPON_OAM &
			# epon_oam 初始化会把 ctcOui/onuVenID/CTC ONUSN 等运行态恢复为固件默认值。
		# 必须等待新进程可读后再做最终身份重放，不能在 kill 之前写完就退出。
		tries=0
		while [ "$tries" -lt 20 ]; do
			pidof epon_oam >/dev/null 2>&1 && $OAM get mode >/dev/null 2>&1 && break
			tries=$((tries + 1))
			sleep 1
		done
		[ "$tries" -lt 20 ] || {
			logger -t xpon "EPON OAM 重启后 20 秒内未就绪，身份未重放"
			return 1
		}
		/usr/bin/xpon-auth-native.sh || {
			logger -t xpon "EPON OAM 重启后身份重放失败，详见 /tmp/xpon-auth-native.log"
			return 1
		}
	else
		# GPON：认证属性（尤其 vendor_id/equipment_id）写入共享配置后只需 reconfig。
		# 不能在 LuCI 保存请求中 kill/restart omci/ponmgr，否则 PON 短断并导致页面登出。
		# 设备未运行时由 xpon-app 开机流程负责拉起，不在这里强制重启。
		if [ -x "$OMCID" ]; then
			$OMCID set reconfig >/dev/null 2>&1
			reassert_gpon_identity_after_reconfig "$sn" || return 1
			# 原厂 reconfig 会重新跑一遍 netifd/OMCI 缺省路径；LOID-only
			# 场景下它可能短暂恢复内置 Econet。reconfig 完成后再复写一次。
			if [ "$auth" = "loid" ]; then
				reassert_gpon_loid_after_reconfig "$loid" "$loidpw" || return 1
			fi
		fi
	fi
}

apply_network() {
	uci commit network
	/etc/init.d/network reload
}

apply_mac() {
	# pon 是业务侧 Ethernet 接口；GPON/XGPON/XGSPON 的 PLOAM/OMCI
	# 注册身份来自 SN/Registration ID，而不是 Ethernet MAC。
	# EPON 的 MPCP ONU MAC 则由驱动启动时通过 get_ethaddr() 取得。
	local mode pmac old_eth read_eth
	local backup_dir backup_stamp backup_path backup_tmp
	mode=$(uci_get network.xpon_auth.pon_mode)
	[ "$mode" = EPON ] || mode=$(uci_get xpon.device.pon_mode)
	[ "$mode" = EPON ] || mode=GPON
	if [ "$mode" = EPON ]; then
		pmac=$(uci_get xpon.device.epon_pon_mac)
	else
		pmac=$(uci_get xpon.device.gpon_pon_mac)
	fi
	[ -n "$pmac" ] || pmac=$(uci_get xpon.device.pon_mac)
	[ -n "$pmac" ] || pmac=$(sed -n 's/^wan_mac=//p' /tmp/dsd.env 2>/dev/null | tr -d "'\"" | head -1)
	case "$pmac" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) : ;;
		*)
			[ "$mode" = EPON ] && {
				echo "EPON 注册 MAC 无效，且未取得有效 DSD wan_mac" >&2
				return 1
			}
			logger -t xpon "GPON 业务接口 MAC 未配置且 DSD wan_mac 无效，保持 pon 当前地址"
			return 0
			;;
	esac
	pmac=$(printf '%s' "$pmac" | tr 'a-f' 'A-F')

	if [ "$mode" != EPON ]; then
		ifconfig pon hw ether "$pmac" 2>/dev/null || {
			echo "设置 pon 业务接口 MAC 失败" >&2
			return 1
		}
		logger -t xpon "GPON 业务接口 MAC 已设置：pon=$pmac；未修改 U-Boot ethaddr"
		return 0
	fi

	command -v fw_setenv >/dev/null 2>&1 && command -v fw_printenv >/dev/null 2>&1 || {
		echo "fw_setenv/fw_printenv 不可用（缺 uboot-envtools 或 fw_env.config）" >&2
		return 1
	}

	old_eth=$(fw_printenv -n ethaddr 2>/dev/null | tr 'a-f' 'A-F')
	if [ "$old_eth" = "$pmac" ]; then
		ifconfig pon hw ether "$pmac" 2>/dev/null || true
		logger -t xpon "EPON MPCP 注册 MAC env 已一致：ethaddr=$pmac（无需写入）"
		return 0
	fi

	# 写入前保存完整环境，兼顾教程里的人工恢复路径。每次保存生成独立文件，
	# 避免上一次写入失败后重试时覆盖唯一的可用备份。
	backup_dir=/etc/xpon-env-backups
	backup_stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null)
	[ -n "$backup_stamp" ] || backup_stamp=unknown
	backup_path="$backup_dir/ponmac-$backup_stamp-$$.bak"
	backup_tmp="$backup_path.tmp"
	umask 077
	mkdir -p "$backup_dir" || { echo "创建 U-Boot env 备份目录失败" >&2; return 1; }
	chmod 700 "$backup_dir" 2>/dev/null || true
	fw_printenv > "$backup_tmp" 2>/dev/null || {
		rm -f "$backup_tmp"
		echo "备份 U-Boot env 失败，拒绝修改注册 MAC" >&2
		return 1
	}
	mv "$backup_tmp" "$backup_path" || {
		rm -f "$backup_tmp"
		echo "保存 U-Boot env 备份失败，拒绝修改注册 MAC" >&2
		return 1
	}

	[ "$old_eth" = "$pmac" ] || fw_setenv ethaddr "$pmac" || {
		echo "写入 env ethaddr 失败；原环境已备份到 $backup_path" >&2
		return 1
	}
	read_eth=$(fw_printenv -n ethaddr 2>/dev/null | tr 'a-f' 'A-F')
	[ "$read_eth" = "$pmac" ] || {
		echo "env ethaddr 回读失败：期望 $pmac，实际 ${read_eth:-空}" >&2
		return 1
	}
	ifconfig pon hw ether "$pmac" 2>/dev/null || true
	logger -t xpon "EPON MPCP 注册 MAC env 写入并回读成功：ethaddr=$pmac backup=$backup_path"
}

apply_leds() {
	local led
	# sts_green 常亮修复：缺 aliases 时设备默认闪绿。
	if [ "$(uci_get xpon.led.fix_sts_green)" = "1" ] && [ -d /sys/class/leds/sts_green ]; then
		echo none > /sys/class/leds/sts_green/trigger 2>/dev/null
		echo 255 > /sys/class/leds/sts_green/brightness 2>/dev/null
	fi
	# 上网灯：pppoe-wan netdev 触发器（可选）
	led=$(uci_get xpon.led.internet_led)
	[ -n "$led" ] && [ -d "/sys/class/leds/$led" ] && {
		echo netdev > "/sys/class/leds/$led/trigger" 2>/dev/null
		echo pppoe-wan > "/sys/class/leds/$led/device_name" 2>/dev/null
		echo 1 > "/sys/class/leds/$led/link" 2>/dev/null
		echo 1 > "/sys/class/leds/$led/tx" 2>/dev/null
		echo 1 > "/sys/class/leds/$led/rx" 2>/dev/null
	}
}

# 切换 HGU / SFU × GPON / XGPON / XGSPON 模式（写 U-Boot env，重启后生效）
# PON 模式来自 U-Boot env 的 onu_type 字节：
#       bits[1:0]=ONU 类型 1=SFU 2=HGU；bits[7:4]=PON 模式 1=GPON 6=XGPON 7=XGSPON。
#       出厂 71=SFU+XGSPON；本机当前 61=SFU+XGPON；联通 HGU 请用 62=HGU+XGPON。
# 只改 env 不重启（由页面选择是否 reboot）。
apply_ponmode() {
	local val="$1"
	local ba_raw ba newba read_ba read_ba_onu bootargs_present=0
	[ -n "$val" ] || { echo "usage: xpon-apply.sh ponmode <2-digit-hex>" >&2; return 1; }
	case "$val" in
		[0-9a-fA-F][0-9a-fA-F]) : ;;
		*) echo "invalid onu_type: $val（需 2 位十六进制）" >&2; return 1 ;;
	esac
	command -v fw_setenv >/dev/null 2>&1 || {
		echo "fw_setenv 不可用（缺 uboot-envtools 或 fw_env.config）" >&2
		return 1
	}

	# Some XG2010G images boot from a FIT DTB and have no legacy bootargs.
	# When bootargs is present (as on older/upgraded devices), it remains the
	# effective command line and must be kept in sync with onu_type. Never create
	# bootargs on images where it is absent.
	ba_raw=$(fw_printenv -n bootargs 2>/dev/null)
	ba=$ba_raw
	while [ "${ba#bootargs=}" != "$ba" ]; do ba=${ba#bootargs=}; done
	if [ -n "$ba" ]; then
		bootargs_present=1
		case " $ba " in
			*" onu_type="[0-9a-fA-F]*) : ;;
			*) echo "bootargs 中缺少 onu_type，拒绝写入不完整模式" >&2; return 1 ;;
		esac
		newba=$(printf '%s' "$ba" | sed "s/onu_type=[0-9a-fA-F]*/onu_type=$val/")
		[ -n "$newba" ] || { echo "生成 bootargs 失败" >&2; return 1; }
	fi
	fw_setenv onu_type "$val" || { echo "写入 env onu_type 失败" >&2; return 1; }
	[ "$bootargs_present" -eq 0 ] || [ "$newba" = "$ba" ] || fw_setenv bootargs "$newba" || {
		echo "写入 env bootargs 失败" >&2
		return 1
	}

	read_onu=$(fw_printenv -n onu_type 2>/dev/null | tr 'a-f' 'A-F')
	val=$(printf '%s' "$val" | tr 'a-f' 'A-F')
	[ "$read_onu" = "$val" ] || {
		echo "env onu_type 回读失败：期望 $val，实际 ${read_onu:-空}" >&2
		return 1
	}
	if [ "$bootargs_present" -eq 1 ]; then
		read_ba=$(fw_printenv -n bootargs 2>/dev/null)
		read_ba_onu=$(printf '%s\n' "$read_ba" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^onu_type=/) { print substr($i, 10); exit } }' | tr 'a-f' 'A-F')
		val=$(printf '%s' "$val" | tr 'a-f' 'A-F')
		[ "$read_ba_onu" = "$val" ] || {
			echo "env bootargs 回读失败：期望 onu_type=$val，实际 ${read_ba_onu:-空}" >&2
			return 1
		}
		logger -t xpon "模式 env/bootargs 写入并回读成功：onu_type=$val"
	else
		logger -t xpon "bootargs 未定义，模式仅通过 env onu_type=$val 保存并回读"
	fi
}

apply_iptv() {
	[ -x /usr/bin/xpon-iptv.sh ] || return 0
	/usr/bin/xpon-iptv.sh >/dev/null 2>&1
}

rc=0
case "${1:-all}" in
	restore-auth) restore_auth || rc=$? ;;
	auth)    apply_auth || rc=$? ;;
	network) apply_network || rc=$? ;;
	mac)     apply_mac || rc=$? ;;
	leds)    apply_leds || rc=$? ;;
	iptv)    apply_iptv || rc=$? ;;
	ponmode) apply_ponmode "$2" || rc=$? ;;
	all)
		restore_auth || rc=$?
		[ "$rc" -ne 0 ] || apply_auth || rc=$?
		[ "$rc" -ne 0 ] || apply_mac || rc=$?
		[ "$rc" -ne 0 ] || apply_network || rc=$?
		[ "$rc" -ne 0 ] || apply_leds || rc=$?
		;;
	*) echo "usage: $0 {restore-auth|auth|network|mac|leds|iptv|ponmode <hex>|all}" >&2; exit 1 ;;
esac

exit "$rc"
