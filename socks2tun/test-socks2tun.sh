#!/usr/bin/env bash
#
# Checks default_route's choices without root, a VPN or dante: re-execs itself in
# a private network namespace (unshare -rn), builds a veth (ethernet) and a tun
# (point-to-point) in there, sources socks2tun with its `main "$@"` stripped
# and asserts the routing decisions made for each.  Run as a normal user: ./test-socks2tun.sh
#
set -euo pipefail
SRC=$(dirname "$(readlink -f "$0")")/socks2tun

[ "${IN_NETNS:-}" ] || exec unshare -rn env IN_NETNS=1 "$0"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed 's/^main "\$@"$/:/' "$SRC" > "$T/s2t"
# shellcheck source=/dev/null
. "$T/s2t"

ip link add veth0 type veth peer name veth1
ip addr add 10.99.0.2/24 dev veth0
ip link set veth0 up; ip link set veth1 up
ip route add default via 10.99.0.1 dev veth0

ip tuntap add mode tun tun9
ip addr add 10.8.0.2/24 dev tun9
ip link set tun9 up

check() { [ "$2" = "$3" ] || { echo "FAIL $1: got '$2' want '$3'"; exit 1; }; echo "ok: $1"; }

check "ethernet reuses its own gateway" "$(default_route veth0)"           "default via 10.99.0.1 dev veth0"
check "explicit -g wins"                "$(default_route veth0 10.99.0.9)" "default via 10.99.0.9 dev veth0"
check "tunnel routes on-link"           "$(default_route tun9)"            "default dev tun9"

check "no forcing needed when the box already defaults out the interface" \
      "$(needs_policy_routing veth0 && echo yes || echo no)" "no"
check "forcing needed for an interface that isn't the default path" \
      "$(needs_policy_routing tun9 && echo yes || echo no)" "yes"

ip route del default
if (default_route veth0) 2>/dev/null; then
    echo "FAIL: a gatewayless ethernet link must be refused, not routed on-link"; exit 1
fi
echo "ok: gatewayless ethernet refused"
