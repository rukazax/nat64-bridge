# Рецепт: IPv4-сервисы на IPv6-only сервере через NAT64 (REDIRECT → SO_ORIGINAL_DST → IPv6)

Проверено на реальном сервере: Ubuntu 22.04 в LXC, только IPv6 (`2a0c:...`), у провайдера есть
DNS64/NAT64 (Hetzner). На этом рецепте подняты **два рабочих сервиса**:

* **MTProto-прокси Telegram** (`mtg`) — вариант A, мост `dc6`;
* **AmneziaWG 3.1 сервер** с IPv4-доступом для клиентов — вариант B, мост `vpn4`.

Главный приём одинаковый: соединение, которое сервис хочет открыть по IPv4, перенаправляется в
локальный процесс, тот восстанавливает исходный адрес через `SO_ORIGINAL_DST` и открывает то же
соединение **по IPv6 на NAT64-префикс провайдера** (`prefix::<IPv4>`). Ответы приходят на наш
настоящий IPv6 и корректно доставляются сокету.

---

## 0. Когда рецепт применим

| Условие | Как проверить | Что означает |
|---|---|---|
| У сервера нет IPv4-маршрута | `ip -4 route show default` — пусто | «чистый» IPv6-only |
| Провайдер даёт DNS64/NAT64 | `getent ahostsv6 ipv4only.arpa` выдаёт AAAA | есть NAT64 |
| NAT64 реально пропускает TCP | тест из шага 2 | приём сработает |

Если у сервера есть публичный IPv4 — рецепт не нужен, используйте обычный NAT.

---

## 1. Найти NAT64-префикс

```bash
getent ahostsv6 ipv4only.arpa
# 2a01:4f8:c2c:123f:64:5:c000:aa  ← это <prefix>::192.0.0.170
```

`ipv4only.arpa` имеет только A-записи (`192.0.0.170/171`), поэтому в ответе виден префикс:
отбросьте последние 32 бита — получите `/96`, например `2a01:4f8:c2c:123f:64:5::/96`.

Также проверьте `/etc/resolv.conf`: DNS64-резолвер провайдера обычно виден там же.

---

## 2. Проверить TCP через NAT64 (обязательно)

`bash` c `/dev/tcp` **не умеет IPv6** — проверяйте питоном:

```bash
python3 - <<'PY'
import socket
P = '2a01:4f8:c2c:123f:64:5'          # ваш префикс
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

Ожидается `TCP OK` для обоих. ICMP тоже работает (`ping -6 <prefix>::101:101`), но TCP — главный тест.

---

## 3. Почему не tayga/CLAT (не повторяйте эту ошибку)

Проверено на живом сервере — все три пути в тупик:

| Подход | Что происходит |
|---|---|
| `tayga` с `dynamic-pool` (клиенты за tun) | пакеты транслируются, ответы не приходят: провайдер не маршрутизирует prefix-адреса к нам |
| `tayga` с `map 192.0.0.2 <наш IPv6>` (CLAT) | запросы уходят правильно, SYN-ACK приходит, но **ядро отвечает RST** (локального IPv4-сокета нет) |
| `ip6tables -t raw PREROUTING -s <prefix> -j DROP` (чтобы убрать RST) | RST исчезает, но и tayga перестаёт видеть ответы (raw/PREROUTING раньше, чем сокет tayga) |
| `clatd` | отсутствует в репозитории Ubuntu 22.04 |

Вывод: **на уровне пакетов** корректный CLAT на этом хосте недостижим, а **на уровне TCP-соединений** —
достижим, потому что инициатором соединения становится наш процесс, и ответы приходят на его сокет.

---

## 4. Схема приёма

```
клиент/сервис ──IPv4──► iptables -t nat REDIRECT ──► наш процесс (127.0.0.1:PORT)
                                                          │ SO_ORIGINAL_DST
                                                          │ (getsockopt SOL_IP, 80)
                                                          ▼
                                             dial tcp6  [prefix::<IPv4>]:port
                                                          ▼
                                                 NAT64 провайдера ──► IPv4-хост
```

Ключевые детали:

1. **REDIRECT в `nat PREROUTING`** (для трафика клиентов) или в `nat OUTPUT` (для своих процессов).
   REDIRECT не теряет исходный адрес — его читают через `getsockopt(fd, SOL_IP, SO_ORIGINAL_DST)`.
2. Для **локальных** процессов маршрут должен существовать **до** netfilter: добавьте
   `ip -4 route replace <сеть> dev lo`, иначе connect упадёт с `ENETUNREACH` ещё до REDIRECT.
3. Перевод IPv4 → IPv6-адрес: `prefix::a.b.c.d` (последние 32 бита = IPv4).
4. Программа — статический Go-бинарь (`CGO_ENABLED=0`), зависимостей нет.
5. systemd-unit с `Restart=on-failure`; правила — отдельный oneshot-unit (переживают reboot).

---

## 5. Вариант A — MTProto-прокси Telegram (`mtg` + `dc6`)

```
Telegram ──► [IPv6 сервера]:443  mtg
                  │ TCP к 149.154.x.x:443 (mtg знает только IPv4)
                  ▼
             dc6 (REDIRECT → 127.0.0.1:19191)
                  ▼
             [prefix::149.154.x.x]:443 ──► NAT64 ──► DC Telegram
```

### 5.1 Установка

```bash
# 1) бинарь mtg (на машине с IPv4 скачать, затем скопировать)
#    https://github.com/9seconds/mtg/releases  → mtg-<ver>-linux-amd64.tar.gz
install -m 755 mtg /usr/local/bin/mtg

# 2) dc6 — собрать из src/dc6/main.go (см. раздел 7) или взять готовый бинарь
install -m 755 dc6 /usr/local/bin/dc6

# 3) секрет (fake-TLS требует домен)
mtg generate-secret --hex cloudflare.com > /etc/mtg/secret
chmod 600 /etc/mtg/secret
SECRET=$(cat /etc/mtg/secret)

printf 'secret = "%s"\nbind-to = "0.0.0.0:443"\npublic-ipv6 = "%s"\n' \
  "$SECRET" "$(ip -6 addr show dev eth0 scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)" \
  > /etc/mtg/config.toml
```

### 5.2 Правила (oneshot `dc6-rules.service`)

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

```ini
# /etc/systemd/system/dc6.service
[Unit]
Description=dc6 - IPv4 to IPv6 bridge for MTProto datacenters
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/dc6
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/mtg.service
[Unit]
Description=MTProto proxy (mtg)
After=network-online.target dc6.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run /etc/mtg/config.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now dc6.service mtg.service
```

### 5.4 Проверка и ссылка

```bash
ss -tlnp | grep ':443 '                 # mtg слушает
journalctl -u dc6 -n 20                 # после любого соединения видно "bridge ... -> [prefix::...]:443"
mtg access /etc/mtg/config.toml         # tg:// и https://t.me/proxy ссылки + QR
```

Ссылка вида:

```
tg://proxy?port=443&secret=<base64url>&server=<IPv6 сервера>
```

---

## 6. Вариант B — AmneziaWG 3.1 с IPv4 для клиентов (`vpn4`)

```
клиент 10.90.0.2 ──awg0──► сервер 10.90.0.1
                              │ iptables REDIRECT (TCP всё, UDP/53)
                              ▼
                        vpn4 (19192 tcp, 5353 udp)
                              ▼
                   [prefix::<IPv4>] ──► NAT64 ──► интернет
```

### 6.1 Сервер (AmneziaWG уже поднят; см. `amneziawg.md`)

```bash
# IPv4 внутри туннеля
ip -4 addr replace 10.90.0.1/24 dev awg0
# peer клиента должен иметь оба адреса
sed -i 's|^AllowedIPs = .*|AllowedIPs = 10.90.0.2/32, fd90:1::2/128|' /etc/awg-owner/awg0.setconf.conf
awg setconf awg0 /etc/awg-owner/awg0.setconf.conf
```

`apply.py` сервера должен повторять это при старте (адрес + `net.ipv4.ip_forward=1`).

### 6.2 Правила (oneshot `vpn4-rules.service`)

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

`vpn4.service` — как `dc6.service`, но `ExecStart=/usr/local/bin/vpn4`, `After=awg-owner.service`.

### 6.3 Клиентский конфиг AmneziaWG

```ini
[Interface]
PrivateKey = <ключ клиента>
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
PublicKey = <публичный ключ сервера>
Endpoint = [<IPv6 сервера>]:51830
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

### 6.4 Проверка

```bash
ss -tlnp | grep 19192 ; ss -ulnp | grep 5353
iptables -t nat -S PREROUTING | grep awg0
# с клиента:
wget -4 -qO- http://1.1.1.1/cdn-cgi/trace   # покажет IPv4 выхода (NAT64 провайдера)
getent ahostsv4 example.com                  # DNS через 10.90.0.1
```

В логе `journalctl -u vpn4` видно:

```
tcp 10.90.0.2:52684 -> 1.1.1.1:80 via [2a01:4f8:c2c:123f:64:5:101:101]:80
```

---

## 7. Сборка бинарей

```bash
# на любой машине с Go (или на этом же сервере, если есть golang)
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o vpn4 main.go
```

Исходники: `src/dc6/main.go`, `src/vpn4/main.go`. Оба — stdlib + `syscall`, без зависимостей.

---

## 8. Ограничения (честно)

| Что | Статус |
|---|---|
| TCP (HTTP/S, Telegram, SSH, любые сервисы) | **работает полностью** |
| UDP DNS (порт 53) | работает через отдельный релей в `vpn4` |
| Остальной UDP (QUIC, игры, VoIP) | **не проходит**; браузеры откатываются на TCP |
| ICMP / ping | не работает |
| Endpoint | остаётся **только IPv6** — клиенту нужна IPv6-сеть |
| Выходной IPv4 | адрес NAT64 провайдера |

`dc6` (для mtg) транслирует **только TCP**, потому что MTProto-прокси ходит в дата-центры по TCP.

---

## 9. Чек-лист приёмки

1. `getent ahostsv6 ipv4only.arpa` → есть AAAA.
2. TCP-тест из шага 2 → `TCP OK`.
3. `systemctl is-enabled --quiet dc6-rules mtg` (или `vpn4-rules vpn4`) → exit 0.
4. `journalctl -u dc6` / `-u vpn4` содержит строку с `[prefix::...]` после реального соединения.
5. `mtg access` отдаёт ссылку (вариант A) / клиент получает IPv4-адрес (вариант B).
6. `iptables -t nat -S PREROUTING|OUTPUT` содержит REDIRECT-правила.

---

## 10. Откат

```bash
systemctl disable --now mtg dc6 dc6-rules          # вариант A
systemctl disable --now vpn4 vpn4-rules            # вариант B
iptables -t nat -F PREROUTING ; iptables -t nat -F OUTPUT   # аккуратно: снесёт и чужие правила
ip -4 route del <сеть> dev lo
```
