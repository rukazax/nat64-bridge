# Telegram MTProto proxy on an IPv6-only host (`mtg` + `dc6`)

Companion to the [recipe](recipe.md): details for variant A.

## Diagram

```
Telegram client ──IPv6──► [<server IPv6>]:443  ── mtg
                                                   │ TCP → 149.154.x.x:443
                                                   ▼
                                        dc6 (REDIRECT → 127.0.0.1:19191)
                                                   ▼
                                        [prefix::149.154.x.x]:443
                                                   ▼
                                        provider NAT64 → Telegram DC
```

`mtg` knows only IPv4 datacenter addresses, and the host has no IPv4 route. `dc6` intercepts those
connections and re-opens them over IPv6.

## 1. Why REDIRECT in `OUTPUT`, not `PREROUTING`

`mtg` is a local process on the server, so its outbound connections traverse `nat OUTPUT`. REDIRECT
there keeps the original destination, which `dc6` reads via `SO_ORIGINAL_DST`.

The route to the Telegram networks must exist, otherwise connect fails with `ENETUNREACH` before
netfilter runs:

```bash
ip -4 route replace 149.154.0.0/16 dev lo
ip -4 route replace 91.108.0.0/16  dev lo
ip -4 route replace 95.161.76.0/24 dev lo
```

## 2. Secret

```bash
mtg generate-secret --hex cloudflare.com > /etc/mtg/secret   # fake TLS needs a domain
cat /etc/mtg/secret      # ee… (hex); base64url is also accepted in links
```

`mtg generate-secret` **requires a domain** — without it the command fails (`expected "<hostname>"`),
the secret stays empty and the service refuses to start (`secret is empty`).

The domain should have an AAAA record, otherwise you will see `SNI-DNS check: cannot resolve` — harmless.

## 3. Config

```toml
# /etc/mtg/config.toml
secret = "ee…"
bind-to = "0.0.0.0:443"
public-ipv6 = "2a0c:b641:1a0:800::2a2"
```

`public-ipv6` silences the `cannot detect public IP address` warning.

## 4. Link

```bash
mtg access /etc/mtg/config.toml
# tg_url: tg://proxy?port=443&secret=<base64url>&server=<IPv6 with %3A>
```

Telegram clients accept an IPv6 address in `server=` (URL-encoded) and can scan the QR from
`tg_qrcode`. The secret works in both forms: hex (`ee…`) and base64url.

## 5. Verification

```bash
ss -tlnp | grep ':443 '                     # mtg listens (IPv4+IPv6)
journalctl -u dc6 -n 20                     # after a real connection:
#   bridge 10.x.x.x:port (149.154.167.51:443) -> [2a01:4f8:c2c:123f:64:5:959a:a733]:443
journalctl -u mtg -n 20
```

Fake TLS can be checked locally:

```python
import socket, ssl
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(8)
s.connect(('2a0c:…', 443))
t = ssl._create_unverified_context().wrap_socket(s, server_hostname='cloudflare.com')
print('TLS', t.version())      # expect TLSv1.3
```

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `secret is empty` in journal | `generate-secret` without a domain | `mtg generate-secret --hex <domain>` and restart |
| connect → `Network is unreachable` | no IPv4 route to Telegram networks | `ip -4 route replace <net> dev lo` |
| no lines in the `dc6` log, client cannot connect | NAT64 does not pass TCP | re-check step 2 of the recipe |
| link opens but "Proxy unavailable" | the client has no IPv6 | connect from an IPv6 network (mobile data) |
| `SNI-DNS check: address mismatch` | normal for fake TLS | ignore |

## 7. Rollback

```bash
systemctl disable --now mtg dc6 dc6-rules
rm -rf /etc/mtg
```
