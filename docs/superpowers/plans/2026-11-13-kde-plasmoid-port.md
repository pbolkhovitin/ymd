# KDE Plasma 6 / aarch64 Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Noctalia/Luau plugin with a native KDE Plasma 6 plasmoid and ship installable `ymd` + plasmoid `.deb` packages for Ubuntu 26.04 on aarch64.

**Architecture:** The existing Rust daemon keeps its local HTTP API and MPRIS export. A new QML plasmoid (`io.github.pbolkhovitin.ymd`) polls `/v1/state` over HTTP (1 s while playing, 3 s otherwise), reads the capability key through the new `ymd session-key` command, and sends commands to `/v1/cmd`. Packaging runs inside Ubuntu 26.04 containers (`--platform linux/arm64` under QEMU, `linux/amd64` for fast tests) and produces two `.deb` files.

**Tech Stack:** Rust (axum, GStreamer, zbus), QML/Qt 6 (Plasma 6, Kirigami, PlasmaComponents3, Plasma5Support), Bash, Docker, dpkg-deb.

**Spec:** `docs/superpowers/specs/2026-11-13-kde-plasmoid-port-design.md`

## Global Constraints

- Target OS: Ubuntu 26.04 LTS, architecture `arm64`; development checks may use `amd64`.
- Plasmoid id: `io.github.pbolkhovitin.ymd`; version `0.2.0` everywhere (`Cargo.toml`, `plasmoid/metadata.json`, both `.deb`).
- The plasmoid never calls the Yandex API and never stores a token; only the daemon does.
- The plasmoid authenticates with `X-YMD-Session`; the key is read only via `ymd session-key`.
- No `#rrggbb` literals in QML: colors come from `Kirigami.Theme` (`textColor`, `highlightColor`, `backgroundColor`, `activeTextColor`).
- Zero animations: no `Behavior`, no `NumberAnimation`, no frame tickers.
- Polling intervals: 1000 ms when `state.status === "playing"`, otherwise 3000 ms. No SSE in the plasmoid.
- Do not write to the installed package directory; the plasmoid is read-only at runtime.
- Package names: `ymd` (arch `arm64`/`amd64`) and `plasma-widget-ymd` (arch `all`), with `plasma-widget-ymd` recommending `ymd`.
- Every task ends with a commit. Push after Tasks 1, 4, 5, and 7.
- Before every push: `bash scripts/docs-check.sh` returns `ok` and `gitleaks` finds nothing.

## Review Focus

- **Daemon absent or key missing:** the compact widget must show a readable hint (`ymd` / «Демон не запущен»), not a QML error, and must recover when the daemon starts.
- **Daemon restart / stale key:** a `401` must trigger exactly one key re-read; a second failure becomes a visible hint instead of a request loop.
- **Incomplete track metadata:** missing cover, empty `artists`, or `durationMs == 0` must not break the popup; seek is disabled when duration is zero.
- **Long text and vertical panels:** titles are truncated to 34 characters in the compact widget; a vertical panel shows the icon only.
- **Popup open during track change or seek drag:** polling must not overwrite the slider while the user drags it, and a track change must refresh cover/title without stale values.

---

### Task 1: Daemon `session-key`, version 0.2.0, KDE doctor, containerized tests

**Files:**
- Create: `packaging/Dockerfile`
- Create: `packaging/run-tests.sh`
- Modify: `Cargo.toml` (`[workspace.package] version`)
- Modify: `Cargo.lock` (regenerated)
- Modify: `daemon/Cargo.toml` (description)
- Modify: `daemon/src/main.rs`
- Modify: `daemon/src/session.rs` (doc comment only)
- Modify: `daemon/src/doctor.rs`
- Modify: `daemon/src/state.rs` (doc comment only)
- Modify: `docs/04-daemon.md`
- Create: `notes/kde-port-findings.md`
- Modify: `AGENTS.md` (state table rows for `main.rs`, `session.rs`, `doctor.rs`)

**Interfaces:**
- Consumes: `session::read_key() -> std::io::Result<Option<String>>`, `session::key_path() -> PathBuf`.
- Produces: `ymd session-key` prints the 32-hex key followed by a newline and exits 0; if the key is missing it exits 1 with `session.key не найден — запущен ли «ymd serve»?`.
- Produces: `packaging/run-tests.sh [cargo test args...]` runs `cargo test` in the `ymd-builder:amd64` container with host-owned caches.
- Produces: container image `ymd-builder:amd64` with Rust, GStreamer dev headers, `dpkg-dev`, and `file`.

- [ ] **Step 1: Create the build/test container**

`packaging/Dockerfile`:

```dockerfile
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config curl ca-certificates git \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    dpkg-dev file \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --no-modify-path \
    && chmod -R a+rwX /usr/local/rustup /usr/local/cargo
WORKDIR /work
```

`packaging/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch=amd64
mkdir -p "packaging/.cache/cargo-$arch" "packaging/.cache/target-$arch"
docker build --platform linux/amd64 -t "ymd-builder:$arch" packaging
docker run --rm --platform linux/amd64 \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e CARGO_HOME="/work/packaging/.cache/cargo-$arch" \
  -e CARGO_TARGET_DIR="/work/packaging/.cache/target-$arch" \
  -v "$PWD:/work" -w /work \
  "ymd-builder:$arch" cargo test "$@"
```

Make it executable: `chmod +x packaging/run-tests.sh`. Add `packaging/.cache/` and `dist/` to `.gitignore`.

- [ ] **Step 2: Write the failing CLI test**

Append to `daemon/src/main.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_key_subcommand_parses() {
        let cli = Cli::try_parse_from(["ymd", "session-key"]).expect("parse");
        assert!(matches!(cli.command, Command::SessionKey));
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `packaging/run-tests.sh session_key_subcommand_parses`

Expected: compilation error `no variant or associated item named 'SessionKey' found`.

- [ ] **Step 4: Implement the subcommand and bump the version**

In `daemon/src/main.rs` add after `Serve`:

```rust
/// Напечатать capability-ключ локального API (для плазмоида KDE).
SessionKey,
```

In the `match Cli::parse().command` block add:

```rust
Command::SessionKey => {
    println!("{}", key()?);
    Ok(())
}
```

Change `Cargo.toml`:

```toml
[workspace.package]
version = "0.2.0"
```

Update the stale module comments and metadata: `daemon/src/main.rs` header and `#[command(about = ...)]` (remove «P0 skeleton», describe KDE/Plasma), `daemon/Cargo.toml` `description`, `daemon/src/session.rs` (plasmoid instead of `noctalia.readFile`), `daemon/src/state.rs` («его читает плазмоид»).

- [ ] **Step 5: Update `ymd doctor` for Ubuntu/KDE**

In `daemon/src/doctor.rs` replace the niri block with:

```rust
let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
let kde = desktop.to_ascii_lowercase().contains("kde");
let desktop_detail = if desktop.is_empty() {
    "XDG_CURRENT_DESKTOP не задан"
} else {
    desktop.as_str()
};
row("KDE Plasma", kde, desktop_detail);
row("plasmashell", on_path("plasmashell"), "панель Plasma");
```

Replace the hint strings for missing tools with apt names:

```rust
row("playerctl", on_path("playerctl"), "apt install playerctl");
row("gst-launch-1.0", on_path("gst-launch-1.0"), "apt install gstreamer1.0-tools");
row("mpv", on_path("mpv"), "опционально: apt install mpv");
row("secret-tool", on_path("secret-tool"), "apt install libsecret-tools");
row("curl", on_path("curl"), "проверки HTTP API");
```

Change the header to `println!("ymd doctor");` and the footer to `println!("warn — не ошибка: без части пакетов доступны не все возможности.");`.

- [ ] **Step 6: Run the tests and verify they pass**

Run: `packaging/run-tests.sh`

Expected: all tests pass, including `session_key_subcommand_parses` (27 tests or more). `Cargo.lock` is regenerated with version `0.2.0`.

- [ ] **Step 7: Verify the command manually inside the container**

Run:

```bash
docker run --rm --platform linux/amd64 \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e CARGO_HOME="/work/packaging/.cache/cargo-amd64" \
  -e CARGO_TARGET_DIR="/work/packaging/.cache/target-amd64" \
  -v "$PWD:/work" -w /work \
  ymd-builder:amd64 bash -c '
    mkdir -p /tmp/ymdtest/ymd
    printf "0123456789abcdef0123456789abcdef\n" > /tmp/ymdtest/ymd/session.key
    XDG_RUNTIME_DIR=/tmp/ymdtest cargo run --quiet -- session-key
  '
```

Expected output: `0123456789abcdef0123456789abcdef`.

- [ ] **Step 8: Update docs for the daemon change**

In `docs/04-daemon.md`, add `ymd session-key` to the CLI table with the description «напечатать capability-ключ (для плазмоида)» and replace Noctalia references with KDE Plasma.

Create `notes/kde-port-findings.md` with the checked host facts:

```markdown
# KDE-порт: факты, проверенные на хосте

Дата: 2026-11-13. Хост: Ubuntu 26.04.1 LTS, x86_64, KDE Plasma 6.6.6 (Wayland).

- `plasmashell`, `kpackagetool6`, `dpkg-buildpackage`, `dpkg-shlibdeps` есть.
- QML-модули: `org.kde.plasma.plasma5support`, `org.kde.kirigami`, `org.kde.plasma.components` установлены.
- `plasmoidviewer` и `qmllint6` в apt не найдены; QML проверяется установкой через `kpackagetool6 --packageroot`.
- Rust/cargo и GStreamer dev-пакеты на хосте отсутствуют; тесты и сборка идут в Docker.
- Docker 29.9.3, binfmt `qemu-aarch64` зарегистрирован.
- apt: `gstreamer1.0-pipewire` 1.6.2, `plasma-workspace` 4:6.6.6.
```

Update the `AGENTS.md` state table rows for `daemon/src/main.rs` (add `session-key`), `daemon/src/session.rs`, and `daemon/src/doctor.rs`.

- [ ] **Step 9: Commit and push**

```bash
bash scripts/docs-check.sh
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --no-banner --source=/repo
git add Cargo.toml Cargo.lock daemon/Cargo.toml daemon/src/main.rs daemon/src/session.rs \
  daemon/src/doctor.rs daemon/src/state.rs packaging/Dockerfile \
  packaging/run-tests.sh .gitignore docs/04-daemon.md \
  notes/kde-port-findings.md AGENTS.md
git commit -m "feat(daemon): add session-key command and containerized tests"
git push origin main
```

---

### Task 2: Plasmoid scaffold, formatting helpers, compact widget

**Files:**
- Create: `plasmoid/metadata.json`
- Create: `plasmoid/contents/config/main.xml`
- Create: `plasmoid/contents/config/config.qml`
- Create: `plasmoid/contents/config/configGeneral.qml`
- Create: `plasmoid/contents/ui/format.js`
- Create: `plasmoid/contents/ui/main.qml`
- Create: `plasmoid/contents/ui/CompactRepresentation.qml`
- Create: `plasmoid/tests/format.test.js`
- Rename/rewrite: `docs/03-noctalia-plugin.md` → `docs/03-kde-plasmoid.md`
- Modify: `docs/03-kde-plasmoid.md` (scaffold, key reading, polling, compact)

**Interfaces:**
- Produces in `format.js`: `truncate(text, max) -> string`, `formatTime(ms) -> string`, `qualityLabel(quality) -> string`, `qualityNext(quality) -> string`, `repeatNext(mode) -> string`, `trackLine(item) -> string`.
- Produces in `main.qml`: properties `state`, `sessionKey`, `keyReady`, `keyRetried`, `authFailed`, `lastError`, `lastRev`, `searchResults`, `searchHint`; methods `refresh()`, `cmd(op, payload)`, `search(text)`, `seek(ms)`, `requestKey()`, `baseUrl()`, `cycleQuality()`; derived properties `track`, `title`, `artistLine`, `durationMs`, `positionMs`, `status`, `quality`, `qualityText`, `repeatMode`, `shuffle`, `queueItems`, `queueIndex`.
- Produces: `CompactRepresentation { property var applet }`.

- [ ] **Step 1: Write the failing formatting tests**

`plasmoid/tests/format.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const Format = require("../contents/ui/format.js");

test("truncate keeps short text and adds an ellipsis", () => {
  assert.equal(Format.truncate("abc", 5), "abc");
  assert.equal(Format.truncate("abcdef", 5), "abcd…");
  assert.equal(Format.truncate("", 5), "");
});

test("formatTime renders mm:ss", () => {
  assert.equal(Format.formatTime(0), "0:00");
  assert.equal(Format.formatTime(65000), "1:05");
  assert.equal(Format.formatTime(125000), "2:05");
});

test("qualityLabel maps known values", () => {
  assert.equal(Format.qualityLabel("lossless"), "FLAC");
  assert.equal(Format.qualityLabel("hq"), "AAC 256");
  assert.equal(Format.qualityLabel("nq"), "AAC 192");
  assert.equal(Format.qualityLabel("lq"), "AAC 64");
  assert.equal(Format.qualityLabel("other"), "other");
});

test("qualityNext cycles lossless -> hq -> nq -> lq -> lossless", () => {
  assert.equal(Format.qualityNext("lossless"), "hq");
  assert.equal(Format.qualityNext("hq"), "nq");
  assert.equal(Format.qualityNext("nq"), "lq");
  assert.equal(Format.qualityNext("lq"), "lossless");
  assert.equal(Format.qualityNext("unknown"), "lossless");
});

test("repeatNext cycles off -> all -> one -> off", () => {
  assert.equal(Format.repeatNext("off"), "all");
  assert.equal(Format.repeatNext("all"), "one");
  assert.equal(Format.repeatNext("one"), "off");
});

test("trackLine marks cached and includes the first artist", () => {
  assert.equal(
    Format.trackLine({ title: "Song", artists: ["Artist"], cached: true }),
    "✓ Song · Artist"
  );
  assert.equal(Format.trackLine({ title: "Song", artists: [], cached: false }), "Song");
  assert.equal(Format.trackLine(null), "");
});
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `node --test plasmoid/tests/format.test.js`

Expected: `Cannot find module '../contents/ui/format.js'`.

- [ ] **Step 3: Implement `format.js`**

Implement the six functions with these exact semantics:

- `truncate`: `String(text || "")`; if `max <= 0` return `""`; if length ≤ `max` return text; otherwise `text.slice(0, max - 1) + "…"`.
- `formatTime`: `Math.floor(ms / 1000)`, minutes `m`, seconds `s`; return `m + ":" + (s < 10 ? "0" : "") + s`.
- `qualityLabel`: map `lossless→FLAC`, `hq→AAC 256`, `nq→AAC 192`, `lq→AAC 64`; unknown returns the input.
- `qualityNext`: map `lossless→hq`, `hq→nq`, `nq→lq`, `lq→lossless`; unknown returns `lossless`.
- `repeatNext`: map `off→all`, `all→one`, `one→off`; unknown returns `all`.
- `trackLine`: empty for null; prefix `"✓ "` when `item.cached`; first artist via `item.artists[0]`; title truncated to 24 when an artist exists, otherwise 44; join with `" · "`.

End the file with the Node/QML dual-use guard:

```js
if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        truncate: truncate,
        formatTime: formatTime,
        qualityLabel: qualityLabel,
        qualityNext: qualityNext,
        repeatNext: repeatNext,
        trackLine: trackLine,
    };
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `node --test plasmoid/tests/format.test.js`

Expected: 6 tests pass.

- [ ] **Step 5: Create the package metadata and config**

`plasmoid/metadata.json`:

```json
{
  "KPackageStructure": "Plasma/Applet",
  "KPlugin": {
    "Authors": [{"Name": "Pavel Bolkhovitin", "Email": "pbolkhovitin@yandex.ru"}],
    "Category": "Multimedia",
    "Description": "Yandex Music client for KDE Plasma 6",
    "Icon": "audio-x-generic",
    "Id": "io.github.pbolkhovitin.ymd",
    "License": "MIT",
    "Name": "Yandex Music",
    "Version": "0.2.0",
    "Website": "https://github.com/pbolkhovitin/ym-noctalia"
  },
  "X-Plasma-API": "declarativeappletscript",
  "X-Plasma-API-Minimum-Version": "6.0",
  "X-Plasma-MainScript": "ui/main.qml"
}
```

`plasmoid/contents/config/main.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kcfg xmlns="http://www.kde.org/standards/kcfg/1.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://www.kde.org/standards/kcfg/1.0 http://www.kde.org/standards/kcfg/1.0/kcfg.xsd">
  <kcfgfile name=""/>
  <group name="General">
    <entry name="daemonPort" type="Int">
      <label>Local ymd API port</label>
      <default>8765</default>
    </entry>
  </group>
</kcfg>
```

`plasmoid/contents/config/config.qml`:

```qml
import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "configure"
        source: "configGeneral.qml"
    }
}
```

`plasmoid/contents/config/configGeneral.qml`:

```qml
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: page
    property alias cfg_daemonPort: portField.value
    implicitWidth: Kirigami.Units.gridUnit * 20
    implicitHeight: Kirigami.Units.gridUnit * 6

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing

        QQC2.Label { text: i18n("Daemon port") }
        QQC2.SpinBox {
            id: portField
            from: 1
            to: 65535
            Layout.fillWidth: true
        }
        Item { Layout.fillHeight: true }
    }
}
```

- [ ] **Step 6: Create `main.qml` with key loading, polling, and commands**

Use these exact imports and root skeleton:

```qml
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "format.js" as Format

PlasmoidItem {
    id: root
    property var state: ({})
    property string sessionKey: ""
    property bool keyReady: false
    property bool keyRetried: false
    property bool authFailed: false
    property string lastError: ""
    property int lastRev: -1
    property var searchResults: []
    property string searchHint: ""

    readonly property var track: state.track || null
    readonly property string title: track ? (track.title || "") : ""
    readonly property string artistLine: track ? (track.artists || []).join(", ") : ""
    readonly property int durationMs: track ? (track.durationMs || 0) : 0
    readonly property int positionMs: state.positionMs || 0
    readonly property string status: state.status || "stopped"
    readonly property string quality: state.quality || "lossless"
    readonly property string qualityText: Format.qualityLabel(quality)
    readonly property string repeatMode: (state.queue && state.queue.repeat) || "all"
    readonly property bool shuffle: !!(state.queue && state.queue.shuffle)
    readonly property var queueItems: (state.queue && state.queue.items) || []
    readonly property int queueIndex: (state.queue && state.queue.index) || 0

    compactRepresentation: CompactRepresentation { applet: root }
    fullRepresentation: FullRepresentation { applet: root }

    toolTipMainText: title || "Yandex Music"
    toolTipSubText: artistLine || (keyReady ? lastError : "Демон не запущен")

    function baseUrl() {
        return "http://127.0.0.1:" + plasmoid.configuration.daemonPort;
    }

    function requestKey() {
        authFailed = false;
        keySource.connectSource("ymd session-key");
    }

    function refresh() {
        if (!sessionKey) return;
        var xhr = new XMLHttpRequest();
        xhr.open("GET", baseUrl() + "/v1/state");
        xhr.setRequestHeader("X-YMD-Session", sessionKey);
        xhr.timeout = 5000;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.rev !== lastRev) {
                        state = data;
                        lastRev = data.rev;
                    }
                    lastError = "";
                    keyRetried = false;
                    authFailed = false;
                } catch (e) {
                    lastError = "Некорректный ответ демона";
                }
            } else if (xhr.status === 401) {
                if (!keyRetried) {
                    keyRetried = true;
                    sessionKey = "";
                    keyReady = false;
                    requestKey();
                } else {
                    authFailed = true;
                    lastError = "Ключ не подходит";
                }
            } else {
                lastError = "Демон недоступен (HTTP " + xhr.status + ")";
            }
        };
        xhr.ontimeout = function() { lastError = "Демон не отвечает"; };
        xhr.send();
    }

    function cmd(op, payload) {
        if (!sessionKey) {
            lastError = "Нет ключа сессии";
            return;
        }
        var xhr = new XMLHttpRequest();
        xhr.open("POST", baseUrl() + "/v1/cmd");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.setRequestHeader("X-YMD-Session", sessionKey);
        xhr.timeout = 5000;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 401) {
                keyRetried = true;
                sessionKey = "";
                keyReady = false;
                requestKey();
            } else if (xhr.status >= 400) {
                lastError = "Команда не выполнена (HTTP " + xhr.status + ")";
            } else {
                lastError = "";
                refresh();
            }
        };
        xhr.send(JSON.stringify({ op: op, payload: payload || {} }));
    }

    function search(text) { /* implemented in Task 4 */ }
    function seek(ms) { cmd("seek", { positionMs: Math.round(ms) }); }
    function cycleQuality() { cmd("quality", { value: Format.qualityNext(quality) }); }

    P5Support.DataSource {
        id: keySource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var output = (data.stdout || "").trim();
            sessionKey = output.length >= 16 ? output : "";
            keyReady = sessionKey !== "";
            if (!keyReady) {
                lastError = "Ключ не найден. Запущен ли ymd?";
            }
            disconnectSource(sourceName);
            if (keyReady) refresh();
        }
    }

    Timer {
        interval: root.status === "playing" ? 1000 : 3000
        running: root.keyReady && !root.authFailed
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 5000
        running: !root.keyReady && !root.authFailed
        repeat: true
        onTriggered: root.requestKey()
    }

    Component.onCompleted: requestKey()
}
```

`FullRepresentation.qml` is created in Task 3; for this task create a placeholder `plasmoid/contents/ui/FullRepresentation.qml` so the package loads:

```qml
import QtQuick

Item {
    property var applet
}
```

Task 3 replaces it.

- [ ] **Step 7: Create the compact representation**

`plasmoid/contents/ui/CompactRepresentation.qml`:

```qml
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "format.js" as Format

Item {
    id: compact
    property var applet

    implicitWidth: row.implicitWidth + Kirigami.Units.smallSpacing * 2
    implicitHeight: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: "audio-x-generic"
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium
            color: Kirigami.Theme.textColor
        }

        PlasmaComponents3.Label {
            visible: Plasmoid.formFactor !== PlasmaCore.Types.Vertical
            text: applet.title
                ? Format.truncate(applet.title + (applet.artistLine ? " — " + applet.artistLine : ""), 34)
                : (applet.keyReady ? "" : "ymd")
            color: Kirigami.Theme.textColor
            elide: Text.ElideRight
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) {
                Plasmoid.expanded = !Plasmoid.expanded;
            } else if (mouse.button === Qt.MiddleButton) {
                applet.cmd("toggle");
            }
        }
        onWheel: function(wheel) {
            if (wheel.angleDelta.y !== 0) {
                applet.cmd(wheel.angleDelta.y > 0 ? "prev" : "next");
            }
        }
    }
}
```

Do not accept `Qt.RightButton` in the `MouseArea`, so the Plasma context menu still works.

- [ ] **Step 8: Validate package structure**

Run:

```bash
python3 -m json.tool plasmoid/metadata.json >/dev/null
xmllint --noout plasmoid/contents/config/main.xml
rm -rf /tmp/opencode/ymd-kpackage
mkdir -p /tmp/opencode/ymd-kpackage
kpackagetool6 --type Plasma/Applet --install plasmoid --packageroot /tmp/opencode/ymd-kpackage
kpackagetool6 --type Plasma/Applet --list --packageroot /tmp/opencode/ymd-kpackage | grep io.github.pbolkhovitin.ymd
```

Expected: JSON/XML are valid and the package is listed.

- [ ] **Step 9: Manual smoke test in Plasma**

Install for the current user: `kpackagetool6 --type Plasma/Applet --install plasmoid`. Add «Yandex Music» to a panel. With `ymd serve` running and authorized, the compact widget shows `Трек — Артист`; middle click toggles playback; the wheel switches tracks; the tooltip shows the full title. Ask the user to confirm before continuing.

- [ ] **Step 10: Update the plasmoid doc and commit**

Rename and rewrite the doc:

```bash
git mv docs/03-noctalia-plugin.md docs/03-kde-plasmoid.md
```

Then rewrite `docs/03-kde-plasmoid.md` with sections: package layout, `metadata.json`, key reading via `session-key`, polling, compact interactions, config port. Do not leave the old Noctalia file behind.

```bash
git add plasmoid docs/03-kde-plasmoid.md
git commit -m "feat(plasmoid): scaffold Plasma 6 applet with compact widget"
```

---

### Task 3: Popup core — track, cover, seek, transport, modes, quality

**Files:**
- Replace: `plasmoid/contents/ui/FullRepresentation.qml`
- Create: `plasmoid/contents/ui/TrackRow.qml`
- Modify: `plasmoid/contents/ui/main.qml` (only if a derived property is missing)
- Modify: `docs/03-kde-plasmoid.md` (popup section)

**Interfaces:**
- Consumes: `applet.track`, `applet.title`, `applet.artistLine`, `applet.durationMs`, `applet.positionMs`, `applet.status`, `applet.qualityText`, `applet.repeatMode`, `applet.shuffle`, `applet.cmd(op, payload)`, `applet.seek(ms)`, `applet.cycleQuality()`.
- Produces: `TrackRow { property var item; property int rowIndex; property bool showIndex; property bool current }`; it inherits the `clicked` signal from `PlasmaComponents3.ItemDelegate`.

- [ ] **Step 1: Create `TrackRow.qml`**

```qml
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "format.js" as Format

PlasmaComponents3.ItemDelegate {
    id: row
    property var item
    property int rowIndex: -1
    property bool showIndex: false
    property bool current: false

    text: (showIndex ? (rowIndex + 1) + ". " : "") + Format.trackLine(item)
    highlighted: current
    Layout.fillWidth: true
}
```

- [ ] **Step 2: Build the popup layout**

`FullRepresentation.qml` must contain, in this order:

1. Header row: 96×96 cover (`Image` with `source: applet.track && applet.track.cover ? applet.track.cover : ""`, `asynchronous: true`, `fillMode: Image.PreserveAspectCrop`, `visible: status === Image.Ready`) behind a `Kirigami.Icon { source: "audio-x-generic" }` placeholder; title (bold, `elide: Text.ElideRight`), artist line (`opacity: 0.7`, elide), status line `applet.status + " · " + applet.qualityText` (for example `playing · FLAC`), and `Format.formatTime(applet.positionMs) + " / " + Format.formatTime(applet.durationMs)`.
2. Seek slider using `PlasmaComponents3.Slider` with `Layout.fillWidth: true`, `from: 0`, `to: Math.max(1, applet.durationMs)`, `enabled: applet.durationMs > 0`. Bind value only while not pressed:

```qml
Binding {
    target: seekSlider
    property: "value"
    value: applet.positionMs
    when: !seekSlider.pressed
    restoreMode: Binding.RestoreNone
}
```

and send on release: `onPressedChanged: if (!pressed) applet.seek(value)`.

3. Transport row: `PlasmaComponents3.ToolButton` with `icon.name` `media-skip-backward`, `media-playback-pause`/`media-playback-start` (depending on `applet.status === "playing"`), `media-skip-forward`; a like button with `icon.name: "emblem-favorite"` and `icon.color: applet.track && applet.track.liked ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor`; a wave button (`icon.name: "media-playlist-shuffle"`, command `wave_start`); and a close button (`icon.name: "window-close"`, `onClicked: Plasmoid.expanded = false`). Commands: `prev`, `toggle`, `next`, `like`, `wave_start`.
4. Mode row: repeat button (`Повтор: выкл/все/один`, command `repeat` with `{ value: Format.repeatNext(applet.repeatMode) }`), shuffle button (`Перемешать: вкл/выкл`, command `shuffle` with `{ value: !applet.shuffle }`), quality button (`Качество: ` + `applet.qualityText`, `applet.cycleQuality()`).
5. Hint label showing `applet.lastError` when non-empty, `color: Kirigami.Theme.negativeTextColor`, `visible: text !== ""`; next to it a `PlasmaComponents3.Button { text: "Повторить"; visible: !applet.keyReady || applet.lastError !== ""; onClicked: applet.requestKey() }`.

Use `Kirigami.Units.gridUnit * 21` (≈380 px) for `implicitWidth`; let `implicitHeight` follow the column's `implicitHeight` plus margins. No hex colors, no animations.

- [ ] **Step 3: Validate package structure**

Run the Task 2 Step 8 commands. Expected: package installs and lists.

- [ ] **Step 4: Manual smoke test**

With a track playing: the popup shows cover/title/artist, the slider follows playback, dragging and releasing seeks, transport buttons work, like toggles, repeat/shuffle/quality buttons change state. Ask the user to confirm.

- [ ] **Step 5: Update docs and commit**

Add the popup structure and controls to `docs/03-kde-plasmoid.md`.

```bash
git add plasmoid/contents/ui/FullRepresentation.qml plasmoid/contents/ui/TrackRow.qml \
  plasmoid/contents/ui/main.qml docs/03-kde-plasmoid.md
git commit -m "feat(plasmoid): add popup with transport, seek, modes and quality"
```

---

### Task 4: Popup search and queue

**Files:**
- Modify: `plasmoid/contents/ui/main.qml` (`search` implementation)
- Modify: `plasmoid/contents/ui/FullRepresentation.qml` (search field, results, queue)
- Modify: `docs/03-kde-plasmoid.md` (search/queue section)

**Interfaces:**
- Consumes: `GET /v1/search?q=<text>` returns `{ "query": string, "tracks": [{ id, title, artists, album, durationMs, liked, cover, cached }] }`.
- Produces: `applet.searchResults` (array of track objects), `applet.searchHint` (string).
- Produces: `applet.cmd("play_track", track)` and `applet.cmd("queue_play", { index: n })`.

- [ ] **Step 1: Implement `search(text)` in `main.qml`**

```js
function search(text) {
    var query = String(text || "").trim();
    searchHint = "";
    if (!query) {
        searchResults = [];
        return;
    }
    var xhr = new XMLHttpRequest();
    xhr.open("GET", baseUrl() + "/v1/search?q=" + encodeURIComponent(query));
    xhr.setRequestHeader("X-YMD-Session", sessionKey);
    xhr.timeout = 5000;
    xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return;
        if (xhr.status === 200) {
            try {
                var data = JSON.parse(xhr.responseText);
                searchResults = data.tracks || [];
                searchHint = searchResults.length ? "" : "Ничего не найдено";
            } catch (e) {
                searchResults = [];
                searchHint = "Некорректный ответ поиска";
            }
        } else if (xhr.status === 401) {
            searchHint = "Ключ устарел";
            keyRetried = true;
            sessionKey = "";
            keyReady = false;
            requestKey();
        } else {
            searchResults = [];
            searchHint = "Поиск недоступен (HTTP " + xhr.status + ")";
        }
    };
    xhr.ontimeout = function() { searchHint = "Поиск не отвечает"; };
    xhr.send();
}
```

- [ ] **Step 2: Add search and queue blocks to the popup**

After the mode row add:

- `PlasmaComponents3.TextField { placeholderText: "Поиск"; onAccepted: applet.search(text) }`
- A `Repeater` over `applet.searchResults.slice(0, 4)` with `TrackRow { item: modelData; onClicked: applet.cmd("play_track", modelData) }`.
- A label `applet.searchHint` when non-empty.
- A separator and label «Очередь».
- A `Repeater` over `applet.queueItems.slice(0, 4)` with `TrackRow { item: modelData; rowIndex: index; showIndex: true; current: index === applet.queueIndex; onClicked: applet.cmd("queue_play", { index: index }) }`.
- Empty state: «Введите запрос» when `searchResults` is empty and `searchHint` is empty; «Очередь пуста» when `queueItems` is empty.

- [ ] **Step 3: Validate package structure**

Run the Task 2 Step 8 commands. Expected: package installs and lists.

- [ ] **Step 4: Manual smoke test**

Search for a known track, click a result (playback starts), click a queue row (switches to it), check the cached `✓` marker appears for a downloaded track. Ask the user to confirm.

- [ ] **Step 5: Update docs, run checks, commit and push**

Add the search/queue contract to `docs/03-kde-plasmoid.md`.

```bash
bash scripts/docs-check.sh
node --test plasmoid/tests/format.test.js
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --no-banner --source=/repo
git add plasmoid docs/03-kde-plasmoid.md
git commit -m "feat(plasmoid): add search and queue to the popup"
git push origin main
```

Expected: docs-check `ok` (or only known historical markers), 6 Node tests pass.

---

### Task 5: Debian packaging for `ymd` and the plasmoid

**Files:**
- Create: `LICENSE`
- Create: `packaging/ymd.service`
- Create: `packaging/deb/ymd/control.in`
- Create: `packaging/deb/plasma-widget-ymd/control.in`
- Create: `packaging/in-docker.sh`
- Create: `packaging/build-deb.sh`
- Modify: `packaging/Dockerfile` (already has `dpkg-dev` and `file`)
- Modify: `.gitignore` (already has `dist/` and `packaging/.cache/`)
- Modify: `docs/04-daemon.md` (install section)

**Interfaces:**
- Produces: `packaging/build-deb.sh --arch amd64|arm64`.
- Produces: `dist/ymd_0.2.0_<arch>.deb` and `dist/plasma-widget-ymd_0.2.0_all.deb`.
- `ymd` installs `/usr/bin/ymd` and `/usr/lib/systemd/user/ymd.service`.
- `plasma-widget-ymd` installs `/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd/`.

- [ ] **Step 1: Add the MIT license**

Create `LICENSE` with the standard MIT text and `Copyright (c) 2026 Pavel Bolkhovitin`.

- [ ] **Step 2: Add the systemd user unit**

`packaging/ymd.service`:

```ini
[Unit]
Description=Yandex Music daemon (ymd)
Documentation=https://github.com/pbolkhovitin/ym-noctalia
After=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=/usr/bin/ymd serve
Restart=on-failure
RestartSec=2
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

- [ ] **Step 3: Add control templates**

`packaging/deb/ymd/control.in`:

```text
Source: ymd
Package: ymd
Version: @VERSION@
Section: sound
Priority: optional
Architecture: @ARCH@
Maintainer: Pavel Bolkhovitin <pbolkhovitin@yandex.ru>
Depends: @SHLIBS@, libsecret-tools, playerctl, dbus-user-session
Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-libav, gstreamer1.0-pipewire, pipewire, wireplumber
Description: Yandex Music daemon for KDE Plasma
 Local HTTP API, GStreamer playback, MPRIS export, offline cache and
 "My Wave" for the Yandex Music Plasma plasmoid.
```

`packaging/deb/plasma-widget-ymd/control.in`:

```text
Package: plasma-widget-ymd
Version: @VERSION@
Section: kde
Priority: optional
Architecture: all
Maintainer: Pavel Bolkhovitin <pbolkhovitin@yandex.ru>
Depends: plasma-workspace (>= 4:6.0), qml6-module-org-kde-kirigami, qml6-module-org-kde-plasma-plasma5support
Recommends: ymd
Description: Yandex Music plasmoid for KDE Plasma 6
 Compact panel widget and popup with search, queue, transport and
 "My Wave" controls. Requires the ymd daemon for playback.
```

- [ ] **Step 4: Write the in-container build script**

`packaging/in-docker.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
arch="${1:?usage: in-docker.sh amd64|arm64}"
cd "$(dirname "$0")/.."

version=$(sed -n '/\[workspace.package\]/,/^\[/p' Cargo.toml \
  | sed -n 's/^version = "\(.*\)"/\1/p' | head -n1)
test -n "$version"

if [ "$arch" = "amd64" ]; then
  cargo test --locked
fi
cargo build --release --locked

stage="dist/stage"
rm -rf "$stage" dist/*.deb
install -Dm755 "$CARGO_TARGET_DIR/release/ymd" "$stage/ymd/usr/bin/ymd"
install -Dm644 packaging/ymd.service "$stage/ymd/usr/lib/systemd/user/ymd.service"
install -Dm644 README.md "$stage/ymd/usr/share/doc/ymd/README.md"
install -Dm644 LICENSE "$stage/ymd/usr/share/doc/ymd/copyright"

plasmoid_dir="$stage/plasma-widget-ymd/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd"
mkdir -p "$plasmoid_dir"
cp -a plasmoid/metadata.json plasmoid/contents "$plasmoid_dir/"
install -Dm644 LICENSE "$stage/plasma-widget-ymd/usr/share/doc/plasma-widget-ymd/copyright"

# Resolve exact library versions with dpkg-shlibdeps.
shlib_root="packaging/.shlibdeps/$arch"
rm -rf "$shlib_root"
mkdir -p "$shlib_root/debian"
sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" \
  packaging/deb/ymd/control.in | grep -v '^Depends:' > "$shlib_root/debian/control"
printf 'ymd (%s) unstable; urgency=medium\n\n  * Local build.\n\n -- Pavel Bolkhovitin <pbolkhovitin@yandex.ru>  %s\n' \
  "$version" "$(date -R)" > "$shlib_root/debian/changelog"
binary="$PWD/$stage/ymd/usr/bin/ymd"
shlibs=$(cd "$shlib_root" && dpkg-shlibdeps -O "$binary" \
  | sed -n 's/^shlibs:Depends=//p')
test -n "$shlibs"

mkdir -p "$stage/ymd/DEBIAN"
sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" -e "s|@SHLIBS@|$shlibs|g" \
  packaging/deb/ymd/control.in > "$stage/ymd/DEBIAN/control"

mkdir -p "$stage/plasma-widget-ymd/DEBIAN"
sed -e "s/@VERSION@/$version/g" \
  packaging/deb/plasma-widget-ymd/control.in > "$stage/plasma-widget-ymd/DEBIAN/control"

dpkg-deb --build --root-owner-group "$stage/ymd" "dist/ymd_${version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$stage/plasma-widget-ymd" "dist/plasma-widget-ymd_${version}_all.deb"
```

The script creates `$stage/ymd/DEBIAN` before writing its control.

- [ ] **Step 5: Write the host build script**

`packaging/build-deb.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

arch=arm64
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="${2:?}"; shift 2 ;;
    *) echo "usage: $0 [--arch amd64|arm64]" >&2; exit 2 ;;
  esac
done

case "$arch" in
  amd64) platform=linux/amd64 ;;
  arm64) platform=linux/arm64 ;;
  *) echo "unsupported arch: $arch" >&2; exit 2 ;;
esac

mkdir -p "packaging/.cache/cargo-$arch" "packaging/.cache/target-$arch" dist
docker build --platform "$platform" -t "ymd-builder:$arch" packaging
docker run --rm --platform "$platform" \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e CARGO_HOME="/work/packaging/.cache/cargo-$arch" \
  -e CARGO_TARGET_DIR="/work/packaging/.cache/target-$arch" \
  -v "$PWD:/work" -w /work \
  "ymd-builder:$arch" bash packaging/in-docker.sh "$arch"
```

Make both scripts executable.

- [ ] **Step 6: Build and validate the amd64 packages**

Run: `packaging/build-deb.sh --arch amd64`

Expected: tests pass, `dist/ymd_0.2.0_amd64.deb` and `dist/plasma-widget-ymd_0.2.0_all.deb` exist.

Validate:

```bash
dpkg-deb -I dist/ymd_0.2.0_amd64.deb
dpkg-deb -c dist/ymd_0.2.0_amd64.deb | grep -E 'usr/bin/ymd|systemd/user/ymd.service'
dpkg-deb -c dist/plasma-widget-ymd_0.2.0_all.deb | grep -E 'metadata.json|contents/ui/main.qml'
rm -rf /tmp/opencode/ymd-root && mkdir -p /tmp/opencode/ymd-root
dpkg-deb -x dist/ymd_0.2.0_amd64.deb /tmp/opencode/ymd-root
file /tmp/opencode/ymd-root/usr/bin/ymd
```

Expected: `Depends` contains real library versions (e.g. `libgstreamer1.0-0`), both files are listed, and `file` reports `ELF 64-bit LSB pie executable, x86-64`.

- [ ] **Step 7: Build and validate the arm64 package**

Run: `packaging/build-deb.sh --arch arm64`

Expected (first run may take 10–60 minutes under QEMU): `dist/ymd_0.2.0_arm64.deb` exists. The Rust test suite runs in the amd64 container; the arm64 container performs the release build only.

Validate:

```bash
dpkg-deb -I dist/ymd_0.2.0_arm64.deb | grep -E 'Package|Version|Architecture|Depends'
rm -rf /tmp/opencode/ymd-arm && mkdir -p /tmp/opencode/ymd-arm
dpkg-deb -x dist/ymd_0.2.0_arm64.deb /tmp/opencode/ymd-arm
file /tmp/opencode/ymd-arm/usr/bin/ymd
```

Expected: `Architecture: arm64`, `file` reports `ARM aarch64`.

- [ ] **Step 8: Document installation and commit/push**

In `docs/04-daemon.md` add:

```bash
sudo apt install ./ymd_0.2.0_arm64.deb ./plasma-widget-ymd_0.2.0_all.deb
systemctl --user daemon-reload
systemctl --user enable --now ymd
```

and note that the plasmoid is added via the panel's «Добавить виджеты».

```bash
bash scripts/docs-check.sh
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --no-banner --source=/repo
git add LICENSE packaging .gitignore docs/04-daemon.md
git commit -m "build: package ymd and the Plasma plasmoid as deb files"
git push origin main
```

---

### Task 6: Documentation, scripts, and removal of the Noctalia plugin

**Files:**
- Rewrite: `README.md`
- Rewrite: `AGENTS.md`
- Modify: `docs/01-concept.md`, `docs/02-architecture.md`, `docs/04-daemon.md`, `docs/05-feature-matrix.md`, `docs/06-design.md`, `docs/07-roadmap.md`, `docs/08-risks.md`, `docs/09-p0-spikes.md`
- Modify: `docs/03-kde-plasmoid.md`
- Modify: `notes/kde-port-findings.md`
- Rewrite: `scripts/dev-install.sh`
- Rename/rewrite: `scripts/p0-check.sh` → `scripts/check-env.sh`
- Modify: `scripts/docs-check.sh`
- Delete: `plugin/` (all Luau files), `docs/03-noctalia-plugin.md` if still present

**Interfaces:**
- Produces: `scripts/dev-install.sh` installs/upgrades the plasmoid via `kpackagetool6`.
- Produces: `scripts/check-env.sh` checks Plasma, QML modules, daemon, MPRIS, GStreamer, and the session key.
- Produces: `scripts/docs-check.sh` checks daemon + plasmoid + packaging and the version match between `Cargo.toml` and `plasmoid/metadata.json`.

- [ ] **Step 1: Rewrite `README.md`**

Cover, in this order: what it is (Yandex Music for KDE Plasma 6 on Ubuntu 26.04 aarch64), architecture (daemon + plasmoid + local HTTP/MPRIS), repository layout (`daemon/`, `plasmoid/`, `packaging/`, `docs/`, `notes/`, `scripts/`), install from `.deb` (commands above), build (`packaging/build-deb.sh --arch arm64`), controls (LMB popup, MMB play/pause, wheel prev/next, RMB Plasma menu), status M1–M4 + K5, links to docs. Remove all niri/Noctalia/`plugin.toml`/Luau content.

- [ ] **Step 2: Rewrite `AGENTS.md`**

Keep the rules that still apply (daemon owns the token; plasmoid never calls Yandex; no hex colors; no animations; docs updated with code; gitleaks before push). Replace Noctalia-specific rules (`runAsync`, `pluginDataDir`, `barWidget`) with QML rules: use `Kirigami.Theme` colors, no `Behavior`/animations, poll only via the existing timer, keep `X-YMD-Session` handling in `main.qml`. Update the state table to list `plasmoid/contents/ui/*.qml`, `packaging/*`, and the daemon modules. Set «Следующий шаг» to lyrics (daemon + CLI + popup), resume after interruption, Ynison.

- [ ] **Step 3: Rewrite the numbered docs**

- `docs/01-concept.md`: KDE Plasma 6 instead of niri/Noctalia; keep the product principles; mark niri-only env features (fullscreen/overview/idle) as unused by the KDE port.
- `docs/02-architecture.md`: daemon ↔ plasmoid via `127.0.0.1:8765`, `X-YMD-Session`, polling, MPRIS, package layout, systemd user unit.
- `docs/03-kde-plasmoid.md`: final QML structure (`main.qml`, `CompactRepresentation.qml`, `FullRepresentation.qml`, `TrackRow.qml`, `format.js`), key flow, polling, compact/popup/search/queue, config.
- `docs/04-daemon.md`: CLI including `session-key`, HTTP endpoints, auth, cache, packaging, systemd.
- `docs/05-feature-matrix.md`: M1–M4 and K5 statuses; remove Noctalia rows; add `.deb` packaging.
- `docs/06-design.md`: compact and popup design, color roles, no animations, text truncation.
- `docs/07-roadmap.md`: P0–M4 done, K5 done; next lyrics/resume/Ynison; remove Fedora/COPR/niri items.
- `docs/08-risks.md`: Plasma 6 API changes, Plasma5Support executable engine, QEMU build time, GStreamer codecs, private API; remove niri/Noctalia risks.
- `docs/09-p0-spikes.md`: one-page closure: P0 spikes are historical, results in `notes/p0-findings.md`; no Noctalia instructions.

- [ ] **Step 4: Rewrite the scripts**

`scripts/dev-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
if kpackagetool6 --type Plasma/Applet --show io.github.pbolkhovitin.ymd >/dev/null 2>&1; then
  kpackagetool6 --type Plasma/Applet --upgrade "$repo/plasmoid"
else
  kpackagetool6 --type Plasma/Applet --install "$repo/plasmoid"
fi
echo "Плазмоид установлен. Перезапустите plasmashell или добавьте виджет заново."
```

`scripts/check-env.sh`: check `plasmashell` (`pgrep -x plasmashell`), `kpackagetool6`, the QML module directories (`/usr/lib/*/qt6/qml/org/kde/kirigami`, `.../plasma/plasma5support`), `playerctl`, `gst-launch-1.0`, `secret-tool`, `ymd` in `PATH`, `/v1/health` on 8765, `session.key`, and `systemctl --user is-active ymd`. Print apt hints for missing packages. Exit 0 with warnings, like the old `p0-check.sh`.

`scripts/docs-check.sh` changes:

- `code_ts` paths: `daemon plasmoid packaging`, excluding `packaging/.cache` and `dist` (build caches must not look like newer code).
- Module scan: `daemon/src/*.rs` and `plasmoid/contents/ui/*.qml` / `*.js`.
- Add a version consistency check:

```bash
pkg_version=$(sed -n '/\[workspace.package\]/,/^\[/p' Cargo.toml \
  | sed -n 's/^version = "\(.*\)"/\1/p' | head -n1)
meta_version=$(sed -n 's/.*"Version": "\([^"]*\)".*/\1/p' plasmoid/metadata.json | head -n1)
if [ "$pkg_version" != "$meta_version" ]; then
  say "· версии не совпадают: Cargo.toml=$pkg_version metadata.json=$meta_version"
  status=1
fi
```

- [ ] **Step 5: Remove the Noctalia plugin**

```bash
git rm -r plugin
git rm docs/03-noctalia-plugin.md 2>/dev/null || true
```

Ensure no remaining references: `grep -rn "noctalia\|Noctalia\|plugin.toml\|barWidget" README.md AGENTS.md docs scripts || true`. Historical notes may mention Noctalia; that is allowed only with a «исторически» marker.

- [ ] **Step 6: Run the checks**

```bash
bash scripts/docs-check.sh
node --test plasmoid/tests/format.test.js
```

Expected: `ok: документация согласована`; 6 Node tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "docs: rewrite for KDE Plasma 6 and remove the Noctalia plugin"
```

---

### Task 7: Final verification and release push

**Files:** none (verification only).

- [ ] **Step 1: Run the full Rust test suite**

Run: `packaging/run-tests.sh`

Expected: all tests pass.

- [ ] **Step 2: Rebuild both packages from a clean tree**

```bash
rm -rf dist
packaging/build-deb.sh --arch amd64
packaging/build-deb.sh --arch arm64
```

Expected: four checks pass (two builds, two `dpkg-deb -I`/`file` validations from Task 5).

- [ ] **Step 3: Validate the plasmoid package**

```bash
rm -rf /tmp/opencode/ymd-kpackage && mkdir -p /tmp/opencode/ymd-kpackage
kpackagetool6 --type Plasma/Applet --install plasmoid --packageroot /tmp/opencode/ymd-kpackage
kpackagetool6 --type Plasma/Applet --list --packageroot /tmp/opencode/ymd-kpackage | grep io.github.pbolkhovitin.ymd
```

Expected: listed.

- [ ] **Step 4: Documentation and secret checks**

```bash
bash scripts/docs-check.sh
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --no-banner --source=/repo
```

Expected: docs-check `ok`; gitleaks reports no leaks. (If the image cannot be pulled, record that in the final report and run `gitleaks` locally when available.)

- [ ] **Step 5: Commit any verification fixes and push**

```bash
git status --short
git add -A
git commit -m "chore: final KDE port verification" 2>/dev/null || true
git push origin main
```

- [ ] **Step 6: Hand off the manual acceptance checklist**

Ask the user to install both `.deb` files and verify:

1. `systemctl --user enable --now ymd`; `ymd doctor` shows KDE and the daemon on `:8765`; `curl -s http://127.0.0.1:8765/v1/health` returns `ok: true`.
2. Add «Yandex Music» to the panel: compact text, tooltip, LMB popup, MMB toggle, wheel prev/next.
3. Popup: cover, title/artist, seek, transport, like, repeat/shuffle/quality.
4. Search returns results and plays them; queue rows switch tracks; cached tracks show `✓`.
5. «Моя волна» starts and stops; `playerctl --player=ymd status` works.
6. Restart the daemon while the popup is open: the widget recovers without a Plasma restart.
