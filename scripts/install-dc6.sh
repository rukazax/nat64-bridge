#!/bin/bash
# install-dc6.sh — MTProto-прокси (mtg) + TCP-мост dc6 для IPv6-only сервера с NAT64.
#
# Использование (на сервере, root):
#   ./install-dc6.sh <NAT64_PREFIX> <FAKE_TLS_DOMAIN> [MTG_ARCHIVE_OR_BINARY]
# Пример:
#   ./install-dc6.sh 2a01:4f8:c2c:123f:64:5 cloudflare.com /tmp/mtg
#
# Ожидает рядом с собой собранный бинарь dc6 (или DC6_BIN=/путь/к/dc6).
set -euo pipefail

PREFIX="${1:?укажите NAT64-префикс /96 без маски, напр. 2a01:4f8:c2c:123f:64:5}"
DOMAIN="${2:?укажите домен для fake-TLS, напр. cloudflare.com}"
MTG_SRC="${3:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
DC6_BIN="${DC6_BIN:-$HERE/dc6}"
PROXY_PORT=19191
PORT=443

echo "=== префикс: $PREFIX, домен: $DOMAIN ==="
[ -x "$DC6_BIN" ] || { echo "нет бинаря dc6: $DC6_BIN"; exit 1; }

# dc6 зашивает префикс в константу — проверим, что он совпадает
if ! grep -aq "$PREFIX" "$DC6_BIN"; then
  echo "ВНИМАНИЕ: бинарь dc6 собран с другим префиксом. Пересоберите src/dc6/main.go с nPrefix=$PREFIX"
fi

# ---------- mtg ----------
if [ -z "$(command -v mtg 2>/dev/null)" ] && [ ! -x /usr/local/bin/mtg ]; then
  [ -n "$MTG_SRC" ] || { echo "укажите путь к бинарю/архиву mtg третьим аргументом"; exit 1; }
  case "$MTG_SRC" in
    *.tar.gz) TMP=$(mktemp -d); tar -xzf "$MTG_SRC" -C "$TMP"; install -m 755 "$TMP"/*/mtg /usr/local/bin/mtg || install -m 755 "$TMP"/mtg /usr/local/bin/mtg ;;
    *) install -m 755 "$MTG_SRC" /usr/local/bin/mtg ;;
  esac
fi
install -m 755 "$DC6_BIN" /usr/local/bin/dc6

mkdir -p /etc/mtg
if [ ! -s /etc/mtg/secret ]; then
  /usr/local/bin/mtg generate-secret --hex "$DOMAIN" > /etc/mtg/secret
  chmod 600 /etc/mtg/secret
fi
SECRET=$(cat /etc/mtg/secret)
HOST6=$(ip -6 addr show dev eth0 scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)
printf 'secret = "%s"\nbind-to = "0.0.0.0:%s"\npublic-ipv6 = "%s"\n' "$SECRET" "$PORT" "$HOST6" > /etc/mtg/config.toml

# ---------- units ----------
cat > /etc/systemd/system/dc6.service <<'UNIT'
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
UNIT

cat > /etc/systemd/system/mtg.service <<'UNIT'
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
UNIT

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

cat > /etc/systemd/system/dc6-rules.service <<'UNIT'
[Unit]
Description=dc6 routing and firewall rules
After=network-online.target
Wants=network-online.target
Before=dc6.service mtg.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/dc6-rules.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now dc6-rules.service dc6.service mtg.service
sleep 3

echo
echo "=== проверка ==="
systemctl is-active dc6 mtg dc6-rules || true
ss -tlnp | grep ":${PORT} " || echo "порт ${PORT} не слушается!"
iptables -t nat -S OUTPUT | grep REDIRECT || true
echo
echo "=== ссылка ==="
/usr/local/bin/mtg access /etc/mtg/config.toml 2>/dev/null | sed -n '1,12p' || \
  echo "tg://proxy?server=${HOST6}&port=${PORT}&secret=${SECRET}"
echo
echo "Проверка моста: подключитесь к дата-центру изнутри и посмотрите лог:"
echo "  journalctl -u dc6 -n 20"
