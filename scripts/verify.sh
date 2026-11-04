#!/bin/bash
# verify.sh — приёмка рецепта на живом сервере.
# Запуск: sudo ./verify.sh [NAT64_PREFIX]
# Проверяет: префикс, TCP через NAT64, юниты, правила, движение через мост.
set -uo pipefail

PREFIX="${1:-}"
FAIL=0
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [ .. ] $*"; }

echo "=== 1. IPv6 и отсутствие IPv4 ==="
ip -6 addr show scope global | awk '/inet6/{print "  IPv6:" $2}'
if ip -4 route show default | grep -q .; then bad "у сервера есть IPv4-маршрут (рецепт не нужен)"; else ok "IPv4-маршрута нет"; fi

echo "=== 2. NAT64-префикс ==="
AAAA=$(getent ahostsv6 ipv4only.arpa 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$AAAA" ]; then bad "DNS64 не отвечает"; else
  DETECTED=$(python3 -c "import ipaddress,sys; print(str(ipaddress.IPv6Network(f'{sys.argv[1]}/96', strict=False).network_address))" "$AAAA")
  ok "DNS64 AAAA: $AAAA  →  префикс ${DETECTED}/96"
  [ -n "$PREFIX" ] || PREFIX="$DETECTED"
fi
[ -n "$PREFIX" ] || { echo "Не удалось определить префикс"; exit 1; }

echo "=== 3. TCP через NAT64 (1.1.1.1:443) ==="
if python3 - "$PREFIX" <<'PY'
import socket, sys
P = sys.argv[1]
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(8)
try:
    s.connect((f'{P}:101:101', 443)); print('connected'); sys.exit(0)
except Exception as e:
    print('fail', e); sys.exit(1)
finally:
    s.close()
PY
then ok "TCP через NAT64 проходит"; else bad "TCP через NAT64 не проходит — мост работать не будет"; fi

echo "=== 4. Юниты ==="
for u in dc6 dc6-rules vpn4 vpn4-rules mtg; do
  if systemctl list-unit-files | grep -q "^${u}.service"; then
    en=$(systemctl is-enabled "$u" 2>/dev/null || echo no)
    ac=$(systemctl is-active "$u" 2>/dev/null || echo no)
    if [ "$en" = enabled ] && [ "$ac" = active ]; then ok "$u: enabled/active"; else bad "$u: enabled=$en active=$ac"; fi
  fi
done

echo "=== 5. Прослушиваемые порты ==="
for p in 19191 19192 5353 443; do
  if ss -tlnp 2>/dev/null | grep -q ":${p} " || ss -ulnp 2>/dev/null | grep -q ":${p} "; then
    ok "порт $p слушается"
  else
    info "порт $p не слушается (может быть не нужен для этого варианта)"
  fi
done

echo "=== 6. Правила netfilter ==="
if iptables -t nat -S 2>/dev/null | grep -qE 'REDIRECT --to-ports (19191|19192)'; then
  ok "REDIRECT-правила на месте"
  iptables -t nat -S | grep REDIRECT | sed 's/^/    /'
else
  bad "нет REDIRECT-правил"
fi

echo "=== 7. Маршруты для локального трафика (вариант dc6) ==="
for net in 149.154.0.0/16 91.108.0.0/16 95.161.76.0/24; do
  if ip -4 route show | grep -q "^${net} dev lo"; then ok "маршрут $net → lo"; else info "маршрута $net нет (нужен только для mtg)"; fi
done

echo "=== 8. Реальный трафик через мост ==="
if command -v mtg >/dev/null 2>&1 && [ -f /etc/mtg/config.toml ]; then
  info "проверка моста dc6: подключитесь клиентом к Telegram и проверьте журнал"
fi
for u in dc6 vpn4; do
  if systemctl list-unit-files | grep -q "^${u}.service"; then
    lines=$(journalctl -u "$u" --no-pager 2>/dev/null | grep -c "\[${PREFIX}")
    if [ "$lines" -gt 0 ]; then ok "$u: $lines соединений через NAT64 в журнале"; else info "$u: пока нет соединений (нужен реальный запрос)"; fi
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then echo "ИТОГ: все критичные проверки пройдены."; else echo "ИТОГ: провалено проверок — $FAIL"; fi
exit "$FAIL"
