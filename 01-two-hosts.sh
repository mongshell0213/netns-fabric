#!/usr/bin/env bash
# 01-two-hosts.sh: 가장 단순한 토폴로지 - h1과 h2를 veth로 직접 연결
#
#   ┌────┐        ┌────┐
#   │ h1 ●────────● h2 │
#   └────┘        └────┘
#  10.0.0.1/24  10.0.0.2/24

set -euo pipefail

ACTION="${1:-up}"

up(){
	echo "[+] Creating namespaces h1, h2..."
	sudo ip netns add h1
	sudo ip netns add h2

	echo "[+] Creating veth pair..."
	sudo ip link add h1-eth0 type veth peer name h2-eth0

	echo "[+] Moving veth ends into namespaces..."
	sudo ip link set h1-eth0 netns h1
	sudo ip link set h2-eth0 netns h2

	echo "[+] Assigning IPs..."
	sudo ip netns exec h1 ip addr add 10.0.0.1/24 dev h1-eth0
	sudo ip netns exec h2 ip addr add 10.0.0.2/24 dev h2-eth0

	echo "[+] Bringing interfaces up..."
	for ns in h1 h2; do
		sudo ip netns exec "$ns" ip link set lo up
		sudo ip netns exec "$ns" ip link set "${ns}-eth0" up
	done

	echo "[v] Toplology is up!"
	echo ""
	echo "Try: sudo ip netns exec h1 ping -c 3 10.0.0.2"
}

down(){
	echo "[-] Tearing down..."
	sudo ip netns delete h1 2>/dev/null || true
	sudo ip netns delete h2 2>/dev/null || true
	echo "[v] Cleaned up."
}

case "$ACTION" in
	up) up ;;
	down) down ;;
	*) echo "Usage: $0 {up|down}"; exit 1 ;;
esac
