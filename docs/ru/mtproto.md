# MTProto-прокси Telegram на IPv6-only сервере (`mtg` + `dc6`)

Дополнение к [рецепту](recipe.md): детали варианта A.

## Схема

```
Telegram-клиент ──IPv6──► [<IPv6 сервера>]:443  ── mtg
                                                   │ TCP → 149.154.x.x:443
                                                   ▼
                                        dc6 (REDIRECT → 127.0.0.1:19191)
                                                   ▼
                                        [prefix::149.154.x.x]:443
                                                   ▼
                                        NAT64 провайдера → DC Telegram
```

`mtg` знает только IPv4-адреса дата-центров, а IPv4-маршрута у сервера нет. `dc6` перехватывает
эти соединения и открывает их по IPv6.

## 1. Почему REDIRECT в `OUTPUT`, а не `PREROUTING`

`mtg` — локальный процесс сервера. Его исходящие соединения проходят через `nat OUTPUT`.
REDIRECT там сохраняет исходный адрес назначения, и `dc6` читает его через `SO_ORIGINAL_DST`.

Важно: маршрут до сетей Telegram должен существовать, иначе connect падает `ENETUNREACH`
до срабатывания netfilter:

```bash
ip -4 route replace 149.154.0.0/16 dev lo
ip -4 route replace 91.108.0.0/16  dev lo
ip -4 route replace 95.161.76.0/24 dev lo
```

## 2. Секрет

```bash
mtg generate-secret --hex cloudflare.com > /etc/mtg/secret   # fake-TLS, нужен домен
cat /etc/mtg/secret      # ee… (hex) — в ссылке можно и base64url
```

`mtg generate-secret` **требует домен** — без него команда падает (`expected "<hostname>"`) и
секрет остаётся пустым, а сервис не стартует (`secret is empty`).

Домен должен иметь AAAA-запись, иначе в логе появится предупреждение `SNI-DNS check: cannot resolve`
— на работу это не влияет.

## 3. Конфиг

```toml
# /etc/mtg/config.toml
secret = "ee…"
bind-to = "0.0.0.0:443"
public-ipv6 = "2a0c:b641:1a0:800::2a2"
```

`public-ipv6` убирает предупреждение `cannot detect public IP address`.

## 4. Ссылка

```bash
mtg access /etc/mtg/config.toml
# tg_url: tg://proxy?port=443&secret=<base64url>&server=<IPv6 с %3A>
```

Клиенты Telegram принимают IPv6-адрес в `server=` (URL-кодированный), а также сканируют QR из
`tg_qrcode`. Секрет подходит в двух формах: hex (`ee…`) и base64url — обе валидны.

## 5. Проверка

```bash
ss -tlnp | grep ':443 '                     # mtg слушает (IPv4+IPv6)
journalctl -u dc6 -n 20                     # после реального соединения:
#   bridge 10.x.x.x:port (149.154.167.51:443) -> [2a01:4f8:c2c:123f:64:5:959a:a733]:443
journalctl -u mtg -n 20
```

Fake-TLS можно проверить локально:

```python
import socket, ssl
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(8)
s.connect(('2a0c:…', 443))
t = ssl._create_unverified_context().wrap_socket(s, server_hostname='cloudflare.com')
print('TLS', t.version())      # ожидается TLSv1.3
```

## 6. Частые проблемы

| Симптом | Причина | Решение |
|---|---|---|
| `secret is empty` в journal | `generate-secret` без домена | `mtg generate-secret --hex <домен>` и рестарт |
| connect → `Network is unreachable` | нет IPv4-маршрута до сетей Telegram | `ip -4 route replace <net> dev lo` |
| в логе dc6 нет строк, клиент не подключается | NAT64 не пропускает TCP | перепроверить шаг 2 рецепта |
| ссылка открывается, но «Прокси недоступен» | у клиента нет IPv6 | подключиться из IPv6-сети (мобильный интернет) |
| `SNI-DNS check: address mismatch` | норма для fake-TLS | игнорировать |

## 7. Откат

```bash
systemctl disable --now mtg dc6 dc6-rules
rm -rf /etc/mtg
```
