# nat64-bridge

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**IPv4-сервисы на IPv6-only сервере через NAT64 провайдера.**
Приём: `REDIRECT → SO_ORIGINAL_DST → соединение по IPv6 на <prefix>::<IPv4>`.

[English](README.en.md) · [Рецепт](docs/ru/recipe.md) · [AmneziaWG 3.1](docs/ru/amneziawg.md) · [Промт для агента](prompts/PROMPT.ru.md) · [CI](ci/README.md)

![Схема работы](assets/diagram.svg)

---

## Проблема

Сервер без IPv4-маршрута (`ip -4 route` пуст), но у провайдера есть DNS64/NAT64. Сервисам нужен
IPv4-выход: MTProto-прокси Telegram ходит на IPv4-адреса дата-центров, клиентам AmneziaWG нужен
обычный IPv4-интернет. Классический CLAT (`tayga`, `clatd`, `jool`) на таком хосте не работает —
ответы приходят на локальный IPv6, ядро отвечает `RST`.

## Решение

Соединение открывает **наш собственный процесс** с нашего IPv6-адреса, поэтому ответы доставляются
его сокету:

```
iptables -t nat REDIRECT  →  локальный Go-релей  →  SO_ORIGINAL_DST  →  dial tcp6 [prefix::IPv4]:port
                                            ▼
                                  NAT64 провайдера  →  IPv4-интернет
```

Два готовых сервиса:

| Сервис | Назначение | Порты |
|---|---|---|
| **`dc6`** | IPv4→IPv6 мост для `mtg` (MTProto-прокси Telegram) | слушает `127.0.0.1:19191` |
| **`vpn4`** | IPv4 для клиентов AmneziaWG (+ DNS через NAT64) | `0.0.0.0:19192/tcp`, `0.0.0.0:5353/udp` |

## Быстрый старт

```bash
# 1. Убедиться, что приём применим (найдёт префикс и проверит TCP через NAT64)
sudo ./scripts/nat64-probe.sh

# 2. Собрать мост (Go 1.24+, статический бинарь)
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o dc6  src/dc6/main.go

# 3. Поставить (вариант MTProto)
sudo ./scripts/install-dc6.sh 2a01:4f8:c2c:123f:64:5 cloudflare.com

# 4. Приёмка
sudo ./scripts/verify.sh
```

Для AmneziaWG — `scripts/install-vpn4.sh` и клиентский конфиг из [рецепта](docs/ru/recipe.md).

## Что внутри

| Путь | Содержание |
|---|---|
| `docs/ru`, `docs/en` | полный рецепт, сборка AmneziaWG 3.1, детали MTProto |
| `prompts/` | готовые промты для агента (RU / EN) — воспроизвести приём на другом сервере |
| `src/dc6`, `src/vpn4` | исходники мостов (Go, только stdlib + `syscall`) |
| `scripts/` | `nat64-probe.sh`, `install-dc6.sh`, `install-vpn4.sh`, `verify.sh` |
| `assets/diagram.svg` | схема работы |

## Ограничения

- **TCP работает полностью**; UDP — только DNS (53) в варианте `vpn4`. QUIC и прочий UDP не проходят
  (браузеры откатываются на TCP).
- **ICMP/ping не работает.**
- **Endpoint остаётся IPv6** — клиенту нужна IPv6-сеть.
- Выходной IPv4 — адрес NAT64-провайдера.

## Проверено на

Ubuntu 22.04 в LXC (ядро Proxmox 6.8.12-pve), IPv6-only `2a0c:…`, NAT64 `2a01:4f8:c2c:123f:64:5::/96`:
`mtg` 2.3.0 + Telegram DC через мост, `amneziawg-go` 3.1 + IPv4 в туннеле (DNS и HTTPS через NAT64).

## Лицензия

MIT — см. [LICENSE](LICENSE).
