import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import "format.js" as Format

Item {
    id: popup
    property var applet

    // 0 — «Сейчас», 1 — «Обзор», 2 — текст песни.
    property int view: 0
    property int browseTab: 0
    property string browseDetail: ""
    property int detailBackTab: 0
    property int currentLyric: applet.lyricIndexAt(applet.positionMs)
    readonly property string currentLyricText: currentLyric >= 0
        && currentLyric < applet.lyricsLines.length
        ? applet.lyricsLines[currentLyric].text : ""
    readonly property string nextLyricText: currentLyric + 1 >= 0
        && currentLyric + 1 < applet.lyricsLines.length
        ? applet.lyricsLines[currentLyric + 1].text : ""

    implicitWidth: Kirigami.Units.gridUnit * 24
    // Попап растёт по контенту, но не выше 38 gridUnit: длинную очередь
    // прокручивает ScrollView, а не экран.
    readonly property real activeHeight: view === 0
        ? nowColumn.implicitHeight
        : (view === 1 ? browseColumn.implicitHeight : lyricsColumn.implicitHeight)
    implicitHeight: Math.min(activeHeight + Kirigami.Units.largeSpacing * 2,
                             Kirigami.Units.gridUnit * 38)

    Component.onCompleted: applet.loadPlaylists()

    function openBrowse(tab) {
        view = 1;
        browseDetail = "";
        browseTab = tab;
        if (tab === 0 && applet.homeBlocks.length === 0) {
            applet.loadHome();
        } else if (tab === 1) {
            if (applet.genres.length === 0) applet.loadGenres();
            if (applet.metatagGroups.length === 0) applet.loadMetatags();
        } else if (tab === 2 && applet.favorites.length === 0) {
            applet.loadFavorites();
        }
    }

    function openPlaylistDetail(uid, kind, backTab) {
        applet.loadPlaylist(uid, kind);
        browseDetail = "playlist";
        detailBackTab = backTab;
        view = 1;
    }

    function openAlbumDetail(id, backTab) {
        applet.loadAlbum(id);
        browseDetail = "album";
        detailBackTab = backTab;
        view = 1;
    }

    function openTagDetail(tag, backTab) {
        applet.loadTag(tag);
        browseDetail = "tag";
        detailBackTab = backTab;
        view = 1;
    }

    function closeDetail() {
        browseDetail = "";
        browseTab = detailBackTab;
    }

    function openLyrics() {
        view = 2;
        applet.loadLyrics();
    }

    function playTracks(tracks) {
        if (!tracks || tracks.length === 0) return;
        applet.cmd("queue_set", { tracks: tracks, index: 0, play: true });
        view = 0;
    }

    function flattenTags(nodes, depth) {
        var result = [];
        for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            if (node.tag) {
                result.push({ title: node.title || node.tag, tag: node.tag, depth: depth });
            }
            var children = node.children || [];
            if (children.length > 0) {
                result = result.concat(flattenTags(children, depth + 1));
            }
        }
        return result;
    }

    // В попапе не создаём сотни делегатов: полный список — в окне ymd-qt.
    function shownTracks(items) {
        return (items || []).slice(0, 50);
    }

    // ---------- Сейчас ----------
    PlasmaComponents3.ScrollView {
        id: nowScroll
        anchors.fill: parent
        visible: popup.view === 0
        contentWidth: availableWidth
        padding: Kirigami.Units.largeSpacing

        ColumnLayout {
            id: nowColumn
            width: nowScroll.availableWidth
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Item {
                    implicitWidth: 96
                    implicitHeight: 96

                    Image {
                        id: coverImage
                        anchors.fill: parent
                        source: applet.track && applet.track.cover ? applet.track.cover : ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        visible: status === Image.Ready
                    }

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        source: "audio-x-generic"
                        implicitWidth: Kirigami.Units.iconSizes.large
                        implicitHeight: Kirigami.Units.iconSizes.large
                        visible: coverImage.status !== Image.Ready
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: applet.title || "Ничего не играет"
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: applet.artistLine
                        opacity: 0.7
                        elide: Text.ElideRight
                        visible: text !== ""
                    }

                    PlasmaComponents3.Label {
                        text: applet.status + " · " + applet.qualityText
                        opacity: 0.7
                    }

                    PlasmaComponents3.Label {
                        text: Format.formatTime(applet.positionMs) + " / " + Format.formatTime(applet.durationMs)
                        opacity: 0.7
                    }
                }
            }

            PlasmaComponents3.Slider {
                id: seekSlider
                Layout.fillWidth: true
                from: 0
                to: Math.max(1, applet.durationMs)
                enabled: applet.durationMs > 0
                onPressedChanged: {
                    if (!pressed) {
                        applet.seek(value);
                    }
                }
            }

            Binding {
                target: seekSlider
                property: "value"
                value: applet.positionMs
                when: !seekSlider.pressed
                restoreMode: Binding.RestoreNone
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: "Громкость"
                    opacity: 0.7
                }

                PlasmaComponents3.Slider {
                    id: volumeSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    value: applet.volume
                    onPressedChanged: {
                        if (!pressed) {
                            applet.cmd("volume", { value: value });
                        }
                    }
                }

                PlasmaComponents3.Label {
                    text: Math.round(volumeSlider.value * 100) + "%"
                    opacity: 0.7
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                }
            }

            Binding {
                target: volumeSlider
                property: "value"
                value: applet.volume
                when: !volumeSlider.pressed
                restoreMode: Binding.RestoreNone
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Item { Layout.fillWidth: true }

                PlasmaComponents3.ToolButton {
                    icon.name: "media-skip-backward"
                    onClicked: applet.cmd("prev")
                }

                PlasmaComponents3.ToolButton {
                    icon.name: applet.status === "playing" ? "media-playback-pause" : "media-playback-start"
                    onClicked: applet.cmd("toggle")
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "media-skip-forward"
                    onClicked: applet.cmd("next")
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "emblem-favorite"
                    icon.color: applet.track && applet.track.liked
                        ? Kirigami.Theme.highlightColor
                        : Kirigami.Theme.textColor
                    onClicked: {
                        if (!applet.track) return;
                        applet.cmd("like_track", {
                            id: applet.track.id,
                            liked: !applet.track.liked
                        });
                    }
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "download"
                    opacity: applet.track && applet.track.cached ? 0.5 : 1
                    enabled: !!applet.track
                    onClicked: applet.cmd("download_track", { track: applet.track })
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "media-playlist-shuffle"
                    onClicked: applet.cmd("wave_start")
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "window-close"
                    onClicked: Plasmoid.expanded = false
                }

                Item { Layout.fillWidth: true }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Item { Layout.fillWidth: true }

                PlasmaComponents3.Button {
                    text: "Повтор: " + (applet.repeatMode === "off"
                        ? "выкл"
                        : (applet.repeatMode === "all" ? "все" : "один"))
                    onClicked: applet.cmd("repeat", { value: Format.repeatNext(applet.repeatMode) })
                }

                PlasmaComponents3.Button {
                    text: "Перемешать: " + (applet.shuffle ? "вкл" : "выкл")
                    onClicked: applet.cmd("shuffle", { value: !applet.shuffle })
                }

                PlasmaComponents3.Button {
                    text: "Качество: " + applet.qualityText
                    onClicked: applet.cycleQuality()
                }

                Item { Layout.fillWidth: true }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Button {
                    text: "Обзор"
                    onClicked: popup.openBrowse(0)
                }

                PlasmaComponents3.Button {
                    text: "Текст"
                    enabled: !!applet.track
                    onClicked: popup.openLyrics()
                }

                Item { Layout.fillWidth: true }
            }

            PlasmaComponents3.TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Поиск"
                onAccepted: applet.search(text)
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: "Найдено · " + applet.searchResults.length
                font.bold: true
                visible: applet.searchResults.length > 0
            }

            Repeater {
                model: applet.searchResults
                delegate: TrackRow {
                    item: modelData
                    onClicked: applet.cmd("play_track", modelData)
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: applet.searchResults.length === 0 && applet.searchHint === ""
                    ? "Введите запрос"
                    : applet.searchHint
                opacity: 0.7
                visible: text !== ""
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: "Плейлисты"
                    opacity: 0.7
                }

                PlasmaComponents3.ComboBox {
                    id: playlistBox
                    Layout.fillWidth: true
                    model: applet.playlists
                    textRole: "title"
                    onActivated: {
                        var playlist = applet.playlists[currentIndex];
                        if (playlist) {
                            applet.loadPlaylist(playlist.uid, playlist.kind);
                        }
                    }
                }

                PlasmaComponents3.Button {
                    text: "Играть"
                    enabled: applet.playlistTracks.length > 0
                    onClicked: popup.playTracks(applet.playlistTracks)
                }
            }

            Repeater {
                model: applet.downloads

                delegate: PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    visible: modelData.state === "downloading"
                    text: "⤓ " + (modelData.title || modelData.id)
                        + (modelData.total > 0
                            ? " · " + Math.round(modelData.bytes * 100 / modelData.total) + "%"
                            : "")
                    opacity: 0.7
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            PlasmaComponents3.Label {
                text: "Очередь" + (applet.queueItems.length > 0 ? " · " + applet.queueItems.length : "")
                font.bold: true
            }

            Repeater {
                model: applet.queueItems
                delegate: TrackRow {
                    item: modelData
                    rowIndex: index
                    showIndex: true
                    current: index === applet.queueIndex
                    onClicked: applet.cmd("queue_play", { index: index })
                }
            }

            PlasmaComponents3.Label {
                text: "Очередь пуста"
                opacity: 0.7
                visible: applet.queueItems.length === 0
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: applet.lastError
                    color: Kirigami.Theme.negativeTextColor
                    wrapMode: Text.WordWrap
                    visible: text !== ""
                }

                PlasmaComponents3.Button {
                    text: "Повторить"
                    visible: !applet.keyReady || applet.lastError !== ""
                    onClicked: applet.requestKey()
                }
            }
        }
    }

    // ---------- Обзор ----------
    PlasmaComponents3.ScrollView {
        id: browseScroll
        anchors.fill: parent
        visible: popup.view === 1
        contentWidth: availableWidth
        padding: Kirigami.Units.largeSpacing

        ColumnLayout {
            id: browseColumn
            width: browseScroll.availableWidth
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Button {
                    text: "←"
                    onClicked: {
                        if (popup.browseDetail !== "") {
                            popup.closeDetail();
                        } else {
                            popup.view = 0;
                        }
                    }
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: popup.browseDetail === "playlist"
                        ? applet.playlistTitle
                        : (popup.browseDetail === "album"
                            ? applet.albumTitle
                            : (popup.browseDetail === "tag" ? applet.tagTitle : "Обзор"))
                    font.bold: true
                    elide: Text.ElideRight
                }

                PlasmaComponents3.Button {
                    text: "Сейчас"
                    onClicked: popup.view = 0
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === ""

                PlasmaComponents3.Button {
                    text: "Главная"
                    checkable: true
                    checked: popup.browseTab === 0
                    onClicked: popup.openBrowse(0)
                }

                PlasmaComponents3.Button {
                    text: "Каталог"
                    checkable: true
                    checked: popup.browseTab === 1
                    onClicked: popup.openBrowse(1)
                }

                PlasmaComponents3.Button {
                    text: "Избранное"
                    checkable: true
                    checked: popup.browseTab === 2
                    onClicked: popup.openBrowse(2)
                }

                Item { Layout.fillWidth: true }
            }

            // Главная
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === "" && popup.browseTab === 0

                Repeater {
                    model: applet.homeBlocks

                    delegate: ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: modelData.title || ""
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 146
                            orientation: ListView.Horizontal
                            spacing: Kirigami.Units.smallSpacing
                            clip: true
                            model: modelData.items || []

                            delegate: Item {
                                width: 104
                                height: 142

                                ColumnLayout {
                                    anchors.fill: parent
                                    spacing: 2

                                    Rectangle {
                                        Layout.preferredWidth: 96
                                        Layout.preferredHeight: 96
                                        color: Kirigami.Theme.backgroundColor
                                        radius: Kirigami.Units.smallSpacing

                                        Image {
                                            anchors.fill: parent
                                            source: modelData.cover || ""
                                            asynchronous: true
                                            fillMode: Image.PreserveAspectCrop
                                            visible: status === Image.Ready
                                        }

                                        Kirigami.Icon {
                                            anchors.centerIn: parent
                                            source: "audio-x-generic"
                                            implicitWidth: Kirigami.Units.iconSizes.large
                                            implicitHeight: Kirigami.Units.iconSizes.large
                                            visible: !modelData.cover
                                        }
                                    }

                                    PlasmaComponents3.Label {
                                        Layout.fillWidth: true
                                        text: modelData.title || ""
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }

                                    PlasmaComponents3.Label {
                                        Layout.fillWidth: true
                                        text: modelData.subtitle || ""
                                        opacity: 0.7
                                        elide: Text.ElideRight
                                        visible: text !== ""
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        if (modelData.kind === "playlist") {
                                            popup.openPlaylistDetail(modelData.uid, modelData.playlistKind, 0);
                                        } else if (modelData.kind === "album") {
                                            popup.openAlbumDetail(modelData.id, 0);
                                        } else if (modelData.kind === "track") {
                                            applet.cmd("play_track", modelData);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                PlasmaComponents3.Label {
                    text: "Загрузка главной…"
                    opacity: 0.7
                    visible: applet.homeBlocks.length === 0
                }
            }

            // Каталог
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === "" && popup.browseTab === 1

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: "Жанры"
                    font.bold: true
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: applet.genres

                        delegate: PlasmaComponents3.Button {
                            text: modelData.title
                            onClicked: {
                                applet.startStation(modelData.station);
                                popup.view = 0;
                            }
                        }
                    }
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: "Настроения, занятия, жанры, эпохи"
                    font.bold: true
                }

                Repeater {
                    model: applet.metatagGroups

                    delegate: ColumnLayout {
                        id: metatagGroup
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        property var flatTags: popup.flattenTags(modelData.tags || [], 0)

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: modelData.title || "Подборки"
                            font.bold: true
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Repeater {
                                model: metatagGroup.flatTags

                                delegate: PlasmaComponents3.Button {
                                    text: modelData.title
                                    onClicked: popup.openTagDetail(modelData.tag, 1)
                                }
                            }
                        }
                    }
                }

                PlasmaComponents3.Label {
                    text: "Загрузка каталога…"
                    opacity: 0.7
                    visible: applet.genres.length === 0 && applet.metatagGroups.length === 0
                }
            }

            // Избранное
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === "" && popup.browseTab === 2

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: "Избранное"
                        font.bold: true
                    }

                    PlasmaComponents3.Button {
                        text: "Играть все"
                        enabled: applet.favorites.length > 0
                        onClicked: popup.playTracks(applet.favorites)
                    }
                }

                Repeater {
                    model: popup.shownTracks(applet.favorites)
                    delegate: TrackRow {
                        Layout.fillWidth: true
                        item: modelData
                        onClicked: applet.cmd("play_track", modelData)
                    }
                }

                PlasmaComponents3.Label {
                    text: "Показаны первые 50 из " + applet.favorites.length
                    opacity: 0.7
                    visible: applet.favorites.length > 50
                }

                PlasmaComponents3.Label {
                    text: "Загрузка избранного…"
                    opacity: 0.7
                    visible: applet.favorites.length === 0
                }
            }

            // Плейлист
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === "playlist"

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: applet.playlistTitle
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    PlasmaComponents3.Button {
                        text: "Играть"
                        enabled: applet.playlistTracks.length > 0
                        onClicked: popup.playTracks(applet.playlistTracks)
                    }
                }

                Repeater {
                    model: popup.shownTracks(applet.playlistTracks)
                    delegate: TrackRow {
                        Layout.fillWidth: true
                        item: modelData
                        onClicked: applet.cmd("play_track", modelData)
                    }
                }

                PlasmaComponents3.Label {
                    text: "Показаны первые 50 из " + applet.playlistTracks.length
                    opacity: 0.7
                    visible: applet.playlistTracks.length > 50
                }

                PlasmaComponents3.Label {
                    text: "Загрузка плейлиста…"
                    opacity: 0.7
                    visible: applet.playlistTracks.length === 0
                }
            }

            // Альбом
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === "album"

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: applet.albumTitle
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    PlasmaComponents3.Button {
                        text: "Играть"
                        enabled: applet.albumTracks.length > 0
                        onClicked: popup.playTracks(applet.albumTracks)
                    }
                }

                Repeater {
                    model: popup.shownTracks(applet.albumTracks)
                    delegate: TrackRow {
                        Layout.fillWidth: true
                        item: modelData
                        onClicked: applet.cmd("play_track", modelData)
                    }
                }

                PlasmaComponents3.Label {
                    text: "Показаны первые 50 из " + applet.albumTracks.length
                    opacity: 0.7
                    visible: applet.albumTracks.length > 50
                }

                PlasmaComponents3.Label {
                    text: "Загрузка альбома…"
                    opacity: 0.7
                    visible: applet.albumTracks.length === 0
                }
            }

            // Тег / подборка
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: popup.browseDetail === "tag"

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: applet.tagTitle
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    PlasmaComponents3.Button {
                        text: "Играть волну"
                        visible: applet.tagStation !== ""
                        onClicked: {
                            applet.startStation(applet.tagStation);
                            popup.view = 0;
                        }
                    }
                }

                Repeater {
                    model: applet.tagPlaylists

                    delegate: PlasmaComponents3.ItemDelegate {
                        Layout.fillWidth: true
                        text: (modelData.title || "") + (modelData.trackCount
                            ? " · " + modelData.trackCount : "")
                        onClicked: popup.openPlaylistDetail(modelData.uid, modelData.kind, 1)
                    }
                }

                PlasmaComponents3.Label {
                    text: "Загрузка подборки…"
                    opacity: 0.7
                    visible: applet.tagPlaylists.length === 0
                }
            }
        }
    }

    // ---------- Текст ----------
    PlasmaComponents3.ScrollView {
        id: lyricsScroll
        anchors.fill: parent
        visible: popup.view === 2
        contentWidth: availableWidth
        padding: Kirigami.Units.largeSpacing

        ColumnLayout {
            id: lyricsColumn
            width: lyricsScroll.availableWidth
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Button {
                    text: "←"
                    onClicked: popup.view = 0
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: applet.track ? (applet.title + " — " + applet.artistLine) : "Текст"
                    font.bold: true
                    elide: Text.ElideRight
                }

                PlasmaComponents3.Button {
                    text: "Обновить"
                    onClicked: applet.loadLyrics()
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: popup.currentLyricText
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                color: Kirigami.Theme.highlightColor
                wrapMode: Text.WordWrap
                visible: text !== ""
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: popup.nextLyricText
                opacity: 0.7
                wrapMode: Text.WordWrap
                visible: text !== ""
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
                visible: applet.lyricsLines.length > 0
            }

            Repeater {
                model: applet.lyricsLines

                delegate: PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: modelData.text
                    opacity: index === popup.currentLyric ? 1 : 0.55
                    font.bold: index === popup.currentLyric
                    color: index === popup.currentLyric
                        ? Kirigami.Theme.highlightColor
                        : Kirigami.Theme.textColor
                    wrapMode: Text.WordWrap
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: applet.lyricsText
                wrapMode: Text.WordWrap
                visible: applet.lyricsLines.length === 0 && applet.lyricsText !== ""
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: applet.lyricsError
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
                visible: text !== ""
            }

            PlasmaComponents3.Label {
                text: "Загрузка текста…"
                opacity: 0.7
                visible: applet.lyricsLines.length === 0
                    && applet.lyricsText === ""
                    && applet.lyricsError === ""
            }
        }
    }
}
