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
    property var playlists: []
    property var playlistTracks: []
    property string playlistTitle: ""
    property var homeBlocks: []
    property var metatagGroups: []
    property var genres: []
    property var favorites: []
    property string tagTitle: ""
    property var tagPlaylists: []
    property string tagStation: ""
    property string albumTitle: ""
    property var albumTracks: []
    property string lyricsText: ""
    property var lyricsLines: []
    property string lyricsError: ""

    readonly property var track: state.track || null
    readonly property string title: track ? (track.title || "") : ""
    readonly property string artistLine: track ? (track.artists || []).join(", ") : ""
    readonly property int durationMs: track ? (track.durationMs || 0) : 0
    readonly property int positionMs: state.positionMs || 0
    readonly property string status: state.status || "stopped"
    readonly property string quality: state.quality || "lossless"
    readonly property string qualityText: Format.qualityLabel(quality)
    readonly property real volume: state.volume === undefined ? 0.8 : state.volume
    readonly property string repeatMode: (state.queue && state.queue.repeat) || "all"
    readonly property bool shuffle: !!(state.queue && state.queue.shuffle)
    readonly property var queueItems: (state.queue && state.queue.items) || []
    readonly property int queueIndex: (state.queue && state.queue.index) || 0
    readonly property var downloads: state.downloads || []

    compactRepresentation: CompactRepresentation { applet: root }
    fullRepresentation: FullRepresentation { applet: root }

    toolTipMainText: title || "ymd"
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
                        var previousId = track ? track.id : "";
                        state = data;
                        lastRev = data.rev;
                        if ((data.track ? data.track.id : "") !== previousId) {
                            lyricsText = "";
                            lyricsLines = [];
                            lyricsError = "";
                        }
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
    function loadPlaylists() {
        if (!sessionKey) return;
        var xhr = new XMLHttpRequest();
        xhr.open("GET", baseUrl() + "/v1/playlists");
        xhr.setRequestHeader("X-YMD-Session", sessionKey);
        xhr.timeout = 5000;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    var list = JSON.parse(xhr.responseText).playlists || [];
                    playlists = list;
                    if (list.length > 0 && playlistTracks.length === 0) {
                        loadPlaylist(list[0].uid, list[0].kind);
                    }
                } catch (e) {
                    playlists = [];
                    lastError = "Некорректный список плейлистов";
                }
            } else if (xhr.status === 401) {
                keyRetried = true;
                sessionKey = "";
                keyReady = false;
                requestKey();
            } else {
                lastError = "Плейлисты недоступны (HTTP " + xhr.status + ")";
            }
        };
        xhr.ontimeout = function() { lastError = "Плейлисты не отвечают"; };
        xhr.send();
    }

    function loadPlaylist(uid, kind) {
        playlistTracks = [];
        playlistTitle = "";
        var xhr = new XMLHttpRequest();
        xhr.open("GET", baseUrl() + "/v1/playlist?uid=" + uid + "&kind=" + kind);
        xhr.setRequestHeader("X-YMD-Session", sessionKey);
        xhr.timeout = 8000;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    playlistTitle = (data.playlist && data.playlist.title) || "Плейлист";
                    playlistTracks = data.tracks || [];
                } catch (e) {
                    lastError = "Некорректный плейлист";
                }
            } else {
                lastError = "Плейлист недоступен (HTTP " + xhr.status + ")";
            }
        };
        xhr.ontimeout = function() { lastError = "Плейлист не отвечает"; };
        xhr.send();
    }

    function getJson(path, onSuccess, onError) {
        if (!sessionKey) {
            if (onError) onError("Нет ключа демона");
            return;
        }
        var xhr = new XMLHttpRequest();
        xhr.open("GET", baseUrl() + path);
        xhr.setRequestHeader("X-YMD-Session", sessionKey);
        xhr.timeout = 8000;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    onSuccess(JSON.parse(xhr.responseText));
                } catch (e) {
                    lastError = "Некорректный ответ демона";
                    if (onError) onError(lastError);
                }
            } else if (xhr.status === 401) {
                keyRetried = true;
                sessionKey = "";
                keyReady = false;
                requestKey();
                if (onError) onError("Нет доступа к демону");
            } else {
                lastError = "Запрос не выполнен (HTTP " + xhr.status + ")";
                if (onError) onError(lastError);
            }
        };
        xhr.ontimeout = function() {
            lastError = "Демон не отвечает";
            if (onError) onError(lastError);
        };
        xhr.send();
    }

    function loadHome() {
        getJson("/v1/home", function(data) {
            homeBlocks = data.blocks || [];
        });
    }

    function loadMetatags() {
        getJson("/v1/discovery/metatags", function(data) {
            metatagGroups = data.groups || [];
        });
    }

    function loadGenres() {
        getJson("/v1/discovery/genres", function(data) {
            genres = data.genres || [];
        });
    }

    function loadFavorites() {
        getJson("/v1/favorites", function(data) {
            favorites = data.tracks || [];
        });
    }

    function loadTag(tag) {
        tagTitle = tag;
        tagPlaylists = [];
        tagStation = "";
        getJson("/v1/discovery/tag?tag=" + encodeURIComponent(tag), function(data) {
            tagTitle = data.title || tag;
            tagStation = data.station || "";
            tagPlaylists = data.playlists || [];
        });
    }

    function loadAlbum(id) {
        albumTitle = "";
        albumTracks = [];
        getJson("/v1/album?id=" + encodeURIComponent(id), function(data) {
            albumTitle = (data.album && data.album.title) || "Альбом";
            albumTracks = data.tracks || [];
        });
    }

    function startStation(station) {
        if (!station) return;
        cmd("station_start", { station: station });
    }

    function loadLyrics() {
        if (!track || !track.id) return;
        lyricsText = "";
        lyricsLines = [];
        lyricsError = "";
        getJson("/v1/lyrics?id=" + encodeURIComponent(track.id) + "&format=lrc", function(data) {
            lyricsText = data.text || "";
            lyricsLines = parseLyrics(lyricsText);
            lyricsError = lyricsText ? "" : "Текст не найден";
        }, function(message) {
            lyricsText = "";
            lyricsLines = [];
            lyricsError = message || "Не удалось загрузить текст";
        });
    }

    function parseLyrics(text) {
        var lines = [];
        var rows = String(text || "").split(/\r?\n/);
        for (var i = 0; i < rows.length; i++) {
            var match = rows[i].match(/^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/);
            if (!match) continue;
            var body = match[3].trim();
            if (!body) continue;
            lines.push({
                time: parseInt(match[1], 10) * 60000 + Math.round(parseFloat(match[2]) * 1000),
                text: body
            });
        }
        return lines;
    }

    function lyricIndexAt(pos) {
        var result = -1;
        for (var i = 0; i < lyricsLines.length; i++) {
            if (lyricsLines[i].time <= pos) result = i;
            else break;
        }
        return result;
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
            if (keyReady) {
                refresh();
                if (playlists.length === 0) {
                    loadPlaylists();
                }
            }
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

    onExpandedChanged: {
        if (expanded) {
            loadPlaylists();
            if (homeBlocks.length === 0) loadHome();
            if (genres.length === 0) loadGenres();
            if (metatagGroups.length === 0) loadMetatags();
            if (favorites.length === 0) loadFavorites();
        }
    }

    Component.onCompleted: requestKey()
}
