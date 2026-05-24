#!/usr/bin/env bash

set -euo pipefail
ACTION="${1:-up}"

SPINES=(1 2)
LEAVES=(1 2 3 4)

host_subnet() {
	echo "10.0.$1";
}

transit_subnet(){
	echo "10.99.$(($1 * 10 + $2))";
}

prepare_environment(){
	sudo modprobe br_netfilter 2>/dev/null || true
	sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null
	sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null
	sudo sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null

	if sudo iptables -L FORWARD -n | head -1 | grep -q DROP; then
		sudo iptables -P FORWARD ACCEPT
	fi
}

create_node(){
	local name="$1"
	sudo ip netns add "$name"
	sudo ip netns exec "$name" ip link set lo up
}

enable_routing(){
	sudo ip netns exec "$1" sysctl -w net.ipv4.ip_forward=1 > /dev/null
}

link(){
	local ns_a="$1" if_a="$2" ip_a="$3"
	local ns_b="$4" if_b="$5" ip_b="$6"

	sudo ip link add "$if_a" type veth peer name "$if_b"
	sudo ip link set "$if_a" netns "$ns_a"
	sudo ip link set "$if_b" netns "$ns_b"

	sudo ip netns exec "$ns_a" ip addr add "$ip_a" dev "$if_a"
	sudo ip netns exec "$ns_b" ip addr add "$ip_b" dev "$if_b"

	sudo ip netns exec "$ns_a" ip link set "$if_a" up
	sudo ip netns exec "$ns_b" ip link set "$if_b" up
}

up(){
	echo "[+] Preparing environment..."
	prepare_environment

	echo "[+] Crearing namesapces (${#SPINES[@]} spines, ${#LEAVES[@]} leaves, ${#LEAVES[@]} hosts...)"
	for s in "${SPINES[@]}"; do create_node "spine$s" enable_routing "spine$s"; done
	for l in "${LEAVES[@]}"; do create_node "leaf$l" enable_routing "leaf$l"; done
	for l in "${LEAVES[@]}"; do create_node "h$l"; done

	echo "[+] Connecting hosts to leaves..."
	for l in "${LEAVES[@]}"; do
		local sub
		sub=$(host_subnet "$l")
		link "h$l" "h$l-eth0" "$sub.10/24" \
			"leaf$l" "l$l-h" "$sub.1/24"
		sudo ip netns exec "h$l" ip route add default via "$sub.1"
	done

	echo "[+] Building spine-leaf full mesh (${#SPINES[@]}x${#LEAVES[@]} = $((${#SPINES[@]} * ${#LEAVES[@]})) links)..."
	for s in "${SPINES[@]}"; do
		for l in "${LEAVES[@]}"; do
			local tsub
				tsub=$(transit_subnet "$s" "$l")
				link "spine$s" "s$s-l$l" "$tsub.1/30" \
				"leaf$l" "l$l-s$s" "$tsub.2/30"
		done
	done

	echo "[+] Configuring routing on spines..."

	for s in "${SPINES[@]}"; do
		for l in "${LEAVES[@]}"; do
			local hsub tsub
			hsub=$(host_subnet "$l")
			tsub=$(transit_subnet "$s" "$l")
			sudo ip netns exec "spine$s" \
				ip route add "$hsub.0/24" via "$tsub.2"
		done
	done

	echo "[+] Configuring ECMP routing on leaves..."
	for src_l in "${LEAVES[@]}"; do
		for dst_l in "${LEAVES[@]}"; do
			[ "$src_l" = "$dst_l" ] && continue
			local dst_sub
			dst_sub=$(host_subnet "$dst_l")

			local cmd=(sudo ip netns exec "leaf$src_l" ip route add "$dst_sub.0/24")
			for s in "${SPINES[@]}"; do
				local tsub
				tsub=$(transit_subnet "$s" "$src_l")
				cmd+=(nexthop via "$tsub.1" dev "l$src_l-s$s")
			done
			"${cmd[@]}"
		done
	done

	echo ""
	echo "[v] Spine-Leaf fabric is UP!"
	echo ""
	echo "Try:"
	echo " $0 verify	#All-to-all connectivity"
	echo " $0 ecmp		# See ECMP in action"
	echo " sudo ip netns exec h1 traceroute -n 10.0.4.10"
	echo " sudo ip netns exec leaf1 ip route"
}

down(){
	echo "[-] Tearing down..."
	for s in "${SPINES[@]}"; do sudo ip netns delete "spine$s" 2>/dev/null || true; done
	for l in "${LEAVES[@]}"; do sudo ip netns delete "leaf$l" 2>/dev/null || true; done
	for l in "${LEAVES[@]}"; do sudo ip netns delete "h$l" 2>/dev/null || true; done
	echo "[v] Cleaned up"
}

verify(){
	echo "[?] Connectivity matrix (12 corss-leaf pings):"
	local fail=0
	for src in "${LEAVES[@]}"; do
		for dst in "${LEAVES[@]}"; do
			[ "$src" = "$dst" ] && continue
			local dst_ip="10.0.$dst.10"
			if sudo ip netns exec "h$src" ping -c 1 -w 2 "$dst_ip" &>/dev/null; then
				echo "	[v] h$src -> h$dst"
			else
				echo "	[x] h$src -> h$dst"
				fail=$((fail+1))
			fi
		done
	done

	echo ""
	[ "$fail" -eq 0 ] && echo "[v] All 12 pings passed!" \
	|| echo "[x] $fail pings failed."

	echo ""
	echo "[?] Sample routing table (leaf1) - notice ECMP nexthops:"
	sudo ip netns exec leaf1 ip route | sed 's/^/	/'
}

ecmp_demo(){
	echo "[?] ECMP demonstration: sending 150 flows from h1 to h2, h3, h4..."
	echo "	(each flow is a separate ping = different src port = different hash)"
	echo ""

	declare -A before_tx
	for s in "${SPINES[@]}"; do
		before_tx[$s]=$(sudo ip netns exec "leaf1" \
			cat "/sys/class/net/l1-s$s/statistics/tx_packets")
	done

	for dst in 2 3 4; do
		for i in $(seq 1 50); do
			sudo ip netns exec "h1" \
				ping -c 1 -w 1 "10.0.$dst.10" &>/dev/null &
		done
	done

	wait

	echo "Traffic distribution from leaf1 to spines:"
	local total=0
	declare -A delta
	for s in "${SPINES[@]}"; do
		local now
		now=$(sudo ip netns exec "leaf1" \
				cat "/sys/class/net/l1-s$s/statistics/tx_packets")
		delta[$s]=$((now - before_tx[$s]))
		total=$((total + delta[$s]))
	done

	for s in "${SPINES[@]}"; do
		local pct=0
		[ "$total" -gt 0 ] && pct=$((delta[$s] * 100 / total))
		printf "	via spine%d: %4d packets (%d%%)\n" "$s" "${delta[$s]}" "$pct"
	done

	echo ""
	echo "[i] If balanced ~50/50, ECMP is hashing flows across both spines."
	echo "	Same flow always takes same path (per-flow ECMP, not per-packet)."

}

case "$ACTION" in
	up)		up ;;
	down)	down ;;
	verify)	verify ;;
	ecmp)	ecmp_demo ;;
	*)		echo "Usage: $0 {up|down|verify|ecmp}"; exit 1 ;;
esac


