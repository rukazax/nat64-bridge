# CI

`ci/ci.yml` — готовый workflow GitHub Actions: `bash -n`, `shellcheck -S error`, `go vet` +
статическая сборка `dc6` и `vpn4`, проверка относительных ссылок в Markdown и валидности SVG.

## Почему он лежит здесь, а не в `.github/workflows/`

Файлы `.github/workflows/*` можно создать через API только токеном со scope **`workflow`**.
Токен, которым публиковался репозиторий, имеет `repo` и `read:user`; API отвечает `404` на попытку
записать workflow. Это ограничение GitHub, а не ошибка конфигурации.

## Как включить

**Вариант 1 — через веб-интерфейс (без токена):**

1. Откройте репозиторий → **Add file → Create new file**.
2. Имя: `.github/workflows/ci.yml`.
3. Вставьте содержимое `ci/ci.yml`, нажмите **Commit changes**.

**Вариант 2 — расширить токен:**

```bash
# переавторизоваться с нужными scope (интерактивно)
gh auth refresh -s workflow        # если установлен GitHub CLI
# или выпустить новый PAT с галочкой "workflow" и заменить токен в ~/.dsh/secrets/github.json
```

После этого достаточно скопировать файл:

```bash
mkdir -p .github/workflows && cp ci/ci.yml .github/workflows/ci.yml
git add .github/workflows/ci.yml && git commit -m "ci: enable workflow" && git push
```

## Локальный прогон тех же проверок

Без GitHub Actions всё проверяется одной командой:

```bash
./scripts/ci-local.sh
```

Скрипт делает ровно то же, что джобы в `ci/ci.yml`, и возвращает ненулевой код при провале.
