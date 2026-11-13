# Noctalia UI: факты и грабли (2026-11-14)

Проверено живьём на Noctalia 5.4.1, niri, eDP-1 1920×1080, демон `ymd` 0.2.0.

## Форма данных discovery

- `/v1/discovery/metatags` → `{groups: [{id, title, tags: [{tag, title, children}]}]}`.
  Группы: `moods` «Настроения» 17 (2 с детьми), `activities` «Занятия» 11,
  `genres` «Жанры» 24 (18 с детьми), `epochs` «Эпохи» 9. Поля `trees`/`leaves`
  не существует — первая версия панели из-за этого показывала только жанры.
- `tag` — **отображаемая строка**, а не id: `/v1/discovery/tag?tag=mood:calm`
  отвечает 502 (`Metatag mood:calm not found`), а
  `?tag=Осенняя%20музыка` — 200 `{tag, title, station: "mood:autumn", playlists}`.
  Жанры наоборот: `/genres` даёт `id`, станция строится как `genre:<id>`.
- `/v1/discovery/tag` не всегда даёт `station`: у «Душевное» `station = null`,
  у «Осенняя музыка» — `mood:autumn`. Кнопка «Радио по подборке» показывается
  только при непустой станции.
- `/v1/home` — `blocks[].items[]` с `kind`: `playlist` (`uid`, `playlistKind`),
  `album` (`id`), чарт — плоские треки без `kind`.
- `/v1/album?id=` — volumes сплющены в один список треков; добавлен из-за
  карточки альбома на главной.

## Yoga/`ui.*`, из-за чего панель ломалась

1. **`ui.scroll` — только последний ребёнок корневого `ui.column`.** В Yoga нет
   `flexShrink` (в бинаре есть `flexGrow`, `minHeight`), поэтому скролл с
   контентом выдавливал вкладки и шапку за пределы панели. Порядок, который
   работает: header → track/progress → transport → nav → hint → scroll.
2. `height = 420` на корне не заменяет `flexGrow` и только добавляет артефакты.
3. `contentAlign = "start"` выравнивает текст кнопки по левому краю;
   `textAlign` принимается, но не работает.
4. Хот-релоад применяет изменения неатомарно: после правки структуры панель
   может отрисоваться с «раздутыми» контролами (кнопки-квадраты, съехавшая
   шапка). Лечится полным перезапуском: `pkill -x noctalia; nohup noctalia -d &`.
   `noctalia msg plugins update` файлы не перечитывает.

## Луа

- `local function`, объявленная ниже места вызова, не видна: получается
  глобал `nil` → «attempt to call a nil value» и панель отключается «после
  повторных таймаутов». Взаимные ссылки — только через forward-локалы.
- `repeat` — ключевое слово: поле JSON читается как `queue["repeat"]`.

## Проверки без мыши

Клик мышью и клавиатуру инжектировать нечем, панель фокуса не берёт. Поэтому
в `panel.luau` есть IPC-события для отладки:

```bash
noctalia msg plugin 'pbolkhovitin/yandex-music:panel' all view genres
noctalia msg plugin 'pbolkhovitin/yandex-music:panel' all tag 'Осенняя музыка'
noctalia msg plugin 'pbolkhovitin/yandex-music:panel' all refresh
```

Скриншоты: `grim -o eDP-1`, кроп 620×720+690+20, ×1.4. Панель открывается на
мониторе с фокусом — перед `panel-open` нужен `niri msg action focus-monitor eDP-1`.

## Что осталось непроверенным

- `tag_group` (вложенные теги) — только код, мышью не открыть.
- Ввод в `ui.input`: у панели нет клавиатурного фокуса, поиск в панели
  практически недоступен; закрывается из настроек/обзора.
- Поведение колеса и правого клика на строках списка.
