# 09. Проверки окружения и история P0

P0 закрыт: неизвестности вокруг API Яндекса, GStreamer, MPRIS и
capability-ключа сняты. Этот документ — краткая история и инструкция
для проверки нового хоста, а не пошаговый спайк.

## Что проверяли в P0

| # | Проверка | Итог |
|---|---|---|
| S1 | Версия Noctalia и `plugin_api` | неактуально: переход на Plasma 6 |
| S2 | Методы `barWidget.*` | неактуально: QML-плазмоид |
| S3 | `ui.*` в баре и панели | неактуально: QML-плазмоид |
| S4 | SSE через `httpStream` | неактуально: polling |
| S5 | Чтение capability-ключа | решено командой `ymd session-key` |
| S6 | MPRIS виден шеллу | ✅ `playerctl` и виджет `media` работают |
| S7 | GStreamer → PipeWire | ✅ `playbin3` + `autoaudiosink` |
| S8 | niri IPC | неактуально: KDE Plasma |
| S9 | Свой OAuth loopback | не понадобился: Device Flow / импорт токена |

Факты P0 сохранены в `notes/p0-findings.md` как история; для KDE-версии
актуальны `notes/kde-port-findings.md` и `notes/m1-findings.md` …
`notes/m4-findings.md`.

## Проверка нового хоста

```bash
# 1. Демон и ключ
ymd doctor
KEY="$(ymd session-key)"
curl -s http://127.0.0.1:8765/v1/health
curl -s -H "X-YMD-Session: $KEY" http://127.0.0.1:8765/v1/state

# 2. Плазмоид
kpackagetool6 --type Plasma/Applet --list | grep pbolkhovitin
journalctl --user -u plasma-plasmashell -b | grep -i pbolkhovitin

# 3. MPRIS
playerctl --list-all
playerctl --player=ymd metadata

# 4. Звук
gst-launch-1.0 --version
pactl info | grep -i "server name"

# 5. Автоматическая проверка
bash scripts/check-env.sh
```

`scripts/check-env.sh` проверяет Plasma, QML-модули, демон, ключ, MPRIS,
GStreamer/PipeWire и печатает apt-подсказки. Предупреждения не являются
ошибкой: без части пакетов доступны не все возможности.

## Definition of Done для KDE-версии

- [x] Демон собирается и проходит 27 тестов в Docker.
- [x] `ymd session-key` работает.
- [x] Плазмоид устанавливается через `kpackagetool6`.
- [x] Попап открывается, поиск и очередь отображаются.
- [x] `.deb` собирается для amd64 и arm64.
- [x] systemd --user unit устанавливается.
- [x] Документация и скрипты обновлены.
- [x] gitleaks чист.

## Если что-то не работает

| Симптом | Проверка |
|---|---|
| «Ключ не найден» | `ymd serve` запущен? `ymd session-key` печатает ключ? |
| «Нет связи с ymd» | `curl 127.0.0.1:8765/v1/health`, порт в настройках плазмоида |
| Нет звука | `pactl info`, `gst-launch-1.0 playbin3 uri=file://…` |
| Нет трека в MPRIS | `playerctl --list-all`, `systemctl --user status ymd` |
| Плазмоид не виден | `kpackagetool6 --list`, перезапуск plasmashell |
| Ошибка QML | `journalctl --user -u plasma-plasmashell -b | grep -i pbolkhovitin` |
