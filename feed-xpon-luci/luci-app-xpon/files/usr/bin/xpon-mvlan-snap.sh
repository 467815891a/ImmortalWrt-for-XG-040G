#!/bin/sh
# xpon-mvlan-snap.sh —— 快照驱动实际登记的组播 M-VLAN 白名单到 /tmp/xpon-mvlan-act.txt
#
# 仅供 LuCI 只读展示（mode 页“驱动实际登记”、status 页诊断），LuCI 本身绝不直接调
# xponigmpcmd。由 xpon-app 开机、xpon-mvlan.sh 重放后、以及 mode 页添加/删除组播后
# 后台调用；xponigmpcmd 一律 timeout，防止 ioctl 阻塞拖死调用方（即使 D 状态，
# 也只影响这个后台快照进程，不影响 uhttpd）。

IGMP=/userfs/bin/xponigmpcmd
OUT=/tmp/xpon-mvlan-act.txt

: > "$OUT"
[ -x "$IGMP" ] || { echo "xponigmpcmd missing" > "$OUT"; exit 0; }

SHOW=$(timeout 2 "$IGMP" mvlan show 2>/dev/null)
CNT=$(printf '%s\n' "$SHOW" | awk '$2 ~ /^[0-9]+$/ {n++} END {print n+0}')
echo "cnt=$CNT" > "$OUT"
printf '%s\n' "$SHOW" | awk '$2 ~ /^[0-9]+$/ {print "idx=" n++ " vlan=" $2}' >> "$OUT"

exit 0
