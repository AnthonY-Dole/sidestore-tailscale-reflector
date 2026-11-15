#!/bin/sh
# Starts the reflector, sets up the TUN device, the NAT redirection and the
# supervision loop. Called by /etc/init.d/sidestore-reflector through procd.
#
# Two modes:
#   node   : SideStore (Remote Endpoint) connects to the router's Tailscale IP.
#            That IP is DNATed to the reflected address, then SNATed on the
#            way back.
#   direct : the device connects straight to the reflected address (/32 route).
#
# Forwarding for the TUN interface is allowed by
# /usr/share/nftables.d/chain-pre/forward/30-sidestore-reflector.nft (fw4).
# That file hardcodes the interface name "sidestore": TUN_NAME must not change.

. /lib/functions.sh

BIN=/usr/sbin/sidestore-reflector
TUN_NAME=sidestore
NFT_TABLE=sidestore_reflector
WAIT_UPLINK=30

log() { logger -t sidestore-reflector -- "$*"; }

config_load sidestore-reflector
config_get reflect_ip   main reflect_ip   10.7.0.1
config_get uplink_iface main uplink_iface tailscale0
config_get mode         main mode         node
config_get node_addr    main node_addr    auto
config_get dnat_ports   main dnat_ports   "62078, 49152-65535"
config_get_bool enforce_no_snat main enforce_no_snat 1

nft_added=0
pid=

cleanup() {
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	[ "$nft_added" = "1" ] && nft delete table ip "$NFT_TABLE" 2>/dev/null
	nft_added=0
}
trap cleanup EXIT INT TERM

wait_uplink() {
	i=0
	while [ "$i" -lt "$WAIT_UPLINK" ]; do
		[ -e "/sys/class/net/$uplink_iface" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

resolve_node_addr() {
	[ "$node_addr" != "auto" ] && return 0

	node_addr=$(tailscale ip -4 2>/dev/null | head -n1)
	[ -n "$node_addr" ] || node_addr=$(ip -4 -o addr show dev "$uplink_iface" 2>/dev/null |
		awk '{print $4}' | cut -d/ -f1 | head -n1)
	[ -n "$node_addr" ]
}

# Tailscale masquerades packets arriving on tailscale0: the source is replaced
# by the node address BEFORE the reflector sees them, so the reflected packet
# goes back to the router itself (the router answers RST and the SideStore
# Health Check stays red). This is the pitfall documented by the reference
# project (--snat-subnet-routes=false). Disable it when needed.
ensure_no_snat() {
	[ "$mode" = "node" ] || return 0
	[ "$enforce_no_snat" = "1" ] || return 0
	command -v tailscale >/dev/null 2>&1 || return 0

	tailscale debug prefs 2>/dev/null |
		grep -q '"NoSNAT":[[:space:]]*true' && return 0

	log "Tailscale SNAT is active: disabling it (required by the reflector)"
	tailscale set --snat-subnet-routes=false >/dev/null 2>&1 || {
		log "failed to run 'tailscale set --snat-subnet-routes=false'"
		return 1
	}

	tailscale debug prefs 2>/dev/null |
		grep -q '"NoSNAT":[[:space:]]*true' && return 0

	log "NoSNAT still missing after the command"
	return 1
}

setup_nat() {
	[ "$mode" = "node" ] || return 0
	command -v nft >/dev/null 2>&1 || { log "nft not found"; return 1; }

	nft delete table ip "$NFT_TABLE" 2>/dev/null

	if nft -f - <<EOF
table ip $NFT_TABLE {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
$(if [ -n "$dnat_ports" ]; then
	printf '\t\tiifname "%s" ip daddr %s tcp dport { %s } counter dnat to %s\n' "$uplink_iface" "$node_addr" "$dnat_ports" "$reflect_ip"
	printf '\t\tiifname "%s" ip daddr %s udp dport { %s } counter dnat to %s\n' "$uplink_iface" "$node_addr" "$dnat_ports" "$reflect_ip"
else
	printf '\t\tiifname "%s" ip daddr %s counter dnat to %s\n' "$uplink_iface" "$node_addr" "$reflect_ip"
fi)
	}
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "$uplink_iface" ip saddr $reflect_ip counter snat to $node_addr
	}
}
EOF
	then
		nft_added=1
		log "NAT active: $node_addr ports ${dnat_ports:-all} -> $reflect_ip"
	else
		nft delete table ip "$NFT_TABLE" 2>/dev/null
		log "failed to load the nft table"
		return 1
	fi
}

if ! wait_uplink; then
	log "interface $uplink_iface missing after ${WAIT_UPLINK}s"
	exit 1
fi

if [ "$mode" = "node" ]; then
	resolve_node_addr || { log "node address not found"; exit 1; }
	log "node $node_addr -> reflect $reflect_ip"
	ensure_no_snat
fi

"$BIN" "$TUN_NAME" "$reflect_ip" &
pid=$!

i=0
while [ "$i" -lt 5 ]; do
	[ -e "/sys/class/net/$TUN_NAME" ] && break
	kill -0 "$pid" 2>/dev/null || break
	sleep 1
	i=$((i + 1))
done

if [ ! -e "/sys/class/net/$TUN_NAME" ]; then
	log "TUN $TUN_NAME was not created, stopping"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	exit 1
fi

ip link set dev "$TUN_NAME" up
ip route add "$reflect_ip/32" dev "$TUN_NAME" 2>/dev/null ||
	ip route change "$reflect_ip/32" dev "$TUN_NAME" 2>/dev/null

sysctl -qw net.ipv4.ip_forward=1
setup_nat

log "active: $TUN_NAME, $reflect_ip/32 (mode=$mode)"

wait "$pid"
exit $?
