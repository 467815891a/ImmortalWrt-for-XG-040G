#!/bin/sh
# Export the plain-text DSD factory partition as a sourceable shell file.

DSD=/usr/sbin/gtk_dsd
OUT=/tmp/dsd.env
TMP=/tmp/dsd.env.$$

[ -x "$DSD" ] || exit 1
umask 077
: > "$TMP" || exit 1

for key in admin_password admin_username wan_mac lan_mac serial_number clei_code fsan manufacturer acDisable dcDisable; do
	value=$($DSD get "$key" 2>/dev/null) || continue
	[ -n "$value" ] || continue
	escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
	printf "%s='%s'\n" "$key" "$escaped" >> "$TMP"
done

if grep -q "^fsan='" "$TMP"; then
	mv "$TMP" "$OUT"
	exit 0
fi

rm -f "$TMP"
exit 1
