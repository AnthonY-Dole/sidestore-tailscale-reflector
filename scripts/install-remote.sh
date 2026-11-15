#!/bin/sh
# Reinstalls /tmp/sidestore-reflector_*.ipk on the router and reports the state.
# Usage: scp -O dist/*.ipk slate7:/tmp/ && ./scripts/remote.sh scripts/install-remote.sh
set -e

echo "===== 1. reinstall ====="
opkg install --force-reinstall /tmp/sidestore-reflector_*.ipk 2>&1 |
	grep -v 'unknown option\|not supported by fw4\|unreachable path\|Automatically including'

echo
echo "===== 2. configuration ====="
uci -q get sidestore-reflector.main.enforce_no_snat >/dev/null 2>&1 ||
	uci set sidestore-reflector.main.enforce_no_snat='1'
uci set sidestore-reflector.main.enabled='1'
uci commit sidestore-reflector
rm -f /etc/config/sidestore-reflector-opkg
uci show sidestore-reflector

echo
echo "===== 3. restart ====="
/etc/init.d/sidestore-reflector enable
/etc/init.d/sidestore-reflector restart
sleep 5
/etc/init.d/sidestore-reflector status

echo
echo "===== 4. state ====="
ps w | grep '[s]idestore-reflector' | sed 's/^/  /'
ip -br link show sidestore
ip route get 10.7.0.1 | head -1
echo "--- nft table (counters) ---"
nft -a list table ip sidestore_reflector 2>/dev/null
echo "--- fw4 ---"
nft list chain inet fw4 forward 2>/dev/null | grep -i sidestore

echo
echo "===== 5. tailscale ====="
tailscale debug prefs 2>/dev/null | grep -E 'NoSNAT' | sed 's/^/  /'
echo "--- ts-postrouting ---"
nft list table ip nat 2>/dev/null | sed -n '/ts-postrouting/,/}/p' | sed 's/^/  /'

echo
echo "===== 6. logs ====="
logread 2>/dev/null | grep -i sidestore | tail -8
