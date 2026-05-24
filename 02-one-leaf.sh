#!/usr/bin/env bash
# 02-one-leaf.sh: 한 leaf 스위치에 호스트 4대
#
#                ┌──────────┐
#                │ br-leaf1 │
#                └─┬──┬──┬──┬─┘
#                  │  │  │  │
#                ┌─┴┐┌┴┐┌┴┐┌┴─┐
#                │h1││h2││h3││h4│
#                └──┘└─┘└─┘└──┘
#              10.0.10.{1,2,3,4}/24

set -euo pipefail

ACTION="${1:-up}"

BRIDGE="br-leaf1"
SUBNET="10.0.10"
HOSTS=(1 2 3 4)

up() {
	echo "[+] Configuring bridge netfilter..."
    sudo modprobe br_netfilter 2>/dev/null || true
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null
    sudo sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null
	

	# Docker가 깔려있으면 FORWARD 체인이 DROP일 수 있음
    if sudo iptables -L FORWARD -n | head -1 | grep -q DROP; then
        echo "[+] Adding FORWARD rules for $BRIDGE..."
        sudo iptables -I FORWARD -i "$BRIDGE" -j ACCEPT
        sudo iptables -I FORWARD -o "$BRIDGE" -j ACCEPT
    fi

	echo "[+] Creating bridge $BRIDGE..."
	sudo ip link add "$BRIDGE" type bridge
	sudo ip link set "$BRIDGE" up

	echo "[+] Creating ${#HOSTS[@]} hosts and connecting to bridge..."
	for i in "${HOSTS[@]}"; do
		sudo ip netns add "h$i"
		sudo ip link add "h$i-eth0" type veth peer name "h$i-br"
		sudo ip link set "h$i-eth0" netns "h$i"
		sudo ip link set "h$i-br" master "$BRIDGE"
		sudo ip link set "h$i-br" up

		sudo ip netns exec "h$i" ip addr add "$SUBNET.$i/24" dev "h$i-eth0"
		sudo ip netns exec "h$i" ip link set "h$i-eth0" up
		sudo ip netns exec "h$i" ip link set lo up
	done

	echo "[v] Topology is up!"
    echo ""
    echo "Verification commands:"
    echo "  bridge link show"
    echo "  bridge fdb show br $BRIDGE"
    echo "  sudo ip netns exec h1 ping -c 2 $SUBNET.4"
}

down() {
	echo "[-] Tearing down..."
	# iptables 규칙 제거 (있다면)
    sudo iptables -D FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -o "$BRIDGE" -j ACCEPT 2>/dev/null || true

	for i in "${HOSTS[@]}"; do
		sudo ip netns delete "h$i" 2>/dev/null || true
	done
	sudo ip link delete "$BRIDGE" 2>/dev/null || true
	echo "[v] Cleaned up"
}

verify(){
	 echo "[?] Running connectivity matrix..."
    local fail=0
    for src in "${HOSTS[@]}"; do
        for dst in "${HOSTS[@]}"; do
            [ "$src" = "$dst" ] && continue
            if sudo ip netns exec "h$src" ping -c 1 -W 1 "$SUBNET.$dst" &>/dev/null; then
                echo "  [v] h$src -> h$dst"
            else
                echo "  [x] h$src -> h$dst FAILED"
                fail=$((fail+1))
            fi
        done
    done
    [ "$fail" -eq 0 ] && echo "[v] All $((${#HOSTS[@]} * (${#HOSTS[@]}-1))) pings passed!" \
                     || echo "[x] $fail pings failed."
}

case "$ACTION" in
    up)     up ;;
    down)   down ;;
    verify) verify ;;
    *)      echo "Usage: $0 {up|down|verify}"; exit 1 ;;
esac

