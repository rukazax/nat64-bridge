#!/bin/bash
# install-vpn4.sh — IPv4 для клиентов AmneziaWG через NAT64 (мост vpn4).
#
# Использование (на сервере, root, когда awg0 уже поднят):
#   ./install-vpn4.sh <NAT64_PREFIX> [AWG_IFACE] [CLIENT_V4] [SERVER_V4]
# Пример:
#   ./install-vpn4.sh 2a01:4f8:c2c:123f:64:5 awg0 10.90.0.2 10.90.0.1
#
# Ожидает собранный бинарь vpn4 рядом (или VPN4_BIN=/путь/к/vpn4).
set -euo pipefail

PREFIX="${1:?укажите NAT64-префикс /96, напр. 2a01:4f8:c2c:123f:64:5}"
IFACE="${2:-awg0}"
CLIENT_V4="${3:-10.90.0.2}"
SERVER_V4="${4:-10.90.0.1}"
TCP_PORT=19192
DNS_PORT=5353

HERE="$(cd "$(dirname "$0")" && pwd)"
VPN4_BIN="${VPN4_BIN:-$HERE/vpn4}"

[ -x "$VPN4_BIN" ] || { echo "нет бинаря vpn4: $VPN4_BIN"; exit 1; }
if ! grep -aq "$PREFIX" "$VPN4_BIN"; then
  echo "ВНИМАНИЕ: бинарь собран с другим префиксом — пересоберите src/vpn4/main.go (nPrefix)."
fi

install -m 755 "$VPN4_BIN" /usr/local/bin/vpn4

# адрес сервера внутри туннеля
ip link set "$IFACE" up
ip -4 addr replace "${SERVER_V4}/24" dev "$IFACE"

# peer должен разрешать IPv4-адрес клиента
CONF="/etc/awg-owner/awg0.setconf.conf"
if [ -f "$CONF" ]; then
  CLIENT_V6=$(grep -oE 'fd[0-9a-fA-F:]+::[0-9]+/128' "$CONF" | head -1)
  if [ -n "$CLIENT_V6" ]; then
    sed -i "s|^AllowedIPs = .*|AllowedIPs = ${CLIENT_V4}/32, ${CLIENT_V6}|" "$CONF"
    /usr/local/bin/awg setconf "$IFACE" "$CONF" && echo "peer обновлён: AllowedIPs = ${CLIENT_V4}/32, ${CLIENT_V6}"
  else
    echo "в $CONF не найден IPv6 клиента (/128). Добавьте AllowedIPs = ${CLIENT_V4}/32, <IPv6 клиента>/128 вручную"
  fi
else
  echo "не найден $CONF — добавьте ${CLIENT_V4}/32 в AllowedIPs пира вручную"
fi

# ---------- rules ----------
cat > /usr/local/sbin/vpn4-rules.sh <<SH
#!/bin/sh
set -u
ip link set ${IFACE} up 2>/dev/null || true
ip -4 addr replace ${SERVER_V4}/24 dev ${IFACE} 2>/dev/null || true
iptables -t nat -C PREROUTING -i ${IFACE} -p tcp -j REDIRECT --to-ports ${TCP_PORT} 2>/dev/null || \\
  iptables -t nat -A PREROUTING -i ${IFACE} -p tcp -j REDIRECT --to-ports ${TCP_PORT}
iptables -t nat -C PREROUTING -i ${IFACE} -p udp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} 2>/dev/null || \\
  iptables -t nat -A PREROUTING -i ${IFACE} -p udp --dport 53 -j REDIRECT --to-ports ${DNS_PORT}
iptables -C FORWARD -i ${IFACE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${IFACE} -j ACCEPT
iptables -C FORWARD -o ${IFACE} -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ${IFACE} -j ACCEPT
sysctl -q -w net.ipv4.ip_forward=1
SH
chmod 755 /usr/local/sbin/vpn4-rules.sh

cat > /etc/systemd/system/vpn4.service <<'UNIT'
[Unit]
Description=vpn4 - IPv4 over NAT64 for AmneziaWG clients
After=network-online.target awg-owner.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vpn4
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/vpn4-rules.service <<'UNIT'
[Unit]
Description=vpn4 routing and firewall rules
After=network-online.target awg-owner.service
Wants=network-online.target
Before=vpn4.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn4-rules.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now vpn4-rules.service vpn4.service
sleep 2

echo
echo "=== проверка ==="
systemctl is-active vpn4 vpn4-rules || true
ss -tlnp | grep ":${TCP_PORT} " || echo "TCP ${TCP_PORT} не слушается!"
ss -ulnp | grep ":${DNS_PORT} " || echo "UDP ${DNS_PORT} не слушается!"
iptables -t nat -S PREROUTING | grep -E "${TCP_PORT}|${DNS_PORT}" || true
ip -4 addr show dev "$IFACE" | head -3
echo
echo "Клиентский конфиг: Address = ${CLIENT_V4}/24, <IPv6 клиента>/128 ; DNS = ${SERVER_V4} ; AllowedIPs = 0.0.0.0/0, ::/0"
echo "Проверка с клиента: wget -4 -qO- http://1.1.1.1/cdn-cgi/trace"
echo "Лог моста: journalctl -u vpn4 -n 30"
