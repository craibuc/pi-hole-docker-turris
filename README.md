# pihole

Pi-hole on a Turris Omnia (Turris OS 9.1.1, HBS).

Design: Pi-hole runs in Docker with host networking (so it sees real client IPs) on ports `5354`/`8080`/`8443` so it never fights kresd
(port 53) or LuCI/lighttpd (80/443) for a port. LAN clients are pointed at it by a
firewall rule that redirects port-53 traffic to `5354`. Pi-hole forwards what it does
not block back to kresd on `127.0.0.1:53`.

Client names: kresd does not serve DHCP lease names, so `sync-leases.sh` (cron, every minute)
converts `/tmp/dhcp.leases` into a hosts file Pi-hole reads. See SETUP.md.

Upstream choice: kresd is used so DNSSEC signatures are verified on the router itself.
The ISP resolvers (206.55.176.52/53) do validate DNSSEC too — verified with `dig`: they
set `ad` on signed names and SERVFAIL on `dnssec-failed.org` — so the only thing local
validation buys is not having to trust the plaintext hop between router and ISP.
Forwarding straight to the ISP instead is a reasonable trade; swap `FTLCONF_dns_upstreams`.

    client :53 ──DNAT──▶ router :5354 (Pi-hole, host net) ──▶ 127.0.0.1:53 (kresd) ──▶ internet

## Router environment (verified 2026-08-24 over SSH)

No install work is needed — the prerequisites are already in place:

- LAN IP is `192.168.1.1`; kresd answers there and validates DNSSEC locally
  (`ad` flag set, SERVFAIL on `dnssec-failed.org`).
- Docker 27.3.1 + Compose v2.39.1 installed, `dockerd` enabled at boot.
- Docker `data-root` is `/srv/docker`, on a 954G disk with ~610G free — the eMMC
  (`/`, 4.9G free) is not involved, so image size is a non-issue.
- Ports `5354`/`8080`/`8443` are free; `53`/`80`/`443` are held by kresd and LuCI.
- `etc-pihole/` and `etc-dnsmasq.d/` are both empty, so there is no stale v5 config
  to migrate.
- Existing containers on the host: `jellyfin`, `postgres`. Neither touches DNS or our
  ports.

## 1. Replace the old compose file

`/srv/docker/pihole/docker-compose.yaml` already holds a 2022-era Pi-hole v5 config
(binds `53`/`67`/`80`, plaintext `WEBPASSWORD`). It was never running — there is no
pihole container on the host. Back it up rather than overwrite blind:

    ssh router 'cp /srv/docker/pihole/docker-compose.yaml /srv/docker/pihole/docker-compose.yaml.2022.bak'
    scp docker-compose.yaml .env router:/srv/docker/pihole/

## 2. Start Pi-hole

    ssh router 'cd /srv/docker/pihole && docker compose up -d && docker compose logs --tail=40 pihole'

Web UI: `http://192.168.1.1:8080/admin`, password from `.env`.

Verify Pi-hole resolves before touching any firewall rules:

    dig @192.168.1.1 -p 5354 example.com

## 3. Redirect LAN DNS to Pi-hole

Only after step 3 answers correctly. This is the step that can take DNS down for the
whole LAN, so keep a way in that does not depend on DNS (the router's IP, not a name).

    uci add firewall redirect
    uci set firewall.@redirect[-1].name='Divert-DNS-to-Pihole'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].proto='tcp udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='5354'
    uci set firewall.@redirect[-1].target='DNAT'
    uci commit firewall
    /etc/init.d/firewall restart

This also catches devices with hardcoded DNS (8.8.8.8 and friends) that ignore DHCP.

**No redirect loop here.** The rule is scoped to `src='lan'`; Pi-hole's own upstream queries
to kresd go to `127.0.0.1` on the router and never enter from the LAN zone.

**Why host networking:** the redirect is a DNAT on the router itself, so with a bridge it hit
`docker-proxy` and every client appeared as `172.17.0.1` (see TROUBLESHOOTING.md). There are also currently no other
`redirect` rules to conflict with.

To roll back, delete the rule and restart the firewall:

    uci delete firewall.@redirect[-1]
    uci commit firewall && /etc/init.d/firewall restart

## Known gaps

- **IPv6 bypass (real, confirmed).** `dhcp.lan.dhcpv6='server'` with `ra_management='1'`
  means the router advertises itself as an IPv6 DNS server. A `redirect` rule is IPv4-only
  by default, so dual-stack clients can query kresd over IPv6 port 53 and skip Pi-hole
  entirely — blocking would look partial and inconsistent. Closing this means either an
  equivalent IPv6 rule or stopping the RA/DHCPv6 DNS advertisement. Not addressed here.
- **DNS-over-HTTPS** bypasses this regardless (Firefox default, some phone/TV apps).
  Blocking it means blocking outbound 443 to known DoH resolvers — separate problem.
- **Guest network not covered.** The `tr_guest` zone has its own DNS rule; the redirect
  above is scoped to `lan` only.
- Note `dhcp.@dnsmasq[0].port='0'` — dnsmasq is DHCP-only and kresd owns DNS. That is the
  stock Turris arrangement and the design above depends on it.

## Reference
- https://github.com/pi-hole/docker-pi-hole
- https://hub.docker.com/r/pihole/pihole
