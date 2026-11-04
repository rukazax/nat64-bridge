#!/bin/bash
# nat64-probe.sh — определить NAT64-префикс провайдера и проверить, что TCP через него проходит.
# Запуск: sudo ./nat64-probe.sh [IPv4-адрес для теста]
set -uo pipefail

TEST_V4="${1:-1.1.1.1}"

echo "=== 1. IPv4-маршрут у хоста ==="
if ip -4 route show default | grep -q .; then
  echo "ВНИМАНИЕ: IPv4-маршрут есть — рецепт не нужен, используйте обычный NAT."
  ip -4 route show default
else
  echo "IPv4-маршрута нет (это то, что нужно)."
fi

echo
echo "=== 2. IPv6-адреса ==="
ip -6 addr show scope global | awk '/inet6/{print "  " $2}'

echo
echo "=== 3. Поиск NAT64-префикса (ipv4only.arpa) ==="
AAAA=$(getent ahostsv6 ipv4only.arpa 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$AAAA" ]; then
  echo "  AAAA не получен — DNS64 недоступен, рецепт неприменим."
  exit 1
fi
echo "  AAAA: $AAAA"

PREFIX=$(python3 - "$AAAA" <<'PY'
import sys, ipaddress
a = ipaddress.IPv6Address(sys.argv[1])
# последние 32 бита = 192.0.0.170 или 192.0.0.171 → отбрасываем
net = ipaddress.IPv6Network(f'{a}/96', strict=False)
print(str(net.network_address))
PY
)
echo "  NAT64-префикс: ${PREFIX}/96"

echo
echo "=== 4. ICMP через NAT64 ==="
ipv4hex() { python3 - "$1" <<'PY'
import sys
v4 = sys.argv[1].split('.')
print(':'.join(f'{int(v4[0])<<8|int(v4[1]):x}',) if False else f'{int(v4[0])<<8|int(v4[1]):x}:{int(v4[2])<<8|int(v4[3]):x}')
PY
}
TARGET6="${PREFIX}:$(ipv4hex "$TEST_V4")"
ping -6 -c 2 -W 3 "$TARGET6" 2>&1 | tail -2

echo
echo "=== 5. TCP через NAT64 (главная проверка) ==="
python3 - "$PREFIX" "$TEST_V4" <<'PY'
import socket, sys
P, v4 = sys.argv[1], sys.argv[2]
parts = [int(x) for x in v4.split('.')]
dst = f"{P}:{parts[0] << 8 | parts[1]:x}:{parts[2] << 8 | parts[3]:x}"
for port in (443, 80):
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.settimeout(8)
    try:
        s.connect((dst, port))
        print(f"  {dst}:{port} -> TCP OK")
    except Exception as e:
        print(f"  {dst}:{port} -> FAIL {e}")
    finally:
        s.close()
PY

echo
echo "Готово. Если TCP OK — можно ставить мост (install-dc6.sh / install-vpn4.sh)."
