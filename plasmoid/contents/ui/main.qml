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
