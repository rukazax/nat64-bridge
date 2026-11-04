# Промт для агента: IPv4-сервисы на IPv6-only сервере (приём REDIRECT → SO_ORIGINAL_DST → IPv6 через NAT64)

> Скопируйте блок ниже целиком в чат агента, подставив свои значения в квадратных скобках.
> Промт самодостаточен: агент не видел предыдущей переписки.

---

## Задача

На сервере, у которого **нет IPv4-маршрута** (только IPv6), нужно поднять сервисы, которым нужен
IPv4-выход, и обеспечить им доступ в интернет по IPv4 через **NAT64 провайдера**.

Сервер: `[IP/хост]`, доступ `[ssh root@host -p port]`, пароль/ключ `[если есть]`.
Реализовать два сервиса (оба или те, что перечислены):

1. **MTProto-прокси Telegram** (`mtg`) — TCP 443, клиенты подключаются по IPv6.
2. **AmneziaWG-сервер** (`amneziawg-go` + `amneziawg-tools` 3.1) — клиенты туннеля должны получать
   рабочий IPv4-доступ.

## Условия и ограничения

* Не перезагружать сервер без необходимости; не менять чужие сервисы (проверьте `systemctl list-units`,
  не трогайте существующие VPN-стеки, их файлы и юниты).
* Не использовать kernel-модули (часто LXC) — только userspace.
* Не пытаться ставить `clatd`/`jool` (недоступны/не загрузятся).
* Не менять firewall глобально: только добавление собственных правил с комментарием.
* Все изменения — идемпотентными скриптами; правила и адреса — отдельным oneshot-unit, чтобы
  переживали перезагрузку.

## Ключевая идея (обязательно придерживаться)

У сервера нет IPv4-маршрута, но NAT64 провайдера пропускает трафик, если его открывает **наш процесс**
с нашего IPv6-адреса. Поэтому:

```
iptables -t nat REDIRECT  →  локальный процесс  →  SO_ORIGINAL_DST  →  dial tcp6 [prefix::<IPv4>]:port
```

* `SO_ORIGINAL_DST` = `getsockopt(fd, SOL_IP, 80)` (struct sockaddr_in).
* Перевод адреса: `<prefix>::a.b.c.d` = последние 32 бита.
* Для локально генерируемого трафика обязателен `ip -4 route replace <сеть> dev lo`, иначе connect
  отваливается с `ENETUNREACH` до срабатывания netfilter.
* Не пытаться делать CLAT через tayga: ответы приходят на локальный IPv6, ядро отвечает RST;
  блокировка пакетов в raw/PREROUTING лишает и tayga этих ответов. Это проверено, путь тупиковый.

## Порядок работы

1. **Диагностика.**
   ```bash
   ip -4 route show default ; ip -6 addr show scope global ; systemd-detect-virt
   getent ahostsv6 ipv4only.arpa      # определить NAT64-префикс /96
   ```
2. **Проверить TCP через NAT64** (питоном; `bash /dev/tcp` не умеет IPv6):
   подключиться к `[prefix::1.1.1.1]:443` и `[prefix::149.154.167.51]:443`. Должно быть `TCP OK`.
   Если TCP не проходит — остановиться и доложить, рецепт неприменим.
3. **Собрать мост.** Go, один файл, только stdlib+syscall, `CGO_ENABLED=0`. Два варианта:
   * `dc6` — слушает `127.0.0.1:19191`, для `mtg` (REDIRECT из `nat OUTPUT` по сетям Telegram
     `149.154.0.0/16`, `91.108.0.0/16`, `95.161.76.0/24`);
   * `vpn4` — слушает `0.0.0.0:19192` (TCP) и `0.0.0.0:5353` (UDP DNS-релей), REDIRECT из
     `nat PREROUTING -i awg0`.
4. **Установить и настроить** по шагам раздела «Установка» рецепта (systemd-units, rules-скрипт,
   firewall только для нужных портов).
5. **Проверить по-настоящему**, а не «сервис активен»:
   * `journalctl -u dc6`/`-u vpn4` — строка с реальным соединением `... -> [prefix::x.x.x.x]:443`;
   * `ss -tlnp` — порты слушаются;
   * для MTG: `mtg access` отдаёт рабочую `tg://`-ссылку, TCP+TLS-рукопожатие на `[IPv6]:443`
     проходит (fake-TLS);
   * для AWG: клиент в отдельном netns (`unshare -n`) получает IPv4 и `wget -4 http://1.1.1.1/cdn-cgi/trace`
     возвращает содержимое с IPv4-адресом выхода; DNS-запрос на `10.90.0.1:53` даёт `rcode: 0`.
6. **Зафиксировать**: oneshot-unit с правилами и маршрутами, `systemctl is-enabled` = enabled,
   после `systemctl restart` всех юнитов повторить проверку из п.5.
7. **Отчёт**: что установлено, выводы проверок (команды + результат), какие ограничения у решения,
   как откатить.

## Критерии приёмки

| Проверка | Ожидание |
|---|---|
| `getent ahostsv6 ipv4only.arpa` | AAAA с NAT64-префиксом |
| TCP-тест на `[prefix::1.1.1.1]:443` | `TCP OK` |
| `systemctl is-enabled dc6-rules mtg` (или `vpn4-rules vpn4`) | `enabled` |
| лог моста после реального соединения | `... -> [prefix::<IPv4>]:443` |
| MTG: fake-TLS на `[IPv6]:443` | рукопожатие TLS 1.3 проходит |
| AWG: с клиента `wget -4 http://1.1.1.1/cdn-cgi/trace` | отдаёт `ip=<IPv4 выхода>` |
| AWG: DNS на `10.90.0.1` | `rcode: 0`, есть ответы |

## Известные ограничения, которые нужно указать в отчёте

* Только TCP (плюс UDP/53 в варианте AWG). QUIC и прочий UDP не проходят — браузеры откатываются на TCP.
* ICMP не работает.
* Endpoint остаётся IPv6: клиенту нужна IPv6-сеть.
* Выходной IPv4 — адрес NAT64 провайдера.

## Запрещено

* Перезагружать сервер, менять чужие юниты/файлы, сносить существующие VPN-стеки.
* Ставить kernel-модули, `clatd`, `jool`, `tayga` (тупиковый путь, см. выше).
* Оставлять правила в `nat` без собственного комментария/скрипта.
* Отчитываться «работает» без фактических выводов команд.

---

# English short version (for reuse)

**Goal:** on an IPv6-only host (no IPv4 route), give IPv4 connectivity to services that dial IPv4
addresses, using the provider's NAT64 (`<prefix>::<ipv4>`).

**Technique:** `iptables -t nat REDIRECT` (OUTPUT for local processes, PREROUTING for forwarded
traffic) → a small static Go TCP relay → `getsockopt(SOL_IP, 80)` = `SO_ORIGINAL_DST` → `dial tcp6`
to `[prefix::<ipv4>]:port` → NAT64 → IPv4 internet.

**Must-do:** discover the /96 prefix via `getent ahostsv6 ipv4only.arpa`; verify TCP with python
(bash `/dev/tcp` cannot do IPv6); for locally generated traffic add `ip -4 route replace <net> dev lo`
before the netfilter hook; keep rules in a systemd oneshot unit.

**Do not:** use tayga/clatd/jool for a packet-level CLAT on this host — replies hit the local stack and
the kernel sends RST; dropping them in raw/PREROUTING also hides them from tayga. Verified dead end.

**Acceptance:** a real connection appears in the relay log as `... -> [prefix::x.x.x.x]:443`;
services are `enabled`; after restarting every unit, the end-to-end check still passes.
