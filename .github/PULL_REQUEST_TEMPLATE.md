## Что меняется

<!-- Одно-два предложения: какую задачу решает PR. -->

## Клиент

<!-- Отметьте один: CI client-scope не пропускает PR, который правит
     noctalia/ и (plasmoid|app)/ одновременно. -->

- [ ] демон `daemon/`
- [ ] Noctalia `noctalia/`
- [ ] Plasma `plasmoid/`
- [ ] `ymd-qt` `app/`
- [ ] документация / пакеты / скрипты

## Проверки

- [ ] `bash scripts/docs-check.sh` → `ok`
- [ ] `bash scripts/version.sh --check` (если менялись манифесты)
- [ ] `cargo test -p ymd` или `bash packaging/run-tests.sh -p ymd`
- [ ] проверено живьём (что именно и на каком окружении)
- [ ] `CHANGELOG.md` обновлён в разделе `[Unreleased]`
- [ ] в клиентах нет токена и прямых запросов к API Яндекса

## Как проверить

<!-- Команды и ожидаемый результат. -->

```bash
```

## Связанные issue

<!-- Fixes #123 -->
