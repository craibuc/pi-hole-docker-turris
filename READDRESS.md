# Re-addressing a Turris router before handing it off

Use this when a router was set up on one LAN address (e.g. `192.168.2.1`, so it can sit behind another router during configuration) and needs to move to its final address (e.g. `192.168.1.1`). Pi-hole itself needs no change: it listens in `LOCAL` mode and forwards to `127.0.0.1`, so it is address-independent.

## What holds the address

Only two settings reference the LAN address:

| Setting | Why it matters |
|---|---|
| `network.lan.ipaddr` | The router's own address. |
| `dhcp.lan.dhcp_option` (`6,<ip>`) | The DNS server advertised to DHCP clients. If left at the old address, clients are told to use a DNS server that no longer exists. |

The guest network (`10.111.222.1`) is separate and unaffected. Check for anything else with:

    ssh root@<current-ip> 'grep -rn "<old-subnet>\." /etc/config/'

## Before you start

- **Subnet conflict.** Only matters while the router sits behind another router: its WAN side must not be on the new LAN subnet. In its final home it connects straight to the ISP (like yours), so `192.168.1.0/24` is fine there. Don't plug it back in behind your own `192.168.1.1` router after re-addressing; both LANs would then use the same subnet and routing breaks.
- **Your SSH session will drop** when the address changes. Run the command in one go and reconnect afterwards.

## Steps

1. Apply both changes together (example: `192.168.2.1` to `192.168.1.1`):

       ssh root@192.168.2.1 '
       uci set network.lan.ipaddr="192.168.1.1/24"
       uci set dhcp.lan.dhcp_option="6,192.168.1.1"
       uci commit network && uci commit dhcp
       /etc/init.d/network restart; /etc/init.d/dnsmasq restart'

2. Renew your machine's DHCP lease (unplug and replug, or toggle Wi-Fi). It still holds a `192.168.2.x` address until you do.
3. Reconnect: `ssh root@192.168.1.1`.
4. Verify:

       dig @192.168.1.1 doubleclick.net +short    # 0.0.0.0
       curl -sI http://192.168.1.1:8080/admin/    # 302

   The Pi-hole UI is now at `http://192.168.1.1:8080/admin`.
5. Optional: change the Pi-hole web password in the UI before handing the router over.

## If you lose access

Use the Turris reForis web interface at the new address, or the router's factory-reset button recovery as a last resort.

## Rollback

Repeat step 1 with the old address, then renew your DHCP lease again.
