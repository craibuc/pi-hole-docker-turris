#!/usr/bin/env bash
# Deploy Pi-hole to a Turris/OpenWrt router and apply the firewall changes it needs.
# Idempotent: safe to re-run. See SETUP.md for the manual steps and TROUBLESHOOTING.md for why.
#
# Usage: ./deploy.sh            (HOST=router REMOTE_DIR=/srv/docker/pihole by default)
#        HOST=myrouter ./deploy.sh
set -euo pipefail

HOST="${HOST:-router}"
REMOTE_DIR="${REMOTE_DIR:-/srv/docker/pihole}"
DNS_PORT=5354
UI_PORT=8080

cd "$(dirname "$0")"
ssh_r() { ssh -o ClearAllForwardings=yes "$HOST" "$@"; }
step() { printf '\n==> %s\n' "$*"; }

step "Preflight"
[[ -f docker-compose.yaml && -f .env ]] || { echo "docker-compose.yaml and .env must exist here" >&2; exit 1; }
ssh_r 'docker compose version >/dev/null && uci -q show firewall >/dev/null' \
  || { echo "cannot reach $HOST, or docker/uci missing" >&2; exit 1; }

step "Back up router config to ./backup-<timestamp>/ (contains .env; git-ignored)"
backup="backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
ssh_r "mkdir -p $REMOTE_DIR"   # fresh router: the dir must exist or tar exits non-zero
ssh_r "tar czf - /etc/config/firewall /etc/config/dhcp /etc/config/network /etc/config/dockerd $REMOTE_DIR 2>/dev/null" > "$backup/router-config.tgz"
cp docker-compose.yaml .env "$backup/"
echo "saved $backup/"

step "Apply firewall changes on the router (idempotent)"
# Runs under the router's ash, so no bashisms below.
ssh_r 'sh -s' <<'REMOTE'
set -eu

# Does a section of the given type exist with all the given option=value pairs?
# usage: has_section forwarding src=docker dest=wan
has_section() {
  type="$1"; shift
  uci show firewall | awk -v t="$type" -v want="$*" '
    BEGIN { n = split(want, w, " ") }
    $0 ~ "=" t "$" { split($0, a, "="); cur = a[1]; next }
    cur != "" && index($0, cur ".") == 1 {
      for (i = 1; i <= n; i++) { split(w[i], kv, "="); if ($0 == cur "." kv[1] "=\x27" kv[2] "\x27") seen[i] = 1 }
    }
    END { for (i = 1; i <= n; i++) if (!seen[i]) exit 1 }'
}

changed=0

# 1. Containers on docker0 may reach the internet (needed for gravity/blocklists).
if has_section forwarding src=docker dest=wan; then
  echo "firewall: docker -> wan forwarding already present"
else
  uci add firewall forwarding >/dev/null
  uci set firewall.@forwarding[-1].src='docker'
  uci set firewall.@forwarding[-1].dest='wan'
  echo "firewall: added docker -> wan forwarding"; changed=1
fi

# 2. Legacy from the bridge setup (Pi-hole now uses host networking, so this rule is unused);
#    kept so existing routers and rollbacks to a bridge setup keep working.
if has_section rule name=Allow-LAN-to-Pihole; then
  echo "firewall: Allow-LAN-to-Pihole rule already present"
else
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Allow-LAN-to-Pihole'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest='docker'
  uci set firewall.@rule[-1].proto='tcp udp'
  uci set firewall.@rule[-1].dest_port='53 80 443'
  uci set firewall.@rule[-1].target='ACCEPT'
  echo "firewall: added Allow-LAN-to-Pihole rule"; changed=1
fi

# 2b. Redirect LAN DNS (port 53) to Pi-hole's port 5354 (host network). Scoped to src=lan so Pi-hole's own
#     upstream queries to kresd (127.0.0.1:53, not from lan) are not looped back to itself.
if has_section redirect name=LAN-DNS-to-Pihole; then
  echo "firewall: LAN-DNS-to-Pihole redirect already present"
else
  uci add firewall redirect >/dev/null
  uci set firewall.@redirect[-1].name='LAN-DNS-to-Pihole'
  uci set firewall.@redirect[-1].src='lan'
  uci set firewall.@redirect[-1].proto='tcp udp'
  uci set firewall.@redirect[-1].src_dport='53'
  uci set firewall.@redirect[-1].dest_port='5354'
  uci set firewall.@redirect[-1].target='DNAT'
  echo "firewall: added LAN-DNS-to-Pihole redirect (53 -> 5354)"; changed=1
fi
[ "$changed" = 1 ] && { uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1; echo "firewall: reloaded"; }

# 3. dockerd blocks wan -> docker0 with a blanket REJECT, which also rejects replies to the
#    containers' own outbound traffic. Restrict it to NEW connections (persisted for reboots).
want='-m conntrack --ctstate NEW'
if [ "$(uci -q get dockerd.firewall.extra_iptables_args || true)" != "$want" ]; then
  uci set dockerd.firewall.extra_iptables_args="$want"
  uci commit dockerd
  echo "dockerd: set extra_iptables_args (persists across reboots)"
fi
# ...and make the live rule match without restarting dockerd (which would bounce other containers).
if ! iptables -C DOCKER-USER -i eth2 -o docker0 -m conntrack --ctstate NEW -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
  iptables -D DOCKER-USER -i eth2 -o docker0 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
  iptables -I DOCKER-USER 1 -i eth2 -o docker0 -m conntrack --ctstate NEW -j REJECT --reject-with icmp-port-unreachable
  echo "iptables: DOCKER-USER now rejects only NEW wan -> docker0 connections"
fi
REMOTE

step "Copy compose files and (re)start Pi-hole"
ssh_r "mkdir -p $REMOTE_DIR && [ -f $REMOTE_DIR/docker-compose.yaml ] && cp $REMOTE_DIR/docker-compose.yaml $REMOTE_DIR/docker-compose.yaml.bak || true"
scp -q -o ClearAllForwardings=yes docker-compose.yaml .env sync-leases.sh "$HOST:$REMOTE_DIR/"

step "Client names: lease -> hosts sync (addn-hosts config + cron, idempotent)"
ssh_r "sh -s" <<REMOTE
set -eu
cd $REMOTE_DIR
mkdir -p etc-dnsmasq.d
echo 'addn-hosts=/etc/dnsmasq.d/leases.hosts' > etc-dnsmasq.d/02-leases.conf
chmod +x sync-leases.sh
./sync-leases.sh
grep -q sync-leases.sh /etc/crontabs/root 2>/dev/null || echo "* * * * * $REMOTE_DIR/sync-leases.sh" >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart
REMOTE

ssh_r "cd $REMOTE_DIR && docker compose up -d"

step "Wait for the container to become healthy (first run downloads blocklists; up to ~3 min)"
for _ in $(seq 1 36); do
  status="$(ssh_r "docker inspect -f '{{.State.Health.Status}}' pihole" 2>/dev/null || true)"
  [[ "$status" == healthy ]] && break
  sleep 5
done
echo "container health: ${status:-unknown}"

step "Verify from this machine"
fail=0
router_ip="$(ssh_r 'uci -q get network.lan.ipaddr | cut -d/ -f1')"
[[ -n "$router_ip" ]] || { echo "could not read network.lan.ipaddr from $HOST" >&2; exit 1; }
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$router_ip:$UI_PORT/admin/" || true)"
echo "UI http status: $code (expect 200/302)"; [[ "$code" =~ ^(200|302)$ ]] || fail=1
ok="$(dig @"$router_ip" -p "$DNS_PORT" example.com +short +time=3 +tries=1 | head -1)"
echo "example.com   -> ${ok:-<no answer>}"; [[ -n "$ok" ]] || fail=1
blocked="$(dig @"$router_ip" -p "$DNS_PORT" doubleclick.net +short +time=3 +tries=1 | head -1)"
echo "doubleclick.net -> ${blocked:-<no answer>} (expect 0.0.0.0 once gravity has loaded)"
plain="$(dig doubleclick.net +short +time=3 +tries=1 | head -1)"
echo "doubleclick.net via system resolver -> ${plain:-<no answer>} (expect 0.0.0.0 if this machine uses $router_ip for DNS)"
[[ "$plain" == "0.0.0.0" ]] || echo "WARNING: port-53 redirect not effective from here (or this machine doesn't use $router_ip for DNS)" >&2

if (( fail )); then
  echo; echo "FAILED. Check: ssh $HOST 'docker logs --tail=40 pihole'; backup is in $backup/" >&2
  exit 1
fi
echo; echo "OK. LAN clients using $router_ip for DNS (e.g. via DHCP) now go through Pi-hole via the port-53 redirect."
