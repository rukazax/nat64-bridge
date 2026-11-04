# Agent prompt: IPv4 services on an IPv6-only host (REDIRECT → SO_ORIGINAL_DST → IPv6 via NAT64)

> Paste the block below into an agent chat, replacing the bracketed values.
> It is self-contained: the agent has no access to this repository or any prior conversation.

---

## Task

On a server that has **no IPv4 route** (IPv6 only), bring up services that need IPv4 egress, giving
them IPv4 internet access through the **provider's NAT64**.

Server: `[IP/host]`, access `[ssh root@host -p port]`, password/key `[if any]`.
Implement both services (or only the ones listed):

1. **Telegram MTProto proxy** (`mtg`) — TCP 443, clients connect over IPv6.
2. **AmneziaWG server** (`amneziawg-go` + `amneziawg-tools` 3.1) — tunnel clients must get working IPv4.

## Constraints

* Do not reboot the server unless necessary; do not touch foreign services (inspect
  `systemctl list-units`; leave existing VPN stacks, their files and units alone).
* No kernel modules (the host is often LXC) — userspace only.
* Do not try `clatd`/`jool` (not packaged / cannot load in a container).
* Do not modify the firewall globally: only add your own rules, commented and scripted.
* Every change must be idempotent; routing and firewall rules belong in a separate oneshot unit so
  they survive a reboot.

## Core technique (must follow)

The host has no IPv4 route, but the provider's NAT64 passes traffic when **our process** opens it from
our own IPv6 address:

```
iptables -t nat REDIRECT → local process → SO_ORIGINAL_DST → dial tcp6 [prefix::<IPv4>]:port
```

* `SO_ORIGINAL_DST` = `getsockopt(fd, SOL_IP, 80)` (struct sockaddr_in).
* Address mapping: `<prefix>::a.b.c.d` — the last 32 bits are the IPv4 address.
* For locally generated traffic you must add `ip -4 route replace <net> dev lo`, otherwise connect
  fails with `ENETUNREACH` before netfilter is consulted.
* Do **not** attempt a CLAT with tayga: replies hit the local IPv6 stack and the kernel answers RST;
  dropping them in raw/PREROUTING also hides them from tayga. This is a verified dead end.

## Steps

1. **Diagnostics.**
   ```bash
   ip -4 route show default ; ip -6 addr show scope global ; systemd-detect-virt
   getent ahostsv6 ipv4only.arpa      # derive the NAT64 /96 prefix
   ```
2. **Verify TCP through NAT64** with Python (`bash /dev/tcp` cannot do IPv6): connect to
   `[prefix::1.1.1.1]:443` and `[prefix::149.154.167.51]:443`. Both must be `TCP OK`.
   If TCP does not pass, stop and report that the recipe is not applicable.
3. **Build the bridge.** Go, single file, stdlib + syscall only, `CGO_ENABLED=0`. Two variants:
   * `dc6` — listens on `127.0.0.1:19191`, for `mtg` (REDIRECT from `nat OUTPUT` for
     `149.154.0.0/16`, `91.108.0.0/16`, `95.161.76.0/24`);
   * `vpn4` — listens on `0.0.0.0:19192` (TCP) and `0.0.0.0:5353` (UDP DNS relay), REDIRECT from
     `nat PREROUTING -i awg0`.
4. **Install and configure** following the recipe (systemd units, rules script, firewall only for the
   required ports).
5. **Verify for real**, not merely "service is active":
   * `journalctl -u dc6` / `-u vpn4` shows a real connection line `... -> [prefix::x.x.x.x]:443`;
   * `ss -tlnp` shows the listeners;
   * MTG: `mtg access` returns a working `tg://` link, and TCP+TLS to `[IPv6]:443` completes (fake TLS);
   * AWG: a client in its own netns (`unshare -n`) receives IPv4 and
     `wget -4 http://1.1.1.1/cdn-cgi/trace` returns a body with the egress IPv4 address;
     a DNS query to `10.90.0.1:53` returns `rcode: 0`.
6. **Persist**: oneshot unit with rules and routes, `systemctl is-enabled` = enabled, and re-run the
   checks from step 5 after restarting every unit.
7. **Report**: what was installed, the actual command outputs, the limitations, and how to roll back.

## Acceptance criteria

| Check | Expectation |
|---|---|
| `getent ahostsv6 ipv4only.arpa` | AAAA with the NAT64 prefix |
| TCP test to `[prefix::1.1.1.1]:443` | `TCP OK` |
| `systemctl is-enabled dc6-rules mtg` (or `vpn4-rules vpn4`) | `enabled` |
| bridge log after a real connection | `... -> [prefix::<IPv4>]:443` |
| MTG: fake TLS on `[IPv6]:443` | TLS 1.3 handshake completes |
| AWG: from the client `wget -4 http://1.1.1.1/cdn-cgi/trace` | body with `ip=<egress IPv4>` |
| AWG: DNS to `10.90.0.1` | `rcode: 0` with answers |

## Limitations to state in the report

* TCP only (plus UDP/53 in the AWG variant). QUIC and other UDP do not pass — browsers fall back to TCP.
* ICMP does not work.
* The endpoint stays IPv6: the client needs an IPv6 network.
* The egress IPv4 is the provider's NAT64 address.

## Forbidden

* Rebooting the server, editing foreign units/files, removing existing VPN stacks.
* Installing kernel modules, `clatd`, `jool`, `tayga` (dead end, see above).
* Leaving `nat` rules without your own comment/script.
* Reporting "it works" without actual command output.

---

# Промт на русском

Готовый русский вариант: [PROMPT.ru.md](PROMPT.ru.md) — те же требования, шаги и критерии приёмки.
