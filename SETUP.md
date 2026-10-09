# Manual setup: Pi-hole on a Turris/OpenWrt router

`./deploy.sh` does all of this idempotently. These are the same steps by hand. The reasons for each are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Assumes: SSH alias `router`, Docker on the router, data under `/srv/docker/pihole`, LAN `192.168.1.0/24`, Docker's default bridge `docker0` (gateway `172.17.0.1`).

1. **Prepare `.env`**: `cp .env.example .env`, then set at least `WEB_API_PASSWORD`.
2. **Compose file requirements** (already in `docker-compose.yaml`):
   - `network_mode: host`, so Pi-hole sees real client IPs. With a bridge, the 53 -> 5354 redirect lands on `docker-proxy` and every client shows as `172.17.0.1`. FTL is moved to DNS `5354` and web `8080`/`8443` via `FTLCONF_dns_port` / `FTLCONF_webserver_port`.
   - Upstream `FTLCONF_dns_upstreams: 127.0.0.1#53` (kresd, via the host network).
   - The `docker0`-zone firewall steps below (forwarding, `Allow-LAN-to-Pihole`, `DOCKER-USER`) were needed for the old bridge setup and are harmless but no longer required for Pi-hole.
3. **Back up the router config:**
   ```sh
   ssh router 'tar czf - /etc/config/firewall /etc/config/dockerd /srv/docker/pihole' > router-backup.tgz
   ```
4. **Allow containers to reach the internet** (needed for the first gravity run):
   ```sh
   uci add firewall forwarding
   uci set firewall.@forwarding[-1].src='docker'
   uci set firewall.@forwarding[-1].dest='wan'
   ```
5. **Allow the LAN to reach Pi-hole's published ports** (matched after Docker's DNAT, so 53/80/443, not 5354/8080/8443):
   ```sh
   uci add firewall rule
   uci set firewall.@rule[-1].name='Allow-LAN-to-Pihole'
   uci set firewall.@rule[-1].src='lan'
   uci set firewall.@rule[-1].dest='docker'
   uci set firewall.@rule[-1].proto='tcp udp'
   uci set firewall.@rule[-1].dest_port='53 80 443'
   uci set firewall.@rule[-1].target='ACCEPT'
   uci commit firewall && /etc/init.d/firewall reload
   ```
   **Redirect LAN DNS to Pi-hole.** Without this, clients using `192.168.1.1:53` reach kresd, not Pi-hole. Scoped to `src=lan` so Pi-hole's own upstream queries to kresd (from the docker zone) aren't looped back:
   ```sh
   uci add firewall redirect
   uci set firewall.@redirect[-1].name='LAN-DNS-to-Pihole'
   uci set firewall.@redirect[-1].src='lan'
   uci set firewall.@redirect[-1].proto='tcp udp'
   uci set firewall.@redirect[-1].src_dport='53'
   uci set firewall.@redirect[-1].dest_port='5354'
   uci set firewall.@redirect[-1].target='DNAT'
   uci commit firewall && /etc/init.d/firewall reload
   ```
   This also redirects LAN devices that hardcode another resolver (e.g. 8.8.8.8). If Pi-hole is down, LAN DNS fails.
6. **Stop dockerd rejecting replies into `docker0`.** Restrict its WAN block to NEW connections, both persistently and live:
   ```sh
   uci set dockerd.firewall.extra_iptables_args='-m conntrack --ctstate NEW'
   uci commit dockerd
   iptables -D DOCKER-USER -i eth2 -o docker0 -j REJECT --reject-with icmp-port-unreachable
   iptables -I DOCKER-USER 1 -i eth2 -o docker0 -m conntrack --ctstate NEW -j REJECT --reject-with icmp-port-unreachable
   ```
   Do not restart dockerd just for this; it restarts your other containers.
7. **Deploy:**
   ```sh
   scp docker-compose.yaml .env router:/srv/docker/pihole/
   ssh router 'cd /srv/docker/pihole && docker compose up -d'
   ```
   The first start downloads blocklists and takes a minute or two. Wait for `docker ps` to show `healthy`.
8. **Verify:**
   ```sh
   curl -I http://192.168.1.1:8080/admin/          # 200/302
   dig @192.168.1.1 -p 5354 example.com            # answer
   dig @192.168.1.1 -p 5354 doubleclick.net +short # 0.0.0.0 (blocked)
   dig doubleclick.net +short                      # 0.0.0.0 via the port-53 redirect, if this machine's DNS is 192.168.1.1
   ```
9. **Use it.** Clients whose DNS is the router (the usual DHCP default) go through Pi-hole via the port-53 redirect from step 5. The redirect is untested on the Turris: if plain `dig` still isn't blocked, check the order of Docker's `nat` rules against the fw redirect (`iptables -t nat -S | grep -E '5354|DOCKER'`).

## Rollback

Delete the added sections (check the indexes first with `uci show firewall | grep -n forwarding`), then `uci delete dockerd.firewall.extra_iptables_args`, commit, and reload the firewall. Or restore `/etc/config/*` from the backup tarball.

## Client names in the Pi-hole UI

kresd does not serve DHCP lease names, so `sync-leases.sh` turns `/tmp/dhcp.leases` into an `addn-hosts` file that Pi-hole reads.

    scp sync-leases.sh router:/srv/docker/pihole/
    ssh router 'echo "addn-hosts=/etc/dnsmasq.d/leases.hosts" > /srv/docker/pihole/etc-dnsmasq.d/02-leases.conf'
    ssh router 'echo "* * * * * /srv/docker/pihole/sync-leases.sh" >> /etc/crontabs/root && /etc/init.d/cron enable && /etc/init.d/cron restart'

Leases with no hostname (`*`) are skipped and still show as IPs.
