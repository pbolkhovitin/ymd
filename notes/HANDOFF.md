# HANDOFF — состояние и следующий шаг

Обновлено: 2026-11-13. Проект: `~/omv-leo/Projects/ym-noctalia`.

## Что это

Клиент Яндекс Музыки для **KDE Plasma 6**: плазмоид в панели + Rust-демон `ymd`.
Демон владеет токеном, API, GStreamer-плеером, MPRIS и кэшем. Плазмоид говорит
с ним по локальному HTTP (`127.0.0.1:8765`) и не видит токен.

## Что готово

| Слой | Состояние |
|---|---|
| `ymd` | API, OAuth/импорт токена, GStreamer, MPRIS, кэш, «Моя волна», качество |
| плазмоид | компакт в панели, попап, поиск, очередь, транспорт, seek, режимы |
| упаковка | `ymd_0.2.0_amd64.deb`, `plasma-widget-ymd_0.2.0_all.deb`, systemd --user |
| документация | README, docs/01–09, AGENTS, notes переписаны под KDE |

Факты порта и грабли: `notes/kde-port-findings.md`. План: `docs/superpowers/plans/2026-11-13-kde-plasmoid-port.md`.

## Проверки

```bash
bash packaging/run-tests.sh                 # 27 тестов в Docker (amd64)
node --test plasmoid/tests/format.test.js   # 6 тестов
bash scripts/docs-check.sh                  # ok
bash scripts/check-env.sh                   # окружение KDE/ymd
```

Сборка пакетов:

```bash
bash packaging/build-deb.sh --arch amd64
bash packaging/build-deb.sh --arch arm64
```

Установка на целевую машину:

```bash
sudo apt install ./dist/ymd_0.2.0_arm64.deb ./dist/plasma-widget-ymd_0.2.0_all.deb
systemctl --user enable --now ymd
ymd auth login
```

Плазмоид добавляется через «Добавить виджеты» → Yandex Music.

## Следующий шаг

1. **Тексты песен** — `api::lyrics()`, `GET /v1/lyrics`, `ymd lyrics`, кнопка в попапе.
   Разведка API: `notes/lyrics-findings.md`.
2. **Докачка после обрыва** — `.part` + `Range`, не начинать с нуля.
3. **Ynison** — WebSocket-синхронизация между устройствами (опционально).
4. **Отдельное приложение Qt/Kirigami** — после KDE-порта; тот же демон `ymd`
   по HTTP, окно вместо плазмоида. Нужна отдельная спека.

## Правила

- Плазмоид не видит токен и не ходит в API Яндекса.
- Цвета — `Kirigami.Theme` / `PlasmaComponents3`, без `#rrggbb`.
- Ноль анимаций по умолчанию.
- Факт → `docs/`, гипотеза → `notes/`.
