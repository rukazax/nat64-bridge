#!/bin/bash
# ci-local.sh — прогнать локально те же проверки, что описаны в ci/ci.yml.
# Использование: ./scripts/ci-local.sh   (из корня репозитория)
# Требуется: bash, python3. Желательно: shellcheck, go.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
skip() { echo "  [skip] $*"; }

echo "=== 1. bash -n ==="
for f in scripts/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "$f"; else fail "$f"; fi
done

echo "=== 2. shellcheck (errors only) ==="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error scripts/*.sh; then pass "shellcheck"; else fail "shellcheck"; fi
else
  skip "shellcheck не установлен"
fi

echo "=== 3. go vet + static build ==="
if command -v go >/dev/null 2>&1; then
  for b in dc6 vpn4; do
    if go vet "./src/$b/main.go" 2>/dev/null; then pass "go vet $b"; else fail "go vet $b"; fi
    if CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "/tmp/ci-$b" "src/$b/main.go" 2>/dev/null; then
      pass "build $b ($(du -h "/tmp/ci-$b" | cut -f1))"
    else
      fail "build $b"
    fi
  done
else
  skip "go не установлен"
fi

echo "=== 4. относительные ссылки в Markdown ==="
if python3 scripts/check-links.py; then pass "links"; else fail "links"; fi

echo "=== 5. SVG ==="
if python3 - <<'PY'
import glob, sys, xml.etree.ElementTree as ET
files = glob.glob('assets/*.svg')
if not files:
    sys.exit(1)
for f in files:
    ET.parse(f)
    print('OK', f)
PY
then pass "svg"; else fail "svg"; fi

echo
if [ "$FAIL" -eq 0 ]; then echo "ИТОГ: все проверки пройдены"; else echo "ИТОГ: провалов — $FAIL"; fi
exit "$FAIL"
