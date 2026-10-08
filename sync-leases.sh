#!/bin/sh
# Publish DHCP lease hostnames to Pi-hole so the clients table shows names.
# kresd (port 53) does not serve lease names and dnsmasq here is DHCP-only, so we
# turn /tmp/dhcp.leases into an addn-hosts file and SIGHUP FTL when it changes.
# Run from cron (see SETUP.md): * * * * * /srv/docker/pihole/sync-leases.sh
set -eu

DIR="${PIHOLE_DATA_DIR:-/srv/docker/pihole}/etc-dnsmasq.d"
OUT="$DIR/leases.hosts"
TMP="$OUT.tmp"

mkdir -p "$DIR"
# lease format: expiry mac ip hostname clientid ; skip nameless ("*") leases
awk '$4 != "*" && $4 != "" { print $3, $4 }' /tmp/dhcp.leases | sort > "$TMP"

if ! cmp -s "$TMP" "$OUT" 2>/dev/null; then
  mv "$TMP" "$OUT"
  docker exec pihole pkill -HUP pihole-FTL 2>/dev/null || true
else
  rm -f "$TMP"
fi
