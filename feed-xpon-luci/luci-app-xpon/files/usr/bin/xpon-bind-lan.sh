#!/bin/sh
# XPON 业务接口归属与 PON 引擎自愈；自动处理所有受管 Internet pon.<vlan>。
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/userfs/bin
TAG=xpon-bind; LOCK=/var/run/xpon-bind-lan.lock; LIST=/tmp/xpon-bind-vlans.$$; BRIDGE=br-lan
log(){ logger -t "$TAG" -- "$*" 2>/dev/null || echo "$TAG: $*" >&2; }; get(){ uci -q get "$1" 2>/dev/null; }
lock(){ mkdir "$LOCK" 2>/dev/null || { log "已有实例运行，跳过"; exit 0; }; trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM; }

# 生成 vlan|接口|模式|当前设备 清单；兼容 mode/payload 字段。
collect(){
 local s vid st en m i d access; : > "$LIST"
 for s in $(uci show network 2>/dev/null|sed -n 's/^network\.\([^.=]*\)=xpon_service$/\1/p'); do
  [ "$(get network.$s.xpon_managed)" = 1 ] || continue; vid=$(get network.$s.vlan_id)
  case "$vid" in ''|*[!0-9]*) continue;; esac; [ "$vid" -ge 1 ] 2>/dev/null && [ "$vid" -le 4094 ] 2>/dev/null || continue
  access=$(get network.$s.access_mode); [ "$access" = untagged ] && continue
  st=$(get network.$s.service_type); [ -n "$st" ] || st=internet; [ "$st" = internet ] || continue
  en=$(get network.$s.enable); [ "$en" = 0 ] && continue
  m=$(get network.$s.mode); [ -n "$m" ] || m=$(get network.$s.payload); m=$(printf '%s' "$m"|tr 'A-Z' 'a-z')
  case "$m" in bridged|bridge) m=bridged;; routed|route) m=routed;; *) continue;; esac
  i=$(get network.$s.interface); [ -n "$i" ] || i=nas1_0; d=$(get network.$i.device)
  printf '%s|%s|%s|%s\n' "$vid" "$i" "$m" "$d" >> "$LIST"
 done
 # 没有 xpon_service 元数据时，使用 bind_lan 兼容段。
 if [ ! -s "$LIST" ]; then
  vid=$(get xpon.bind_lan.vlan_id); m=$(get xpon.bind_lan.mode); i=$(get xpon.bind_lan.interface)
  [ -n "$vid" ] && [ -n "$m" ] && { [ -n "$i" ] || i=wan; d=$(get network.$i.device); printf '%s|%s|%s|%s\n' "$vid" "$i" "$m" "$d" >> "$LIST"; }
 fi
}

find_bridge(){ local s n; BRSEC=; for s in $(uci show network 2>/dev/null|sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do [ "$(get network.$s.type)" = bridge ] || continue; n=$(get network.$s.name); [ "$n" = "$1" ] && { BRSEC=$s; return 0; }; done; return 1; }

# 仅移除目标 pon.<vlan>，保留其它 bridge 端口（包括 IPTV eth0.5）。
remove_old(){
 local s p x keep changed; for s in $(uci show network 2>/dev/null|sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
  [ "$(get network.$s.type)" = bridge ] || continue; p=$(get network.$s.ports); keep=; changed=0
  for x in $p; do case "$x" in pon.*) grep -q "${x#pon.}|" "$LIST" 2>/dev/null && changed=1 || keep="$keep $x";; *) keep="$keep $x";; esac; done
  [ "$changed" = 1 ] || continue; uci -q delete network.$s.ports; for x in $keep; do uci -q add_list network.$s.ports="$x"; done
 done
}

apply_binding(){
 local rec vid iface mode dev b; collect; [ -s "$LIST" ] || { log "未找到受管 tagged Internet VLAN"; return 0; }; remove_old
 while IFS='|' read -r vid iface mode dev; do
  [ -n "$vid" ] || continue
  if [ "$mode" = bridged ]; then
   b=$dev; [ -n "$b" ] || b=$BRIDGE; find_bridge "$b" || { b=$BRIDGE; find_bridge "$b" || { log "找不到桥 $b"; continue; }; }
   uci -q add_list network.$BRSEC.ports="pon.$vid"; [ "$dev" = "$b" ] || uci -q set network.$iface.device="$b"; log "桥接：pon.$vid -> $b"
  else
   uci -q set network.$iface.device="pon.$vid"; log "路由：pon.$vid 摘除 bridge，交给 $iface"
  fi
 done < "$LIST"; uci commit network
}

pon_tech(){ local n=$(cat /proc/tc3162/sys_xpon_mode 2>/dev/null); case "$n" in 2|3|4|5|12) echo EPON;; *) [ "$(get network.xpon_auth.pon_mode)" = EPON ] && echo EPON || echo GPON;; esac; }

# EPON OAM：清理残留 pid 后按 init 脚本/二进制顺序重启。
heal_epon_oam(){
 local f p stale=0 need=0 started=0 s b
 for f in /var/run/epon_oam.pid /tmp/epon_oam.pid /var/run/oamd.pid /tmp/oamd.pid; do [ -f "$f" ] || continue; p=$(cat "$f" 2>/dev/null); case "$p" in ''|*[!0-9]*) rm -f "$f"; stale=1;; *) kill -0 "$p" 2>/dev/null || { rm -f "$f"; stale=1; };; esac; done
 pidof epon_oam >/dev/null 2>&1 || pidof oamd >/dev/null 2>&1 || need=1; [ "$stale" = 1 ] && need=1; [ "$need" = 1 ] || return 0
 log "EPON OAM 缺失或 pid 残留，执行自愈"; killall epon_oam >/dev/null 2>&1 || true; killall oamd >/dev/null 2>&1 || true; rm -f /var/run/epon_oam.pid /tmp/epon_oam.pid /var/run/oamd.pid /tmp/oamd.pid
 for s in /etc/init.d/epon_oam /etc/init.d/epon-oam /etc/init.d/oamd; do [ -x "$s" ] || continue; "$s" restart >/dev/null 2>&1 && { started=1; break; }; done
 [ "$started" = 1 ] || for b in /userfs/bin/epon_oam /usr/bin/epon_oam /userfs/bin/oamd /usr/sbin/oamd; do [ -x "$b" ] || continue; "$b" >/dev/null 2>&1 & started=1; break; done
 [ "$started" = 1 ] || log "未找到 EPON OAM 启动入口"
}

# GPON/XGPON：正常运行时执行 OMCI reconfig；缺失/残留时重启 OMCI。
heal_gpon_omci(){
 local f p stale=0 need=0 started=0 s b
 for f in /var/run/omci.pid /tmp/omci.pid /var/run/omcid.pid /tmp/omcid.pid; do [ -f "$f" ] || continue; p=$(cat "$f" 2>/dev/null); case "$p" in ''|*[!0-9]*) rm -f "$f"; stale=1;; *) kill -0 "$p" 2>/dev/null || { rm -f "$f"; stale=1; };; esac; done
 pidof omci >/dev/null 2>&1 || pidof omcid >/dev/null 2>&1 || need=1
 if [ "$stale" = 1 ]; then need=1; fi
 if [ "$need" = 0 ]; then [ -x /userfs/bin/omci ] && /userfs/bin/omci set reconfig >/dev/null 2>&1 || true; return 0; fi
 log "GPON OMCI 缺失或 pid 残留，执行自愈"; killall omci >/dev/null 2>&1 || true; killall omcid >/dev/null 2>&1 || true; rm -f /var/run/omci.pid /tmp/omci.pid /var/run/omcid.pid /tmp/omcid.pid
 for s in /etc/init.d/omci /etc/init.d/omcid /etc/init.d/xpon; do [ -x "$s" ] || continue; "$s" restart >/dev/null 2>&1 && { started=1; break; }; done
 [ "$started" = 1 ] || for b in /userfs/bin/omci /usr/bin/omci /userfs/bin/omcid /usr/sbin/omcid; do [ -x "$b" ] || continue; "$b" >/dev/null 2>&1 & started=1; break; done
 [ "$started" = 1 ] || log "未找到 GPON OMCI 启动入口"
}

runtime_member(){ [ -e "/sys/class/net/$1/brif/pon.$2" ] && return 0; command -v brctl >/dev/null 2>&1 && brctl show "$1" 2>/dev/null|awk 'NR>1{print $1}'|grep -qx "pon.$2"; }

verify_later(){ (
 trap 'rm -f "$LIST"' EXIT
 sleep 20; [ -s "$LIST" ] || exit 0; local bad=0 rec vid iface mode dev b
 while IFS='|' read -r vid iface mode dev; do
  if [ "$mode" = bridged ]; then b=$dev; [ -n "$b" ] || b=$BRIDGE; runtime_member "$b" "$vid" || bad=1; fi
  if [ "$mode" = routed ]; then for b in /sys/class/net/*/brif/pon.$vid; do [ -e "$b" ] && bad=1; done; fi
 done < "$LIST"; [ "$bad" = 0 ] && exit 0; log "20 秒校验发现运行态与 UCI 不一致，执行 netifd reload"; /etc/init.d/network reload >/dev/null 2>&1 || ubus call network reload >/dev/null 2>&1
 rm -f "$LIST"
 ) >/dev/null 2>&1 & }

main(){ lock; b=$(get xpon.bind_lan.bridge); [ -n "$b" ] && BRIDGE="$b"; apply_binding; /etc/init.d/network reload >/dev/null 2>&1 || ubus call network reload >/dev/null 2>&1; [ "$(pon_tech)" = EPON ] && heal_epon_oam || heal_gpon_omci; verify_later; }
cmd="$1"; [ -n "$cmd" ] || cmd=all; case "$cmd" in all|apply) main;; *) echo "用法: $0 all" >&2; exit 2;; esac
exit 0
