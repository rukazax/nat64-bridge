# Recipe: IPv4 services on an IPv6-only host through NAT64

Verified on a real server: Ubuntu 22.04 in LXC, IPv6 only (`2a0c:…`), provider DNS64/NAT64.
Two services are built with this recipe:

* **Telegram MTProto proxy** (`mtg`) — variant A, bridge `dc6`;
* **AmneziaWG 3.1 server** with IPv4 for its clients — variant B, bridge `vpn4`.

The core technique is the same everywhere: a connection the service wants to open over IPv4 is
redirected into a local process, which recovers the original destination via `SO_ORIGINAL_DST` and
opens the same connection **over IPv6 to the provider's NAT64 prefix** (`prefix::<IPv4>`). Replies
arrive at our real IPv6 address and are delivered correctly to that socket.

---

## 0. When it applies

| Condition | How to check | Meaning |
|---|---|---|
| No IPv4 route | `ip -4 route show default` is empty | truly IPv6-only |
| Provider offers DNS64/NAT64 | `getent ahostsv6 ipv4only.arpa` returns AAAA | NAT64 exists |
| NAT64 passes TCP | test in step 2 | the technique will work |

If the host has a public IPv4 address, skip this recipe and use ordinary NAT.

---

## 1. Find the NAT64 prefix

```bash
getent ahostsv6 ipv4only.arpa
# 2a01:4f8:c2c:123f:64:5:c000:aa  ← this is <prefix>::192.0.0.170
```

`ipv4only.arpa` only has A records (`192.0.0.170/171`), so the answer reveals the prefix: drop the last
32 bits and you get the `/96`, for example `2a01:4f8:c2c:123f:64:5::/96`.

---

## 2. Verify TCP through NAT64 (mandatory)

Bash `/dev/tcp` **cannot do IPv6** — use Python:

```bash
python3 - <<'PY'
import socket
P = '2a01:4f8:c2c:123f:64:5'          # your prefix
for v4 in ('1.1.1.1', '149.154.167.51'):
    h = ''.join(f'{int(o):02x}' for o in v4.split('.'))
    dst = f"{P}:{int(h[:4],16):x}:{int(h[4:],16):x}"
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(7)
    try:
        s.connect((dst, 443)); print(v4, 'TCP OK ->', dst)
    except Exception as e:
        print(v4, 'FAIL', e)
    finally:
        s.close()
PY
```

Both must print `TCP OK`. ICMP works too (`ping -6 <prefix>::101:101`), but TCP is the decisive test.

---

## 3. Why not tayga/CLAT (do not repeat this)

All three paths lead to a dead end; this was measured on a live host:

| Approach | What happens |
|---|---|
| `tayga` with `dynamic-pool` (clients behind the tun) | packets are translated, replies never arrive: the provider does not route prefix addresses back to us |
| `tayga` with `map 192.0.0.2 <our IPv6>` (CLAT) | requests leave correctly, SYN-ACK returns, but **the kernel answers RST** (there is no local IPv4 socket) |
| `ip6tables -t raw PREROUTING -s <prefix> -j DROP` (to suppress RST) | RST disappears, but tayga stops seeing the replies as well (raw/PREROUTING runs before tayga's socket) |
| `clatd` | not available in the Ubuntu 22.04 repositories |

Conclusion: a **packet-level** CLAT is out of reach here, while a **connection-level** bridge works
because our process initiates the connection and receives the replies on its own socket.

---

## 4. The technique

```
client/service ──IPv4──► iptables -t nat REDIRECT ──► our process (127.0.0.1:PORT)
                                                          │ SO_ORIGINAL_DST
                                                          │ getsockopt(SOL_IP, 80)
                                                          ▼
                                             dial tcp6  [prefix::<IPv4>]:port
                                                          ▼
                                                 provider NAT64 ──► IPv4 host
```

Key details:

1. **REDIRECT in `nat PREROUTING`** (traffic from clients) or `nat OUTPUT` (our own processes).
   REDIRECT keeps the original destination, readable via
   `getsockopt(fd, SOL_IP, SO_ORIGINAL_DST)`.
2. For **local** processes a route must exist **before** netfilter: add `ip -4 route replace <net> dev lo`,
   otherwise connect fails with `ENETUNREACH` before REDIRECT is consulted.
3. IPv4 → IPv6 address mapping: `prefix::a.b.c.d` (the last 32 bits are the IPv4 address).
4. The program is a static Go binary (`CGO_ENABLED=0`) with no dependencies.
5. A systemd unit with `Restart=on-failure`; routing/firewall rules live in a separate oneshot unit so
   they survive a reboot.

---

## 5. Variant A — Telegram MTProto proxy (`mtg` + `dc6`)

```
Telegram ──► [server IPv6]:443  mtg
                  │ TCP to 149.154.x.x:443 (mtg knows only IPv4)
                  ▼
             dc6 (REDIRECT → 127.0.0.1:19191)
                  ▼
             [prefix::149.154.x.x]:443 ──► NAT64 ──► Telegram DC
```

### 5.1 Install

```bash
# 1) mtg binary (download on a machine with IPv4, then copy over)
#    https://github.com/9seconds/mtg/releases  → mtg-<ver>-linux-amd64.tar.gz
install -m 755 mtg /usr/local/bin/mtg

# 2) dc6 — build from src/dc6/main.go (see section 7) or take the prepared binary
install -m 755 dc6 /usr/local/bin/dc6

# 3) secret (fake TLS needs a domain)
mtg generate-secret --hex cloudflare.com > /etc/mtg/secret
chmod 600 /etc/mtg/secret
SECRET=$(cat /etc/mtg/secret)

printf 'secret = "%s"\nbind-to = "0.0.0.0:443"\npublic-ipv6 = "%s"\n' \
  "$SECRET" "$(ip -6 addr show dev eth0 scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)" \
  > /etc/mtg/config.toml
```

### 5.2 Rules (oneshot `dc6-rules.service`)

```bash
cat > /usr/local/sbin/dc6-rules.sh <<'SH'
#!/bin/sh
set -u
for net in 149.154.0.0/16 91.108.0.0/16 95.161.76.0/24; do
  ip -4 route replace "$net" dev lo
  iptables -t nat -C OUTPUT -p tcp -d "$net" -j REDIRECT --to-ports 19191 2>/dev/null || \
    iptables -t nat -A OUTPUT -p tcp -d "$net" -j REDIRECT --to-ports 19191
done
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
ip6tables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 443 -j ACCEPT
SH
chmod 755 /usr/local/sbin/dc6-rules.sh
```

### 5.3 Units

`dc6.service`: `ExecStart=/usr/local/bin/dc6`, `After=network-online.target`, `Restart=on-failure`.
`mtg.service`: `ExecStart=/usr/local/bin/mtg run /etc/mtg/config.toml`, `After=… dc6.service`.
`dc6-rules.service`: `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=/usr/local/sbin/dc6-rules.sh`.

```bash
systemctl daemon-reload
systemctl enable --now dc6-rules.service dc6.service mtg.service
```

### 5.4 Verify and get the link

```bash
ss -tlnp | grep ':443 '                 # mtg is listening
journalctl -u dc6 -n 20                 # after a real connection: "bridge ... -> [prefix::...]:443"
mtg access /etc/mtg/config.toml         # tg:// and https://t.me/proxy links + QR
```

The link looks like:

```
tg://proxy?port=443&secret=<base64url>&server=<server IPv6>
```

Details, tuning and troubleshooting: [mtproto.md](mtproto.md).

---

## 6. Variant B — AmneziaWG 3.1 with IPv4 for clients (`vpn4`)

```
client 10.90.0.2 ──awg0──► server 10.90.0.1
                              │ iptables REDIRECT (all TCP, UDP/53)
                              ▼
                        vpn4 (19192 tcp, 5353 udp)
                              ▼
                   [prefix::<IPv4>] ──► NAT64 ──► internet
```

### 6.1 Server side

```bash
# IPv4 inside the tunnel
ip -4 addr replace 10.90.0.1/24 dev awg0
# the client peer must allow both addresses
sed -i 's|^AllowedIPs = .*|AllowedIPs = 10.90.0.2/32, fd90:1::2/128|' /etc/awg-owner/awg0.setconf.conf
awg setconf awg0 /etc/awg-owner/awg0.setconf.conf
```

The server's `apply.py` must repeat this on boot (address + `net.ipv4.ip_forward=1`).

### 6.2 Rules (oneshot `vpn4-rules.service`)

```bash
cat > /usr/local/sbin/vpn4-rules.sh <<'SH'
#!/bin/sh
set -u
ip link set awg0 up 2>/dev/null || true
ip -4 addr replace 10.90.0.1/24 dev awg0 2>/dev/null || true
iptables -t nat -C PREROUTING -i awg0 -p tcp -j REDIRECT --to-ports 19192 2>/dev/null || \
  iptables -t nat -A PREROUTING -i awg0 -p tcp -j REDIRECT --to-ports 19192
iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
  iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-ports 5353
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o awg0 -j ACCEPT
sysctl -q -w net.ipv4.ip_forward=1
SH
chmod 755 /usr/local/sbin/vpn4-rules.sh
```

### 6.3 Client config (AmneziaWG)

```ini
[Interface]
PrivateKey = <client key>
Address = 10.90.0.2/24, fd90:1::2/128
DNS = 10.90.0.1, 2606:4700:4700::1111
MTU = 1280
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 30
S2 = 40
H1 = 1122334455
H2 = 1277335533
H3 = 1443302144
H4 = 1777000123
ContentPaddingAddition = 10-100
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20

[Peer]
PublicKey = <server public key>
Endpoint = [<server IPv6>]:51830
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

### 6.4 Verify

```bash
ss -tlnp | grep 19192 ; ss -ulnp | grep 5353
iptables -t nat -S PREROUTING | grep awg0
# from the client:
wget -4 -qO- http://1.1.1.1/cdn-cgi/trace   # shows the egress IPv4 (provider NAT64)
getent ahostsv4 example.com                  # DNS through 10.90.0.1
```

The `vpn4` log shows:

```
tcp 10.90.0.2:52684 -> 1.1.1.1:80 via [2a01:4f8:c2c:123f:64:5:101:101]:80
```

---

## 7. Building the binaries

```bash
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o vpn4 main.go
```

Sources: `src/dc6/main.go`, `src/vpn4/main.go`. Both use only stdlib + `syscall`.

---

## 8. Limitations (honest)

| Item | Status |
|---|---|
| TCP (HTTP/S, Telegram, SSH, any service) | **works fully** |
| UDP DNS (port 53) | works through a dedicated relay in `vpn4` |
| Other UDP (QUIC, games, VoIP) | **does not pass**; browsers fall back to TCP |
| ICMP / ping | does not work |
| Endpoint | stays **IPv6 only** — the client needs an IPv6 network |
| Egress IPv4 | the provider's NAT64 address |

`dc6` (for mtg) translates **TCP only**, because the MTProto proxy speaks TCP to datacenters.

---

## 9. Acceptance checklist

1. `getent ahostsv6 ipv4only.arpa` returns AAAA.
2. TCP test from step 2 prints `TCP OK`.
3. `systemctl is-enabled --quiet dc6-rules mtg` (or `vpn4-rules vpn4`) exits 0.
4. `journalctl -u dc6` / `-u vpn4` contains a line with `[prefix::…]` after a real connection.
5. `mtg access` returns a link (variant A) / the client receives an IPv4 address (variant B).
6. `iptables -t nat -S PREROUTING|OUTPUT` contains the REDIRECT rules.

Run `sudo ./scripts/verify.sh` to check all of this automatically.

---

## 10. Rollback

```bash
systemctl disable --now mtg dc6 dc6-rules          # variant A
systemctl disable --now vpn4 vpn4-rules            # variant B
iptables -t nat -F PREROUTING ; iptables -t nat -F OUTPUT   # careful: removes foreign rules too
ip -4 route del <net> dev lo
```
