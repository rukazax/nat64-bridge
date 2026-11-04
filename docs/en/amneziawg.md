# AmneziaWG 3.1 — building the server from source

Verified on Ubuntu 22.04 (LXC, Proxmox kernel 6.8.12-pve). There are no official `amneziawg-go`
binaries — only tags — so you build it yourself; `amneziawg-tools` ships prebuilt archives.

## 1. Versions

| Component | What to take | Check |
|---|---|---|
| `amneziawg-go` | tag **v3.1.20260828** from `amnezia-vpn/amneziawg-go` | `awg show` prints `content padding addition`, `rekey after time` |
| `amneziawg-tools` | release **v3.1.20260812**, asset `ubuntu-22.04-amneziawg-tools.zip` (`awg`, `awg-quick`) | `awg --version` → `amneziawg-tools v3.1.…` |

An older (2.x) `amneziawg-go` binary **does not understand** the 3.x keys (`ContentPaddingAddition`,
`RekeyAfterTime`, `DisableCookies`, `RandomTrailers`) — a 3.1 config will not apply.

## 2. Build `amneziawg-go`

On a machine with Go (the result is static and portable to any linux-amd64):

```bash
go version    # 1.24+ (Debian/Ubuntu: apt install golang-go)
cd /tmp
curl -sL -o go.tgz https://github.com/amnezia-vpn/amneziawg-go/archive/refs/tags/v3.1.20260828.tar.gz
tar xzf go.tgz && cd amneziawg-go-3.1.20260828
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o amneziawg-go-3.1 .
file amneziawg-go-3.1     # statically linked
```

Capability check:

```bash
for s in content_padding_addition rekey_after_time disable_cookies random_trailers; do
  printf '%-26s %s\n' "$s" "$(strings amneziawg-go-3.1 | grep -c $s)"
done
# every value must be > 0
```

## 3. Tools (`awg`)

```bash
curl -L -o tools.zip \
  https://github.com/amnezia-vpn/amneziawg-tools/releases/download/v3.1.20260812/ubuntu-22.04-amneziawg-tools.zip
python3 -c "import zipfile;zipfile.ZipFile('tools.zip').extractall('.')"
install -m 755 ubuntu-22.04-amneziawg-tools/awg /usr/local/bin/awg
install -m 755 ubuntu-22.04-amneziawg-tools/awg-quick /usr/local/bin/awg-quick
awg --version
```

## 4. Running the userspace daemon

```ini
# /etc/systemd/system/awg-owner.service
[Unit]
Description=Owner AmneziaWG 3.1 instance (awg0)
After=network.target

[Service]
Type=simple
UMask=0077
Environment=WG_PROCESS_FOREGROUND=1
Environment=LOG_LEVEL=error
ExecStart=/usr/local/bin/amneziawg-go-3.1 -f awg0
ExecStartPost=/usr/bin/python3 /etc/awg-owner/apply.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

`apply.py` waits for `/run/amneziawg/awg0.sock` and then runs:

```bash
awg setconf awg0 /etc/awg-owner/awg0.setconf.conf
ip address replace fd90:1::1/64 dev awg0
ip -4 addr replace 10.90.0.1/24 dev awg0        # if IPv4 is needed (see nat64 recipe)
ip link set dev awg0 mtu 1280 up
ip6tables -I INPUT -p udp --dport 51830 -j ACCEPT
```

> `awg setconf` **does not accept** `Address` and `MTU` (those are `awg-quick` directives). Keep two
> files: the full `awg0.conf` for documentation and `awg0.setconf.conf` without `Address`/`MTU`.

## 5. 3.1 parameters (server and client must match)

```ini
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
```

Constraints: `Jmin < Jmax`; `S1 + 148 != S2`; `H1..H4` unique and within 5…2147483647.
`RandomTrailers` and `DisableCookies` default to `off` — enable them only if every client supports it
(old iOS/macOS clients reject `DisableCookies`).

## 6. Verification

```bash
systemctl is-active awg-owner
awg show                 # interface, port, 3.1 parameters, peers
awg showconf awg0        # effective config
ss -ulnp | grep 51830
```

End-to-end test without an external client — run a client in its own netns:

```bash
unshare -n sleep 300 &   # netns addressed by PID
# veth into that netns, fd91::/64 addresses, default route, NAT66 on eth0
# inside: amneziawg-go-3.1 -f awgc ; awg setconf awgc client.conf ; ip addr/route
nsenter -t <PID> -n ping -6 -c3 2606:4700:4700::1111
```

For that test, scope the policy route to locally generated traffic, otherwise the rule captures
forwarded packets too and the tunnel loops:

```bash
ip -6 rule add from <client-v6> iif lo lookup 51830 prio 100
```

## 7. Rollback

```bash
systemctl disable --now awg-owner
rm -rf /etc/awg-owner
```
