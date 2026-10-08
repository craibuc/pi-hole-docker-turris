# Pi-hole on Turris: setup findings (2026-10-05)

## Symptom

After deploying `docker-compose.yaml` to the router, `dig @192.168.1.1 -p 5354` timed out and the UI on `:8080` was down.

## Root cause

Pi-hole never started. On an empty data directory it runs gravity first, which needs DNS to download blocklists. The container had no working network path, so gravity failed (`DNS resolution is currently unavailable`) and FTL (DNS and web UI in v6) never launched. Five separate problems were stacked:

| # | Finding | How it was tested | Fix |
|---|---|---|---|
| 1 | Compose created a new bridge (`br-<id>`). The Turris firewall's `docker` zone only covers `docker0`. | Container ping to 9.9.9.9 failed; router's own ping worked; `nft` forward chain is policy drop. | `network_mode: bridge` in compose |
| 2 | No `docker` -> `wan` forwarding. Zone `forward ACCEPT` only covers traffic within the zone. | `tcpdump`: packets on `docker0`, none on `eth2`. | uci forwarding `docker` -> `wan` |
| 3 | `DOCKER-USER` rejected everything `eth2` -> `docker0`, including replies. Comes from dockerd `blocked_interfaces`. | `tcpdump`: replies arrived on `eth2`, never reached `docker0`. | `dockerd.firewall.extra_iptables_args='-m conntrack --ctstate NEW'` |
| 4 | Upstream `192.168.1.1` timed out: kresd replies from `172.17.0.1`, and the container drops replies from an address it did not query. | Container -> 9.9.9.9 worked, container -> 192.168.1.1 did not; capture showed the reply source. | Upstream `172.17.0.1#53` |
| 5 | LAN could not reach published ports: no `lan` -> `docker` forwarding. | UI returned 302 from the router itself, LAN requests dropped. | Narrow rule `Allow-LAN-to-Pihole` (ports 53, 80, 443) |
| 6 | Every client logged as `172.17.0.1`. The fw redirect (53 -> 5354) is a DNAT on the router, so it hit `docker-proxy` on 5354 instead of Docker's own DNAT rule. | `netstat -lnp` showed `docker-proxy` on 5354; redirect has no `dest_ip`. | `network_mode: host` with `FTLCONF_dns_port=5354`, upstream `127.0.0.1#53` (rollback: `docker-compose.yaml.prehost` on the router) |

## Router changes (persistent)

```sh
# 2. docker -> wan forwarding
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='docker'
uci set firewall.@forwarding[-1].dest='wan'

# 5. LAN -> Pi-hole container (ports after Docker's DNAT: 53, 80, 443)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-LAN-to-Pihole'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='docker'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53 80 443'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall && /etc/init.d/firewall reload

# 3. only block NEW connections from wan into docker0 (replies allowed)
uci set dockerd.firewall.extra_iptables_args='-m conntrack --ctstate NEW'
uci commit dockerd
# applied live without restarting dockerd:
iptables -D DOCKER-USER -i eth2 -o docker0 -j REJECT --reject-with icmp-port-unreachable
iptables -I DOCKER-USER 1 -i eth2 -o docker0 -m conntrack --ctstate NEW -j REJECT --reject-with icmp-port-unreachable
```

Rollback: delete the added firewall sections with `uci delete firewall.@forwarding[-1]` / `uci delete firewall.@rule[-1]` (check the index first), `uci delete dockerd.firewall.extra_iptables_args`, then commit and reload. A pre-change backup is in `backup-20261005-063204/` (contains `.env` with the password; ignored by git).

## Verified final state

- Container healthy; UI `http://192.168.1.1:8080/admin/` returns 302.
- `dig @192.168.1.1 -p 5354 example.com` resolves; `doubleclick.net` returns `0.0.0.0` (blocked).
- Postgres 5432 not reachable from the LAN.
- Guest network unchanged: no access to Pi-hole, uses kresd at `10.111.222.1`.
- jellyfin and postgres unaffected; router internet unaffected.

## Notes and not done

- No client uses Pi-hole for DNS yet (DHCP still hands out `192.168.1.1`, kresd).
- Rule 5 matches post-DNAT ports 53/80/443 to any container in the docker zone, not just Pi-hole. It was chosen over matching the container IP because that can change on recreate. Postgres (5432) is excluded.
- A router reboot was not tested; the changes use uci and dockerd config, so they should persist.
- Container ICMP ping to the internet still fails (UDP/TCP work); not investigated, not needed by Pi-hole.
