#!/usr/bin/env bash

set -euo pipefail
ACTION="${1:-up}"

LEAF1_BRIDGE="br-leaf1"
LEAF1_SUBNET="10.0.10"
LEAF1_HOSTS=(1 2)
LEAF1_GW=254

LEAF2_BRIDGE="br-leaf2"
LEAF2_SUBNET="10.0.20"
LEAF2_HOSTS=(3 4)
LEAF2_GW=254

ROUTER="router-ns"
ALL_HOSTS=(1 2 3 4)

prepare_environment() {
	sudo modprobe br_netfilter 2>/dev/null || true
	sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null
	sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null
	sudo sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null

	if sudo iptables -L FORWARD -n | head -1 | grep -q DROP; then
		for br in "$LEAF1_BRIDGE" "$LEAF2_BRIDGE"; do
			sudo iptables -I FORWARD -i "$br" -j ACCEPT 2>/dev/null || true
			sudo iptables -I FORWARD -o "$br" -j ACCEPT 2>/dev/null || true
		done
	fi
}

create_leaf(){
	local bridge="$1"
	local subnet="$2"
	local gw="$3"
	shift 3
	local hosts=("$@")

	sudo ip link add "$bridge" type bridge
	sudo ip link set "$bridge" up

	for i in "${hosts[@]}"; do
		sudo ip netns add "h$i"
		sudo ip link add "h$i-eth0" type veth peer name "h$i-br"
		sudo ip link set "h$i-eth0" netns "h$i"
		sudo ip link set "h$i-br" master "$bridge"
		sudo ip link set "h$i-br" up

		sudo ip netns exec "h$i" ip addr add "$subnet.$i/24" dev "h$i-eth0"
		sudo ip netns exec "h$i" ip link set "h$i-eth0" up
		sudo ip netns exec "h$i" ip link set lo up

		sudo ip netns exec "h$i" ip route add default via "$subnet.$gw"
	done
}

connect_router_to_leaf(){
	local leaf_name="$1"
	local bridge="$2"
	local gw_ip="$3"

	sudo ip link add "r-$leaf_name" type veth peer name "$leaf_name-r"
	sudo ip link set "r-$leaf_name" netns "$ROUTER"
	sudo ip link set "$leaf_name-r" master "$bridge"
	sudo ip link set "$leaf_name-r" up

	sudo ip netns exec "$ROUTER" ip addr add "$gw_ip/24" dev "r-$leaf_name"
	sudo ip netns exec "$ROUTER" ip link set "r-$leaf_name" up
}

up(){
	echo "[+] Preparing environment..."
	prepare_environment

	echo "[+] Creating router namespace..."
	sudo ip netns add "$ROUTER"
	sudo ip netns exec "$ROUTER" ip link set lo up

	echo "[+] Creating leaf 1 ($LEAF1_BRIDGE, $LEAF1_SUBNET.0/24)..."
	create_leaf "$LEAF1_BRIDGE" "$LEAF1_SUBNET" "$LEAF1_GW" "${LEAF1_HOSTS[@]}"

	echo "[+] Creating leaf 2 ($LEAF2_BRIDGE, $LEAF2_SUBNET.0/24)..."
	create_leaf "$LEAF2_BRIDGE" "$LEAF2_SUBNET" "$LEAF2_GW" "${LEAF2_HOSTS[@]}"

	echo "[+] Connecting router to both leaves..."
	connect_router_to_leaf "leaf1" "$LEAF1_BRIDGE" "$LEAF1_SUBNET.$LEAF1_GW"
	connect_router_to_leaf "leaf2" "$LEAF2_BRIDGE" "$LEAF2_SUBNET.$LEAF2_GW"

	echo "[+] Enabling IP forwarding in router..."
	sudo ip netns exec "$ROUTER" sysctl -w net.ipv4.ip_forward=1 >/dev/null

	echo "[v] Topology is up!"
	echo ""
	echo "Try cross-subnet ping:"
	echo "	sudo ip netns exec h1 ping -c 2 10.0.20.3"
	echo "	sudo ip netns exec h1 traceroute 10.0.20.4"
}

down(){
	echo "[-] Tearing down..."
	
	for br in "$LEAF1_BRIDGE" "$LEAF2_BRIDGE"; do
		sudo iptables -D FORWARD -i "$br" -j ACCEPT 2>/dev/null || true
		sudo iptables -D FORWARD -o "$br" -j ACCEPT 2>/dev/null || true
	done

	for i in "${ALL_HOSTS[@]}"; do
		sudo ip netns delete "h$i" 2>/dev/null || true
	done
	sudo ip netns delete "$ROUTER" 2>/dev/null || true

	sudo ip link delete "$LEAF1_BRIDGE" 2>/dev/null || true
	sudo ip link delete "$LEAF2_BRIDGE" 2>/dev/null || true

	echo "[v] Cleaned up."
}

verify(){
	echo "[?] Running connectivity matrix..."
	local fail=0

	declare -A HOST_IP=(
		[1]="$LEAF1_SUBNET.1"
		[2]="$LEAF1_SUBNET.2"
		[3]="$LEAF2_SUBNET.3"
		[4]="$LEAF2_SUBNET.4"
	)

	for src in "${ALL_HOSTS[@]}"; do
		for dst in "${ALL_HOSTS[@]}"; do
			[ "$src" = "$dst" ] && continue
			local dst_ip="${HOST_IP[$dst]}"
			if sudo ip netns exec "h$src" ping -c 1 -W 1 "$dst_ip" &>/dev/null; then
				local marker="(L2)"
				if [[ "$src" -le 2 && "$dst" -gt 2 ]] || [[ "$src" -gt 2 && "$dst" -le 2 ]]; then
					marker="(L3)"
				fi
				echo "	[v] h$src -> h$dst $marker"
			else
				echo "	[x] h$src -> h$dst FAILED"
				fail=$((fail+1))
			fi
		done
	done

	[ "$fail" -eq 0 ] && echo "[v] All 12 pings passed !" \
					|| echo "[x] $fail pings failed."
}

case "$ACTION" in
	up)		up ;;
	down)	down ;;
	verify)	verify ;;
	*)		echo "Usage: $0 {up|down|verify}"; exit 1 ;;
esac

