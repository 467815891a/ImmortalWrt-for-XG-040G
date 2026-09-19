#!/bin/sh
# xpon-iptv.sh —— IPTV 组播配置后端
#
# 数据源：xpon.iptv.*（旧版/兼容 IPTV 配置）
#   vlan          IPTV 业务 VLAN（由用户或 OLT 业务配置决定）
#   mcast_vlan    组播 VLAN（多数省份 OLT 直接在业务 VLAN 内送组播，
#                 此值仅当需要单独登记 M-VLAN 过滤表时填写）
#   igmp_version  2 | 3（每业务口 igmp_set_ver）
#   igmp_fastleave 0|1（每业务口 igmp_set_fastleave）
#   iptv_port     绑定 LAN 口（默认 port 1~4
#                 XG2010G 实际映射为 LAN1/2/3/4 = eth0.8/7/5/4，
#                 port 号需真机用 igmp_get_portvlan_id 验证）
#   stb_port      专口透传（由 hotplug 25-iptv-port 处理，本脚本不重复）
#
# 安全：全部命令静默（> /dev/null 2>&1）；mvlan del 先删旧值再 add，
# 避免重复登记同组播 VLAN；xpon_app/业务页保存时调用。

IGMP=/userfs/bin/xponigmpcmd
ECNT=/userfs/bin/ecnt_igmp_cmd

[ -x "$IGMP" ] || exit 0
[ "$(uci -q get xpon.iptv.enable)" = "1" ] || exit 0

vid=$(uci -q get xpon.iptv.vlan)
mvid=$(uci -q get xpon.iptv.mcast_vlan)
ver=$(uci -q get xpon.iptv.igmp_version)
ver=${ver:-2}
fast=$(uci -q get xpon.iptv.igmp_fastleave)
fast=${fast:-1}
port=$(uci -q get xpon.iptv.iptv_port)

# 1) 组播 VLAN 登记表：先清旧值再登记新值（幂等且不堆积）
if [ -n "$mvid" ] && [ "$mvid" -ge 1 ] 2>/dev/null && [ "$mvid" -le 4094 ] 2>/dev/null; then
	$IGMP mvlan del "$mvid" >/dev/null 2>&1
	$IGMP mvlan add "$mvid" >/dev/null 2>&1
fi

# 2) SDK 侦听/代理模式由 pon.multicast.snooping/proxy 统一管理，
# 避免本脚本在开机延迟重放时覆盖用户刚保存的 fwdmode。

# 3) 业务口参数：绑定口（iptv_port）或默认 UNI port 1
for p in ${port:-1}; do
	case "$p" in
		''|*[!0-9]*) continue ;;
	esac
	[ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 4 ] 2>/dev/null || continue
	$IGMP igmp_set_func "$p" 1 >/dev/null 2>&1
	$IGMP igmp_set_ver "$p" "$ver" >/dev/null 2>&1
	$IGMP igmp_set_fastleave "$p" "$fast" >/dev/null 2>&1
	[ -n "$vid" ] && $IGMP igmp_add_portvlan "$p" "$vid" >/dev/null 2>&1
done

# 4) LAN 侧 IGMP Snooping（ecnt_igmp_cmd）：仅 IPTV 业务开启时使能
$ECNT set_snooping 1 >/dev/null 2>&1

exit 0
