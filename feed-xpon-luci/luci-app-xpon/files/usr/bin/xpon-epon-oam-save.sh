#!/bin/sh
# Notify stock epon_oam that a TCAPI_SAVE/update-config event occurred.
# This is not, by itself, a Flash/NVRAM write. The durable project-owned
# source is /etc/config/xpon; boot-time replay restores the OAM runtime.
# libepon.h: ftok(/tmp/epon_oam/epon_oam_cmd_queue, 10), cmdType=24.

HELPER=/usr/libexec/xpon-epon-oam-tcapi-save
QUEUE=/tmp/epon_oam/epon_oam_cmd_queue

[ -x "$HELPER" ] || { echo "EPON OAM 原厂同步工具不可用：$HELPER" >&2; exit 127; }
[ -e "$QUEUE" ] || { echo "EPON OAM 队列未就绪：$QUEUE" >&2; exit 1; }

"$HELPER"
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "EPON OAM TCAPI_SAVE/update-config 通知发送失败，exit_code=$rc" >&2
	exit "$rc"
fi

logger -t xpon "EPON OAM 原厂 TCAPI_SAVE/update-config 通知已发送（cmdType=24；不代表持久写入）"
exit 0
