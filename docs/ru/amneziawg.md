# AmneziaWG 3.1 — сборка сервера из исходников (рецепт)

Проверено на Ubuntu 22.04 (LXC, ядро Proxmox 6.8.12-pve). Официальных бинарей `amneziawg-go` нет —
только теги, поэтому собираем сами; `amneziawg-tools` есть готовыми архивами.

## 1. Версии

| Компонент | Что брать | Проверка |
|---|---|---|
| `amneziawg-go` | тег **v3.1.20260828** из `amnezia-vpn/amneziawg-go` | `awg show` печатает `content padding addition`, `rekey after time` |
| `amneziawg-tools` | релиз **v3.1.20260812**, asset `ubuntu-22.04-amneziawg-tools.zip` (`awg`, `awg-quick`) | `awg --version` → `amneziawg-tools v3.1.…` |

Старый (2.x) бинарь `amneziawg-go` **не понимает** ключи 3.x (`ContentPaddingAddition`,
`RekeyAfterTime`, `DisableCookies`, `RandomTrailers`) — конфиг 3.1 с ним не применится.

## 2. Сборка (`amneziawg-go`)

На машине с Go (собирается статически, переносится на любой linux-amd64):

```bash
go version    # 1.24+ (Debian/Ubuntu: apt install golang-go)
cd /tmp
curl -sL -o go.tgz https://github.com/amnezia-vpn/amneziawg-go/archive/refs/tags/v3.1.20260828.tar.gz
tar xzf go.tgz && cd amneziawg-go-3.1.20260828
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o amneziawg-go-3.1 .
file amneziawg-go-3.1     # statically linked
```

Проверка возможностей:

```bash
for s in content_padding_addition rekey_after_time disable_cookies random_trailers; do
  printf '%-26s %s\n' "$s" "$(strings amneziawg-go-3.1 | grep -c $s)"
done
# все значения должны быть > 0
```

## 3. Инструменты (`awg`)

```bash
curl -L -o tools.zip \
  https://github.com/amnezia-vpn/amneziawg-tools/releases/download/v3.1.20260812/ubuntu-22.04-amneziawg-tools.zip
python3 -c "import zipfile;zipfile.ZipFile('tools.zip').extractall('.')"
install -m 755 ubuntu-22.04-amneziawg-tools/awg /usr/local/bin/awg
install -m 755 ubuntu-22.04-amneziawg-tools/awg-quick /usr/local/bin/awg-quick
awg --version
```

## 4. Запуск userspace-демона

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

`apply.py` ждёт появления `/run/amneziawg/awg0.sock`, затем:

```bash
awg setconf awg0 /etc/awg-owner/awg0.setconf.conf
ip address replace fd90:1::1/64 dev awg0
ip -4 addr replace 10.90.0.1/24 dev awg0        # если нужен IPv4 (см. nat64-bridge/README.md)
ip link set dev awg0 mtu 1280 up
ip6tables -I INPUT -p udp --dport 51830 -j ACCEPT
```

> `awg setconf` **не принимает** `Address` и `MTU` (это директивы `awg-quick`). Держите два файла:
> полный `awg0.conf` для документации и `awg0.setconf.conf` без `Address`/`MTU` для применения.

## 5. Параметры 3.1 (сервер и клиент должны совпадать)

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

Ограничения: `Jmin < Jmax`; `S1 + 148 != S2`; `H1..H4` уникальны и в диапазоне 5…2147483647.
`RandomTrailers` и `DisableCookies` по умолчанию `off` — включайте только если уверены, что все
клиенты понимают (старые iOS/macOS-клиенты отвергают `DisableCookies`).

## 6. Проверка

```bash
systemctl is-active awg-owner
awg show                 # интерфейс, порт, параметры 3.1, пиры
awg showconf awg0        # эффективный конфиг
ss -ulnp | grep 51830
```

Сквозной тест без внешнего клиента — клиент в отдельном netns:

```bash
unshare -n sleep 300 &   # netns по PID
# veth в этот netns, адреса fd91::/64, default route, NAT66 на eth0
# внутри netns: amneziawg-go-3.1 -f awgc ; awg setconf awgc client.conf ; ip addr/route
nsenter -t <PID> -n ping -6 -c3 2606:4700:4700::1111
```

Для этого теста политику маршрутизации задавайте с `iif lo`, иначе правило перехватит
форвардинг и трафик закольцуется:

```bash
ip -6 rule add from <client-v6> iif lo lookup 51830 prio 100
```

## 7. Откат

```bash
systemctl disable --now awg-owner
rm -rf /etc/awg-owner
```
