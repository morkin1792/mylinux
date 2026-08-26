#!/usr/bin/env bash
#
# Checks the routing decisions in write_client_conf without touching a real
# WireGuard install: the script is sourced with its final `main "$@"` stripped,
# the paths are pointed at a temp dir, and the generated client .conf files are
# inspected. Run it as a normal user:  ./test-simplewire.sh
#
set -euo pipefail
SRC=$(dirname "$(readlink -f "$0")")/simplewire
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

sed 's/^main "\$@"$/:/' "$SRC" > "$T/sw"
# shellcheck source=/dev/null
. "$T/sw"

WGDIR=$T/wg; KEYDIR=$WGDIR/keys; CLIENTDIR=$WGDIR/clients; WG_CONF=$WGDIR/wg0.conf
mkdir -p "$KEYDIR" "$CLIENTDIR"

SUBNET=10.8.0.0/24; NET_ADDR=10.8.0.0; PREFIX=24; SERVER_IP=10.8.0.1
PORT=443; ALT_PORTS=''; ENDPOINT=vpn.example.com; CLIENT_DNS=1.1.1.1

printf 'srvpub\n' > "$KEYDIR/server.pub"
for n in full split legacy; do printf 'key-%s\n' "$n" > "$KEYDIR/$n.key"; done

cat > "$WG_CONF" <<'EOF'
[Interface]
### BEGIN peer full
[Peer]
# full-tunnel = yes
AllowedIPs = 10.8.0.2/32, fd42:42:42::2/128
### END peer full
### BEGIN peer split
[Peer]
# full-tunnel = no
AllowedIPs = 10.8.0.3/32, fd42:42:42::3/128
### END peer split
### BEGIN peer legacy
[Peer]
AllowedIPs = 10.8.0.4/32, fd42:42:42::4/128
### END peer legacy
EOF

write_client_conf full   10.8.0.2 >/dev/null
write_client_conf split  10.8.0.3 >/dev/null
write_client_conf legacy 10.8.0.4 >/dev/null

get()  { sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$CLIENTDIR/$1.conf"; }
want() { [ "$2" = "$3" ] || { printf 'FAIL %s: %s is "%s", expected "%s"\n' "$1" "$4" "$2" "$3"; exit 1; }; }

# Full tunnel: the VPN is the default gateway, and the pushed resolver applies.
want full "$(get full AllowedIPs)" "0.0.0.0/0, ::/0" AllowedIPs
want full "$(get full DNS)"        "1.1.1.1"         DNS

# Split tunnel: only the tunnel subnet is routed, and DNS is left alone —
# hijacking it would break local names while most traffic stays off the tunnel.
want split "$(get split AllowedIPs)" "10.8.0.0/24" AllowedIPs
want split "$(get split DNS)"        ""            DNS

# A peer block written before the option existed carries no marker and keeps
# behaving exactly as it did: full tunnel.
want legacy "$(get legacy AllowedIPs)" "0.0.0.0/0, ::/0" AllowedIPs

# The tunnel range is an on-link route for every device whatever AllowedIPs
# says — this is what makes device-to-device work on a split-tunnel client.
want full   "$(get full Address)"   "10.8.0.2/24, fd42:42:42::2/128" Address
want split  "$(get split Address)"  "10.8.0.3/24, fd42:42:42::3/128" Address
want legacy "$(get legacy Address)" "10.8.0.4/24, fd42:42:42::4/128" Address

# rebuild_confs regenerates all three from the peer list, and reports a device
# whose key is gone rather than writing a config it cannot complete.
rm -f "$CLIENTDIR"/*.conf
rebuild_confs
want rebuild "$REBUILT" "3" "count"
[ -f "$CLIENTDIR/split.conf" ] || { echo "FAIL rebuild did not write split.conf"; exit 1; }

rm -f "$KEYDIR/legacy.key"
rebuild_confs >/dev/null
want rebuild-missing-key "$REBUILT" "2" "count"

# A split-tunnel device is refused at the server too, so the setting holds even
# on a device that never re-imported its config.
WG_IF=wg0; WAN_IF=eth0
build_rules
rules=$(printf '%s\n' "${RULES[@]}")

grep -q -- '-i wg0 -o eth0 -s 10.8.0.3/32 .* -j REJECT' <<<"$rules" \
    || { echo "FAIL no internet REJECT for the split-tunnel device"; printf '%s\n' "$rules"; exit 1; }
grep -q -- '-s 10.8.0.2/32 .* -j REJECT' <<<"$rules" \
    && { echo "FAIL full-tunnel device got an internet REJECT"; exit 1; }

# apply_rules inserts every rule at position 1, so the REJECT must come LATER in
# the array than the blanket wg0 -> WAN ACCEPT to end up ABOVE it in the chain.
acc=$(grep -n -- '-i wg0 -o eth0 -m comment .* -j ACCEPT' <<<"$rules" | cut -d: -f1)
rej=$(grep -n -- '-s 10.8.0.3/32 .* -j REJECT' <<<"$rules" | cut -d: -f1)
[ -n "$acc" ] && [ -n "$rej" ] && [ "$rej" -gt "$acc" ] \
    || { echo "FAIL REJECT at $rej would sit below the blanket ACCEPT at $acc"; exit 1; }

# It must not fence the device off from the tunnel subnet — only from the WAN.
grep -q -- '-s 10.8.0.3/32 .* -j REJECT' <<<"$(grep -v -- '-o eth0' <<<"$rules")" \
    && { echo "FAIL split-tunnel REJECT is not scoped to the WAN interface"; exit 1; }

# list_peers orders by address, not by position in wg0.conf and not by name.
# The .10 peer is the one that matters: it must land after .4, which a plain
# text sort of the address column gets wrong.
cat >> "$WG_CONF" <<'EOF'
### BEGIN peer laptop
[Peer]
# full-tunnel = yes
AllowedIPs = 10.8.0.10/32, fd42:42:42::a/128
### END peer laptop
EOF
order=$(list_peers | awk '{print $2}' | tr '\n' ' ')
want list-peers "$order" "10.8.0.2 10.8.0.3 10.8.0.4 10.8.0.10 " "address order"

# --- custom gateway ------------------------------------------------------
# 'split' exits through 'full' instead of through this server. Note the routed
# device is the one carrying the marker, and nothing about ITS config changes.
cat > "$WG_CONF" <<'EOF'
[Interface]
ListenPort = 443
### BEGIN peer home
[Peer]
# full-tunnel = no
AllowedIPs = 10.8.0.2/32, fd42:42:42::2/128
### END peer home
### BEGIN peer phone
[Peer]
# full-tunnel = yes
# reach-peers = no
# gateway = 10.8.0.2
AllowedIPs = 10.8.0.3/32, fd42:42:42::3/128
### END peer phone
### BEGIN peer laptop
[Peer]
# full-tunnel = yes
AllowedIPs = 10.8.0.4/32, fd42:42:42::4/128
### END peer laptop
EOF

want gateway "$(gateway_users | tr '\n' ';')" "10.8.0.3 10.8.0.2;" "routed pairs"
want gateway "$(current_gateway)"             "10.8.0.2"           "gateway address"
want gateway "$(peer_by_ip 10.8.0.2)"         "home"               "name for address"

# The gateway peer gets 0.0.0.0/0 so the server will encrypt arbitrary
# destinations to it; nobody else may hold it, or wg silently moves the entry.
reload_wg() { :; }   # no live interface in the test
sync_gateway_routes
want gateway "$(grep -c '^AllowedIPs.*0\.0\.0\.0/0' "$WG_CONF")" "1" "peers holding 0.0.0.0/0"
grep -q '^AllowedIPs = 10.8.0.2/32.*0\.0\.0\.0/0' "$WG_CONF" \
    || { echo "FAIL 0.0.0.0/0 did not go to the gateway peer"; exit 1; }
# wg-quick would turn that /0 into a default route for the whole server.
grep -q '^Table[[:space:]]*=[[:space:]]*off' "$WG_CONF" \
    || { echo "FAIL Table = off was not added to protect the server's own routing"; exit 1; }

# Moving the role must take it off the old holder, not add a second.
sed -i 's/^# gateway = 10.8.0.2/# gateway = 10.8.0.4/' "$WG_CONF"
sync_gateway_routes
want gateway "$(grep -c '^AllowedIPs.*0\.0\.0\.0/0' "$WG_CONF")" "1" "peers holding 0.0.0.0/0 after move"
grep -q '^AllowedIPs = 10.8.0.4/32.*0\.0\.0\.0/0' "$WG_CONF" \
    || { echo "FAIL 0.0.0.0/0 did not move to the new gateway"; exit 1; }
# ...and dropping it entirely must leave nobody holding it.
sed -i '/^# gateway = /d' "$WG_CONF"
sync_gateway_routes
want gateway "$(grep -c '^AllowedIPs.*0\.0\.0\.0/0' "$WG_CONF")" "0" "peers holding 0.0.0.0/0 after clear"

# A routed device that is ALSO isolated still has to reach its gateway. Its
# internet traffic is wg0 -> wg0 with a destination outside the tunnel, which
# the isolation DROP would otherwise eat.
sed -i 's/^# reach-peers = no/# reach-peers = no\n# gateway = 10.8.0.2/' "$WG_CONF"
WG_IF=wg0; WAN_IF=eth0
build_rules
rules=$(printf '%s\n' "${RULES[@]}")
esc=$(grep -n -- '-i wg0 -o wg0 -s 10.8.0.3/32 ! -d 10.8.0.0/24 .* -j ACCEPT' <<<"$rules" | cut -d: -f1)
drop=$(grep -n -- '-i wg0 -o wg0 -s 10.8.0.3/32 -m comment .* -j DROP' <<<"$rules" | cut -d: -f1)
[ -n "$esc" ] && [ -n "$drop" ] && [ "$esc" -gt "$drop" ] \
    || { echo "FAIL gateway escape at $esc does not sit above the isolation DROP at $drop"; exit 1; }

echo "PASS"
