import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "format.js" as Format

Kirigami.ApplicationWindow {
    id: root
    width: 420
    height: 640
    minimumWidth: 360
    minimumHeight: 520
    title: "ymd"
    visible: true

    property var st: client.state || ({})
    property var track: st.track || ({})
    property var queue: st.queue || ({})
    property var queueItems: queue.items || []
    property int queueIndex: queue.index === undefined ? -1 : queue.index
    property int durationMs: track.durationMs || 0
    property int positionMs: st.positionMs || 0
    property real volume: st.volume === undefined ? 0.8 : Number(st.volume)
    property string status: st.status || "stopped"
    property string quality: st.quality || "lossless"
    property bool playing: status === "playing"
    property string repeatMode: queue.repeat || "off"
    property bool shuffle: queue.shuffle === true
    property string artistLine: {
        var artists = track.artists || [];
        return artists.length ? artists.join(", ") : "";
    }
    property string repeatLabel: repeatMode === "all" ? "все"
        : (repeatMode === "one" ? "один" : "выкл")
    property string statusLine: (playing ? "Играет" : (status === "paused" ? "Пауза" : "Остановлено"))
        + " · " + Format.streamLabel(quality, st.codec, st.bitrateKbps)
    property string playlistFilter: ""
    property int deletePlaylistKind: 0
    property string deletePlaylistTitle: ""
    property var actionTrack: ({})
    property var infoTrack: ({})
    property var downloads: st.downloads || []
    property int downloadPending: st.downloadPending || 0

    function send(op) {
        client.cmd(op, {});
    }

    function downloadItem(item) {
        if (!item || !item.id || item.cached) {
            return;
        }
        client.download(item);
    }

    function likeItem(item) {
        if (!item || item.id === undefined) {
            return;
        }
        client.likeTrack(String(item.id), item.liked !== true);
    }

    function enqueueItem(item) {
        if (!item || item.id === undefined) {
            return;
        }
        client.cmd("enqueue", item);
    }

    function openAddToPlaylist(item) {
        if (!item || item.id === undefined) {
            return;
        }
        root.actionTrack = item;
        addToPlaylistDialog.open();
    }

    function openArtist(item) {
        if (!item || item.artistId === undefined) {
            return;
        }
        artistDialog.open();
        client.loadArtist(String(item.artistId));
    }

    function openAlbum(item) {
        if (!item || item.albumId === undefined) {
            return;
        }
        albumDialog.open();
        client.loadAlbum(String(item.albumId));
    }

    function openTrackInfo(item) {
        if (!item || item.id === undefined) {
            return;
        }
        root.infoTrack = item;
        trackInfoDialog.open();
    }

    function infoState(item) {
        var parts = [];
        if (item.cached) {
            parts.push("в офлайн-кэше");
        }
        if (item.liked) {
            parts.push("в любимых");
        }
        return parts.length ? parts.join(", ") : "не сохранён";
    }

    function startTrackStation(item) {
        if (!item || item.id === undefined) {
            return;
        }
        client.startStation("track:" + String(item.id));
    }

    function startArtistStation(item) {
        if (!item || item.artistId === undefined) {
            return;
        }
        client.startStation("artist:" + String(item.artistId));
    }

    function playTracks(tracks) {
        if (!tracks || tracks.length === 0) {
            return;
        }
        client.cmd("queue_set", {
            "tracks": tracks,
            "index": 0,
            "play": true
        });
    }

    function openPlaylist(uid, kind, title) {
        if (kind === undefined || kind === null) {
            return;
        }
        browseDialog.close();
        tagDialog.close();
        playlistsDialog.pendingUid = uid === undefined ? 0 : uid;
        playlistsDialog.pendingKind = kind;
        playlistsDialog.pendingTitle = title || "";
        playlistsDialog.open();
    }

    function openTag(tag, title) {
        if (!tag) {
            return;
        }
        tagDialog.tagTitle = title || "Подборка";
        tagDialog.open();
        client.loadTag(tag);
    }

    function flattenTags(nodes, depth) {
        var out = [];
        if (!nodes) {
            return out;
        }
        for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            out.push({
                "tag": node.tag,
                "title": node.title,
                "depth": depth || 0
            });
            if (node.children && node.children.length > 0) {
                out = out.concat(flattenTags(node.children, (depth || 0) + 1));
            }
        }
        return out;
    }

    function filteredTracks() {
        var query = playlistFilter.trim().toLowerCase();
        if (!query) {
            return client.playlistTracks;
        }
        return client.playlistTracks.filter(function(item) {
            var artists = (item.artists || []).join(", ");
            return (String(item.title || "") + " " + artists).toLowerCase().indexOf(query) >= 0;
        });
    }

    onClosing: function(close) {
        close.accepted = false;
        root.visible = false;
    }

    Shortcut {
        sequence: "Space"
        enabled: !searchField.activeFocus
        onActivated: root.send("toggle")
    }
    Shortcut {
        sequence: "Left"
        enabled: !searchField.activeFocus
        onActivated: client.seek(Math.max(0, root.positionMs - 5000))
    }
    Shortcut {
        sequence: "Right"
        enabled: !searchField.activeFocus
        onActivated: client.seek(root.positionMs + 5000)
    }
    Shortcut {
        sequence: "Ctrl+F"
        onActivated: searchField.forceActiveFocus()
    }
    Shortcut {
        sequence: "Ctrl+O"
        onActivated: browseDialog.open()
    }
    Shortcut {
        sequence: "Ctrl+P"
        onActivated: playlistsDialog.open()
    }
    Shortcut {
        sequence: "Ctrl+K"
        onActivated: cacheDialog.open()
    }
    Shortcut {
        sequence: "Esc"
        onActivated: root.visible = false
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.largeSpacing
        anchors.rightMargin: Kirigami.Units.largeSpacing
        anchors.topMargin: Kirigami.Units.largeSpacing
        anchors.bottomMargin: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true

            Kirigami.Heading {
                text: "ymd"
                level: 2
                Layout.fillWidth: true
            }

            Controls.ToolButton {
                icon.name: "settings-configure"
                icon.width: Kirigami.Units.iconSizes.smallMedium
                icon.height: Kirigami.Units.iconSizes.smallMedium
                icon.color: Kirigami.Theme.textColor
                onClicked: settingsDialog.open()
                Controls.ToolTip.text: "Настройки"
                Controls.ToolTip.visible: hovered
            }

            Controls.ToolButton {
                text: "✕"
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                onClicked: root.visible = false
                Controls.ToolTip.text: "Скрыть в трей"
                Controls.ToolTip.visible: hovered
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Rectangle {
                Layout.preferredWidth: 128
                Layout.preferredHeight: 128
                color: Kirigami.Theme.backgroundColor
                radius: Kirigami.Units.smallSpacing

                Image {
                    id: coverImage
                    anchors.fill: parent
                    source: root.track.cover || ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }

                Kirigami.Icon {
                    anchors.centerIn: parent
                    source: "audio-x-generic"
                    width: Kirigami.Units.iconSizes.huge
                    height: width
                    visible: !coverImage.visible
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: root.track.title || "Ничего не играет"
                    font.bold: true
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Controls.Label {
                    text: root.artistLine
                    color: Kirigami.Theme.disabledTextColor
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Controls.Label {
                    text: root.statusLine
                    color: Kirigami.Theme.disabledTextColor
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }

        Controls.Slider {
            id: seekSlider
            Layout.fillWidth: true
            from: 0
            to: Math.max(1, root.durationMs)
            value: root.positionMs
            enabled: root.durationMs > 0
            onPressedChanged: {
                if (!pressed && root.durationMs > 0) {
                    client.seek(value);
                }
            }
        }

        Binding {
            target: seekSlider
            property: "value"
            value: root.positionMs
            when: !seekSlider.pressed
        }

        RowLayout {
            Layout.fillWidth: true

            Controls.Label {
                text: Format.formatTime(root.positionMs)
                color: Kirigami.Theme.disabledTextColor
            }

            Item {
                Layout.fillWidth: true
            }

            Controls.Label {
                text: Format.formatTime(root.durationMs)
                color: Kirigami.Theme.disabledTextColor
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Kirigami.Units.largeSpacing

            TransportButton {
                kind: "prev"
                onClicked: root.send("prev")
                Controls.ToolTip.text: "Предыдущий"
                Controls.ToolTip.visible: hovered
            }

            TransportButton {
                kind: root.playing ? "pause" : "play"
                implicitWidth: Kirigami.Units.gridUnit * 2.4
                implicitHeight: Kirigami.Units.gridUnit * 2.4
                onClicked: root.send("toggle")
                Controls.ToolTip.text: root.playing ? "Пауза" : "Играть"
                Controls.ToolTip.visible: hovered
            }

            TransportButton {
                kind: "next"
                onClicked: root.send("next")
                Controls.ToolTip.text: "Следующий"
                Controls.ToolTip.visible: hovered
            }

            Controls.ToolButton {
                text: root.track.liked === true ? "♥" : "♡"
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 4
                opacity: root.track.liked === true ? 1 : 0.45
                enabled: root.track.id !== undefined
                onClicked: root.likeItem(root.track)
                Controls.ToolTip.text: "Нравится"
                Controls.ToolTip.visible: hovered
            }

            Controls.ToolButton {
                text: root.track.cached === true ? "✓" : "⤓"
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                opacity: root.track.cached === true ? 0.55 : 1
                enabled: root.track.id !== undefined
                onClicked: root.downloadItem(root.track)
                Controls.ToolTip.text: root.track.cached === true ? "Уже в кэше" : "Скачать трек"
                Controls.ToolTip.visible: hovered
            }

            TransportButton {
                kind: "wave"
                onClicked: root.send("wave_start")
                Controls.ToolTip.text: "Волна"
                Controls.ToolTip.visible: hovered
            }

            Controls.ToolButton {
                id: volumeButton
                icon.name: root.volume <= 0.001
                    ? "audio-volume-muted"
                    : root.volume < 0.34
                        ? "audio-volume-low"
                        : root.volume < 0.67
                            ? "audio-volume-medium"
                            : "audio-volume-high"
                icon.width: Kirigami.Units.iconSizes.smallMedium
                icon.height: Kirigami.Units.iconSizes.smallMedium
                icon.color: Kirigami.Theme.textColor
                onClicked: volumePopup.opened ? volumePopup.close() : volumePopup.open()
                Controls.ToolTip.text: "Громкость: " + Math.round(root.volume * 100) + "%"
                Controls.ToolTip.visible: hovered
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Kirigami.Units.largeSpacing

            Controls.ToolButton {
                icon.name: root.repeatMode === "one"
                    ? "media-playlist-repeat-song"
                    : "media-playlist-repeat"
                icon.width: Kirigami.Units.iconSizes.smallMedium
                icon.height: Kirigami.Units.iconSizes.smallMedium
                icon.color: root.repeatMode === "off"
                    ? Kirigami.Theme.disabledTextColor
                    : Kirigami.Theme.highlightColor
                opacity: root.repeatMode === "off" ? 0.45 : 1
                onClicked: client.cmd("repeat", { "value": Format.repeatNext(root.repeatMode) })
                Controls.ToolTip.text: "Повтор: " + root.repeatLabel
                Controls.ToolTip.visible: hovered
            }

            Controls.ToolButton {
                icon.name: "media-playlist-shuffle"
                icon.width: Kirigami.Units.iconSizes.smallMedium
                icon.height: Kirigami.Units.iconSizes.smallMedium
                icon.color: root.shuffle
                    ? Kirigami.Theme.highlightColor
                    : Kirigami.Theme.disabledTextColor
                opacity: root.shuffle ? 1 : 0.45
                onClicked: client.cmd("shuffle", { "value": !root.shuffle })
                Controls.ToolTip.text: "Перемешать: " + (root.shuffle ? "вкл" : "выкл")
                Controls.ToolTip.visible: hovered
            }

            Controls.ToolButton {
                icon.name: "media-optical-audio"
                icon.width: Kirigami.Units.iconSizes.smallMedium
                icon.height: Kirigami.Units.iconSizes.smallMedium
                icon.color: Kirigami.Theme.textColor
                onClicked: client.cmd("quality", { "value": Format.qualityNext(root.quality) })
                Controls.ToolTip.text: "Качество: " + Format.qualityLabel(root.quality)
                Controls.ToolTip.visible: hovered
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Kirigami.Units.largeSpacing

            Controls.Button {
                text: "Обзор"
                onClicked: browseDialog.open()
            }

            Controls.Button {
                text: "Плейлисты"
                onClicked: playlistsDialog.open()
            }

            Controls.Button {
                text: "Кэш"
                onClicked: cacheDialog.open()
            }
        }

        Repeater {
            model: root.downloads

            delegate: RowLayout {
                Layout.fillWidth: true
                visible: modelData.state === "downloading"
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: "⤓ " + (modelData.title || modelData.id)
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Controls.ProgressBar {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                    from: 0
                    to: Math.max(1, modelData.total || 0)
                    value: Math.min(modelData.bytes || 0, modelData.total || 0)
                }

                Controls.Label {
                    text: modelData.total > 0
                        ? Math.round((modelData.bytes || 0) * 100 / modelData.total) + "%"
                        : "…"
                    color: Kirigami.Theme.disabledTextColor
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                }
            }
        }

        Controls.Label {
            Layout.alignment: Qt.AlignHCenter
            visible: root.downloadPending > 0
            text: "В очереди на скачивание: " + root.downloadPending
            color: Kirigami.Theme.disabledTextColor
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: errorRow.implicitHeight + Kirigami.Units.smallSpacing * 2
            visible: client.lastError.length > 0
            color: Kirigami.Theme.backgroundColor
            border.width: 1
            border.color: Kirigami.Theme.negativeTextColor
            radius: Kirigami.Units.smallSpacing

            RowLayout {
                id: errorRow
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: client.lastError
                    color: Kirigami.Theme.negativeTextColor
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }

                Controls.Button {
                    text: "Повторить"
                    onClicked: client.retryKey()
                }
            }
        }

        Controls.TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Поиск"
            onAccepted: client.search(text)
        }

        Controls.Label {
            visible: client.searching
                || (searchField.text.length > 0 && client.searchResults.length === 0)
            text: client.searching ? "Ищу…" : "Ничего не найдено"
            color: Kirigami.Theme.disabledTextColor
        }

        Repeater {
            model: Math.min(6, client.searchResults.length)

            delegate: TrackRow {
                Layout.fillWidth: true
                item: client.searchResults[index]
                showDownload: true
                onClicked: client.cmd("play_track", client.searchResults[index])
                onDownloadClicked: root.downloadItem(client.searchResults[index])
                onPlayRequested: client.cmd("play_track", client.searchResults[index])
                onEnqueueRequested: root.enqueueItem(client.searchResults[index])
                onLikeRequested: root.likeItem(client.searchResults[index])
                onAddToPlaylistRequested: root.openAddToPlaylist(client.searchResults[index])
                onCopyLinkRequested: client.copyLink(String(client.searchResults[index].id))
                onArtistRequested: root.openArtist(client.searchResults[index])
                onAlbumRequested: root.openAlbum(client.searchResults[index])
                onStationTrackRequested: root.startTrackStation(client.searchResults[index])
                onStationArtistRequested: root.startArtistStation(client.searchResults[index])
                onInfoRequested: root.openTrackInfo(client.searchResults[index])
            }
        }

        Controls.Label {
            text: "Очередь"
            font.bold: true
            visible: root.queueItems.length > 0
        }

        ListView {
            id: queueView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.queueItems

            delegate: TrackRow {
                width: queueView.width
                item: modelData
                rowIndex: index
                showIndex: true
                current: index === root.queueIndex
                showDownload: true
                reorderable: true
                showRemoveFromQueue: true
                showEnqueue: false
                onClicked: client.cmd("queue_play", { "index": index })
                onDownloadClicked: root.downloadItem(modelData)
                onPlayRequested: client.cmd("queue_play", { "index": index })
                onLikeRequested: root.likeItem(modelData)
                onAddToPlaylistRequested: root.openAddToPlaylist(modelData)
                onCopyLinkRequested: client.copyLink(String(modelData.id))
                onArtistRequested: root.openArtist(modelData)
                onAlbumRequested: root.openAlbum(modelData)
                onStationTrackRequested: root.startTrackStation(modelData)
                onStationArtistRequested: root.startArtistStation(modelData)
                onInfoRequested: root.openTrackInfo(modelData)
                onRemoveFromQueueRequested: client.cmd("queue_remove", { "index": index })
                onMoveRequested: function(from, to) {
                    client.cmd("queue_move", { "from": from, "to": to });
                }
            }
        }

        Controls.Label {
            text: "Очередь пуста"
            color: Kirigami.Theme.disabledTextColor
            visible: root.queueItems.length === 0
        }

        Item {
            Layout.preferredHeight: Kirigami.Units.largeSpacing
        }
    }

    Controls.Popup {
        id: volumePopup
        parent: volumeButton
        x: Math.round((volumeButton.width - width) / 2)
        y: -height - Kirigami.Units.smallSpacing
        width: Kirigami.Units.gridUnit * 2.6
        height: Kirigami.Units.gridUnit * 7
        modal: false
        closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside

        background: Rectangle {
            color: Kirigami.Theme.backgroundColor
            radius: Kirigami.Units.smallSpacing
            border.width: 1
            border.color: Kirigami.Theme.disabledTextColor
        }

        contentItem: Item {
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Controls.Slider {
                    id: volumePopupSlider
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: Qt.Vertical
                    from: 0
                    to: 1
                    value: root.volume
                    onMoved: client.cmd("volume", { "value": value })
                }

                Controls.Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: Math.round(volumePopupSlider.value * 100) + "%"
                    color: Kirigami.Theme.textColor
                }
            }
        }

        onOpened: volumePopupSlider.value = root.volume
    }

    Binding {
        target: volumePopupSlider
        property: "value"
        value: root.volume
        when: !volumePopupSlider.pressed
    }

    Controls.Dialog {
        id: settingsDialog
        title: "Настройки"
        modal: true
        width: Math.min(420, root.width - 32)
        height: Math.min(460, root.height - 32)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close

        function syncFromState() {
            var current = root.quality;
            for (var i = 0; i < qualityCombo.model.length; ++i) {
                if (qualityCombo.model[i].value === current) {
                    qualityCombo.currentIndex = i;
                    break;
                }
            }
            settingsCacheLimitSpin.value = Math.max(settingsCacheLimitSpin.from,
                Math.round(client.cacheLimitBytes / 1048576));
            client.loadCache();
        }

        onOpened: syncFromState()

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                Layout.fillWidth: true
                text: "Качество воспроизведения"
                font.bold: true
            }

            Controls.ComboBox {
                id: qualityCombo
                Layout.fillWidth: true
                textRole: "text"
                model: [
                    { text: "FLAC (lossless)", value: "lossless" },
                    { text: "Высокое (HQ)", value: "hq" },
                    { text: "Среднее (NQ)", value: "nq" },
                    { text: "Низкое (LQ)", value: "lq" }
                ]
            }

            Controls.Label {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                text: "Лимит кэша, МБ"
                font.bold: true
            }

            Controls.SpinBox {
                id: settingsCacheLimitSpin
                Layout.fillWidth: true
                from: 128
                to: 102400
                stepSize: 128
                editable: true
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "Занято " + Format.bytes(client.cacheTotalBytes)
                    + " из " + Format.bytes(client.cacheLimitBytes)
                color: Kirigami.Theme.disabledTextColor
                elide: Text.ElideRight
            }

            RowLayout {
                Layout.fillWidth: true

                Controls.Button {
                    text: "Очистить кэш"
                    onClicked: client.clearCache()
                }

                Item {
                    Layout.fillWidth: true
                }

                Controls.Button {
                    text: "Управление кэшем"
                    onClicked: {
                        settingsDialog.close();
                        cacheDialog.open();
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                text: "Цвета интерфейса берутся из темы KDE."
                color: Kirigami.Theme.disabledTextColor
                wrapMode: Text.WordWrap
            }

            Item {
                Layout.fillHeight: true
            }

            RowLayout {
                Layout.fillWidth: true

                Controls.Button {
                    text: "О программе"
                    onClicked: aboutDialog.open()
                }

                Item {
                    Layout.fillWidth: true
                }

                Controls.Button {
                    text: "Сохранить"
                    highlighted: true
                    onClicked: {
                        var item = qualityCombo.model[qualityCombo.currentIndex];
                        if (item) {
                            client.cmd("quality", { "value": item.value });
                        }
                        client.setCacheLimit(settingsCacheLimitSpin.value);
                        settingsDialog.close();
                    }
                }
            }
        }
    }

    Controls.Dialog {
        id: aboutDialog
        title: "О программе"
        modal: true
        width: Math.min(360, root.width - 32)
        height: Math.min(400, root.height - 32)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "ymd-qt"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Kirigami.Units.iconSizes.huge
                Layout.preferredHeight: Kirigami.Units.iconSizes.huge
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "ymd"
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 6
                horizontalAlignment: Text.AlignHCenter
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "Неофициальный клиент Яндекс Музыки"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "Авторы: Павел Болховитин, Леонид Юрасов"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "Версия " + Qt.application.version
                horizontalAlignment: Text.AlignHCenter
                color: Kirigami.Theme.disabledTextColor
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "Лицензия MIT"
                horizontalAlignment: Text.AlignHCenter
                color: Kirigami.Theme.disabledTextColor
            }

            Controls.Label {
                Layout.fillWidth: true
                text: client.keyReady ? "Демон подключён" : "Нет ключа демона"
                horizontalAlignment: Text.AlignHCenter
                color: client.keyReady
                    ? Kirigami.Theme.disabledTextColor
                    : Kirigami.Theme.negativeTextColor
            }

            Item {
                Layout.fillHeight: true
            }

            Controls.Button {
                Layout.fillWidth: true
                text: "Открыть GitHub"
                onClicked: Qt.openUrlExternally("https://github.com/pbolkhovitin/ym-noctalia")
            }
        }
    }

    Connections {
        target: client

        function onPlaylistsChanged() {
            playlistsDialog.loadingPlaylists = false;
        }

        function onPlaylistTracksChanged() {
            playlistsDialog.loadingTracks = false;
        }

        function onCacheChanged() {
            cacheDialog.loadingCache = false;
            cacheLimitSpin.value = Math.round(client.cacheLimitBytes / 1048576);
            settingsCacheLimitSpin.value = Math.max(settingsCacheLimitSpin.from,
                Math.round(client.cacheLimitBytes / 1048576));
        }

        function onKeyChanged() {
            if (!client.keyReady || !browseDialog.visible) {
                return;
            }
            if (client.homeBlocks.length === 0) {
                client.loadHome();
            }
            if (client.metatagGroups.length === 0) {
                client.loadMetatags();
            }
            if (client.genres.length === 0) {
                client.loadGenres();
            }
            if (client.favorites.length === 0) {
                client.loadFavorites();
            }
        }
    }

    Controls.Dialog {
        id: browseDialog
        title: "Обзор"
        modal: true
        width: Math.max(320, root.width - 16)
        height: Math.max(420, root.height - 16)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close
        property int tab: 0

        onOpened: {
            if (client.homeBlocks.length === 0) {
                client.loadHome();
            }
            if (client.metatagGroups.length === 0) {
                client.loadMetatags();
            }
            if (client.genres.length === 0) {
                client.loadGenres();
            }
            if (client.favorites.length === 0) {
                client.loadFavorites();
            }
        }

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.Button {
                    text: "Главная"
                    checkable: true
                    checked: browseDialog.tab === 0
                    onClicked: browseDialog.tab = 0
                }

                Controls.Button {
                    text: "Каталог"
                    checkable: true
                    checked: browseDialog.tab === 1
                    onClicked: browseDialog.tab = 1
                }

                Controls.Button {
                    text: "Избранное"
                    checkable: true
                    checked: browseDialog.tab === 2
                    onClicked: browseDialog.tab = 2
                }
            }

            Controls.ScrollView {
                id: browseHome
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: browseDialog.tab === 0
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: browseHome.availableWidth
                    spacing: Kirigami.Units.largeSpacing

                    Repeater {
                        model: client.homeBlocks

                        delegate: ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                Layout.fillWidth: true
                                text: modelData.title || "Подборка"
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            ListView {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 172
                                orientation: ListView.Horizontal
                                spacing: Kirigami.Units.smallSpacing
                                clip: true
                                model: modelData.items

                                delegate: Controls.ItemDelegate {
                                    width: 132
                                    height: 168
                                    padding: 0

                                    onClicked: {
                                        if (modelData.kind === "playlist") {
                                            root.openPlaylist(modelData.uid, modelData.playlistKind, modelData.title);
                                        } else if (modelData.kind === "album") {
                                            browseDialog.close();
                                            root.openAlbum({ "albumId": String(modelData.id) });
                                        } else {
                                            browseDialog.close();
                                            client.cmd("play_track", modelData);
                                        }
                                    }

                                    contentItem: ColumnLayout {
                                        spacing: 2

                                        Rectangle {
                                            Layout.preferredWidth: 120
                                            Layout.preferredHeight: 120
                                            radius: Kirigami.Units.smallSpacing
                                            color: Kirigami.Theme.backgroundColor

                                            Image {
                                                id: homeCover
                                                anchors.fill: parent
                                                source: modelData.cover || ""
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                visible: status === Image.Ready
                                            }

                                            Kirigami.Icon {
                                                anchors.centerIn: parent
                                                source: "audio-x-generic"
                                                width: Kirigami.Units.iconSizes.large
                                                height: width
                                                visible: !homeCover.visible
                                            }
                                        }

                                        Controls.Label {
                                            Layout.fillWidth: true
                                            text: modelData.title || "Без названия"
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }

                                        Controls.Label {
                                            Layout.fillWidth: true
                                            text: modelData.subtitle
                                                || (modelData.trackCount !== undefined
                                                    ? modelData.trackCount + " треков" : "")
                                            color: Kirigami.Theme.disabledTextColor
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        visible: client.homeBlocks.length === 0
                        text: "Загрузка главной…"
                        color: Kirigami.Theme.disabledTextColor
                    }
                }
            }

            Controls.ScrollView {
                id: browseCatalog
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: browseDialog.tab === 1
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: browseCatalog.availableWidth
                    spacing: Kirigami.Units.largeSpacing

                    Controls.Label {
                        Layout.fillWidth: true
                        text: "Жанры"
                        font.bold: true
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: client.genres

                            delegate: Controls.Button {
                                text: modelData.title
                                onClicked: {
                                    client.startStation(modelData.station);
                                    browseDialog.close();
                                }
                            }
                        }
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        text: "Настроения, занятия, жанры, эпохи"
                        font.bold: true
                    }

                    Repeater {
                        model: client.metatagGroups

                        delegate: ColumnLayout {
                            id: metatagGroup
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            property var flatTags: root.flattenTags(modelData.tags)

                            Controls.Label {
                                Layout.fillWidth: true
                                text: modelData.title || "Подборки"
                                font.bold: true
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Repeater {
                                    model: metatagGroup.flatTags

                                    delegate: Controls.Button {
                                        text: (modelData.depth > 0 ? "· " : "")
                                            + (modelData.title || modelData.tag)
                                        onClicked: root.openTag(modelData.tag, modelData.title)
                                    }
                                }
                            }
                        }
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        visible: client.genres.length === 0
                            && client.metatagGroups.length === 0
                        text: "Загрузка каталога…"
                        color: Kirigami.Theme.disabledTextColor
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: browseDialog.tab === 2
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true

                    Controls.Label {
                        Layout.fillWidth: true
                        text: "Мне нравится"
                        font.bold: true
                    }

                    Controls.Button {
                        text: "Играть все"
                        enabled: client.favorites.length > 0
                        onClicked: {
                            root.playTracks(client.favorites);
                            browseDialog.close();
                        }
                    }
                }

                ListView {
                    id: favoritesView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: client.favorites

                    delegate: TrackRow {
                        width: favoritesView.width
                        item: modelData
                        rowIndex: index
                        showIndex: true
                        showDownload: true
                        onClicked: client.cmd("play_track", modelData)
                        onDownloadClicked: root.downloadItem(modelData)
                        onPlayRequested: client.cmd("play_track", modelData)
                        onEnqueueRequested: root.enqueueItem(modelData)
                        onLikeRequested: root.likeItem(modelData)
                        onAddToPlaylistRequested: root.openAddToPlaylist(modelData)
                        onCopyLinkRequested: client.copyLink(String(modelData.id))
                        onArtistRequested: root.openArtist(modelData)
                        onAlbumRequested: root.openAlbum(modelData)
                        onStationTrackRequested: root.startTrackStation(modelData)
                        onStationArtistRequested: root.startArtistStation(modelData)
                        onInfoRequested: root.openTrackInfo(modelData)
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    visible: client.favorites.length === 0
                    text: "Загрузка избранного…"
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }
    }

    Controls.Dialog {
        id: tagDialog
        property string tagTitle: ""
        title: tagTitle || "Подборка"
        modal: true
        width: Math.max(320, root.width - 16)
        height: Math.max(420, root.height - 16)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true

                Controls.Label {
                    Layout.fillWidth: true
                    text: client.tagTitle || tagDialog.tagTitle || "Подборка"
                    font.bold: true
                    elide: Text.ElideRight
                }

                Controls.Button {
                    text: "Играть волну"
                    visible: client.tagStation.length > 0
                    onClicked: {
                        client.startStation(client.tagStation);
                        tagDialog.close();
                    }
                }
            }

            ListView {
                id: tagPlaylistsView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: client.tagPlaylists

                delegate: Controls.ItemDelegate {
                    width: tagPlaylistsView.width
                    onClicked: root.openPlaylist(modelData.uid, modelData.kind, modelData.title)

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            Layout.preferredWidth: 40
                            Layout.preferredHeight: 40
                            radius: Kirigami.Units.smallSpacing
                            color: Kirigami.Theme.backgroundColor

                            Image {
                                id: tagCover
                                anchors.fill: parent
                                source: modelData.cover || ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                visible: status === Image.Ready
                            }

                            Kirigami.Icon {
                                anchors.centerIn: parent
                                source: "audio-x-generic"
                                width: Kirigami.Units.iconSizes.small
                                height: width
                                visible: !tagCover.visible
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Controls.Label {
                                Layout.fillWidth: true
                                text: modelData.title || "Плейлист"
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                text: (modelData.trackCount || 0) + " треков"
                                color: Kirigami.Theme.disabledTextColor
                            }
                        }
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: client.tagPlaylists.length === 0
                text: "Загрузка подборки…"
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Controls.Dialog {
        id: playlistsDialog
        title: "Мои плейлисты"
        modal: true
        width: Math.min(400, root.width - Kirigami.Units.largeSpacing * 2)
        height: Math.min(560, root.height - Kirigami.Units.largeSpacing * 2)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close
        property bool showingTracks: false
        property bool loadingPlaylists: false
        property bool loadingTracks: false
        property int currentKind: 0
        property int pendingUid: 0
        property int pendingKind: 0
        property string pendingTitle: ""

        onOpened: {
            showingTracks = false;
            loadingTracks = false;
            loadingPlaylists = true;
            root.playlistFilter = "";
            playlistSearchField.text = "";
            client.loadPlaylists();

            if (pendingKind > 0) {
                showingTracks = true;
                loadingTracks = true;
                currentKind = pendingKind;
                client.loadPlaylist(pendingUid, pendingKind);
                pendingKind = 0;
            }
        }

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                visible: playlistsDialog.showingTracks

                Controls.ToolButton {
                    text: "←"
                    onClicked: {
                        playlistsDialog.showingTracks = false;
                        root.playlistFilter = "";
                        playlistSearchField.text = "";
                    }
                    Controls.ToolTip.text: "К списку плейлистов"
                    Controls.ToolTip.visible: hovered
                }

                Controls.Label {
                    Layout.fillWidth: true
                    text: client.playlistTitle || "Плейлист"
                    font.bold: true
                    elide: Text.ElideRight
                }

                Controls.Button {
                    text: "Скачать все"
                    enabled: client.playlistTracks.length > 0
                    onClicked: client.downloadAll(client.playlistTracks)
                    Controls.ToolTip.text: "Поставить весь плейлист в очередь на скачивание"
                    Controls.ToolTip.visible: hovered
                }

                Controls.Button {
                    text: "Играть"
                    enabled: client.playlistTracks.length > 0
                    onClicked: {
                        client.cmd("queue_set", {
                            "tracks": client.playlistTracks,
                            "index": 0,
                            "play": true
                        });
                        playlistsDialog.close();
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: playlistsDialog.showingTracks && root.downloadPending > 0
                text: "В очереди на скачивание: " + root.downloadPending
                color: Kirigami.Theme.disabledTextColor
            }

            RowLayout {
                Layout.fillWidth: true
                visible: playlistsDialog.showingTracks

                Controls.TextField {
                    id: playlistSearchField
                    Layout.fillWidth: true
                    placeholderText: "Поиск по плейлисту"
                    onTextChanged: root.playlistFilter = text
                }

                Controls.Label {
                    text: root.filteredTracks().length + " / " + client.playlistTracks.length
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: !playlistsDialog.showingTracks

                Controls.Button {
                    text: "Создать плейлист"
                    onClicked: {
                        newPlaylistField.text = "";
                        newPlaylistDialog.open();
                    }
                }

                Item {
                    Layout.fillWidth: true
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: !playlistsDialog.showingTracks && client.playlists.length === 0
                text: playlistsDialog.loadingPlaylists ? "Загрузка плейлистов…" : "Плейлистов нет"
                color: Kirigami.Theme.disabledTextColor
            }

            ListView {
                id: playlistsView
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !playlistsDialog.showingTracks
                clip: true
                model: client.playlists

                delegate: Controls.ItemDelegate {
                    width: playlistsView.width
                    onClicked: {
                        playlistsDialog.loadingTracks = true;
                        playlistsDialog.showingTracks = true;
                        playlistsDialog.currentKind = modelData.kind;
                        root.playlistFilter = "";
                        playlistSearchField.text = "";
                        client.loadPlaylist(modelData.uid, modelData.kind);
                    }

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            Layout.preferredWidth: 40
                            Layout.preferredHeight: 40
                            radius: Kirigami.Units.smallSpacing
                            color: Kirigami.Theme.backgroundColor

                            Image {
                                id: playlistCover
                                anchors.fill: parent
                                source: modelData.cover || ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                visible: status === Image.Ready
                            }

                            Kirigami.Icon {
                                anchors.centerIn: parent
                                source: "audio-x-generic"
                                width: Kirigami.Units.iconSizes.small
                                height: width
                                visible: !playlistCover.visible
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Controls.Label {
                                Layout.fillWidth: true
                                text: modelData.title || "Без названия"
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                text: (modelData.trackCount || 0) + " треков"
                                color: Kirigami.Theme.disabledTextColor
                            }
                        }

                        Controls.ToolButton {
                            text: "🗑"
                            onClicked: {
                                root.deletePlaylistKind = modelData.kind;
                                root.deletePlaylistTitle = modelData.title || "Плейлист";
                                deletePlaylistDialog.open();
                            }
                            Controls.ToolTip.text: "Удалить плейлист"
                            Controls.ToolTip.visible: hovered
                        }
                    }
                }
            }

            ListView {
                id: playlistTracksView
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: playlistsDialog.showingTracks
                    && root.filteredTracks().length > 0
                clip: true
                model: root.filteredTracks()

                delegate: TrackRow {
                    width: playlistTracksView.width
                    item: modelData
                    rowIndex: index
                    showIndex: true
                    showDownload: true
                    showRemoveFromPlaylist: true
                    onClicked: client.cmd("play_track", modelData)
                    onDownloadClicked: root.downloadItem(modelData)
                    onPlayRequested: client.cmd("play_track", modelData)
                    onEnqueueRequested: root.enqueueItem(modelData)
                    onLikeRequested: root.likeItem(modelData)
                    onAddToPlaylistRequested: root.openAddToPlaylist(modelData)
                    onCopyLinkRequested: client.copyLink(String(modelData.id))
                    onArtistRequested: root.openArtist(modelData)
                    onAlbumRequested: root.openAlbum(modelData)
                    onStationTrackRequested: root.startTrackStation(modelData)
                    onStationArtistRequested: root.startArtistStation(modelData)
                    onInfoRequested: root.openTrackInfo(modelData)
                    onRemoveFromPlaylistRequested: {
                        var original = modelData.playlistIndex !== undefined
                            ? modelData.playlistIndex
                            : index;
                        client.removeTrackFromPlaylist(playlistsDialog.currentKind, original);
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: playlistsDialog.showingTracks && root.filteredTracks().length === 0
                text: playlistsDialog.loadingTracks ? "Загрузка треков…"
                    : (client.playlistTracks.length === 0 ? "В плейлисте нет треков"
                                                          : "Ничего не найдено")
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Controls.Dialog {
        id: newPlaylistDialog
        title: "Новый плейлист"
        modal: true
        width: Math.min(360, root.width - Kirigami.Units.largeSpacing * 2)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Ok | Controls.Dialog.Cancel

        onAccepted: client.createPlaylist(newPlaylistField.text)

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                text: "Название"
                color: Kirigami.Theme.disabledTextColor
            }

            Controls.TextField {
                id: newPlaylistField
                Layout.fillWidth: true
                placeholderText: "Например, Дорога"
                onAccepted: newPlaylistDialog.accept()
            }

            Controls.Label {
                Layout.fillWidth: true
                text: "Плейлист будет приватным"
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Controls.Dialog {
        id: deletePlaylistDialog
        title: "Удалить плейлист?"
        modal: true
        width: Math.min(360, root.width - Kirigami.Units.largeSpacing * 2)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Yes | Controls.Dialog.No

        onAccepted: client.deletePlaylist(root.deletePlaylistKind)

        contentItem: Controls.Label {
            text: "«" + root.deletePlaylistTitle + "» будет удалён из Яндекс Музыки."
            wrapMode: Text.WordWrap
        }
    }

    Controls.Dialog {
        id: addToPlaylistDialog
        title: "Добавить в плейлист"
        modal: true
        width: Math.min(380, root.width - Kirigami.Units.largeSpacing * 2)
        height: Math.min(480, root.height - Kirigami.Units.largeSpacing * 2)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close

        onOpened: client.loadPlaylists()

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                Layout.fillWidth: true
                text: (root.actionTrack.title || "Трек")
                    + " · " + (root.actionTrack.artists || []).join(", ")
                font.bold: true
                elide: Text.ElideRight
            }

            ListView {
                id: addPlaylistView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: client.playlists

                delegate: Controls.ItemDelegate {
                    width: addPlaylistView.width
                    text: modelData.title + "  (" + (modelData.trackCount || 0) + ")"
                    onClicked: {
                        client.addTrackToPlaylist(modelData.kind, root.actionTrack);
                        addToPlaylistDialog.close();
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: client.playlists.length === 0
                text: "Плейлистов нет"
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Controls.Dialog {
        id: trackInfoDialog
        title: "Информация о треке"
        modal: true
        width: Math.min(420, root.width - 32)
        height: Math.min(520, root.height - 32)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Rectangle {
                    Layout.preferredWidth: 96
                    Layout.preferredHeight: 96
                    radius: Kirigami.Units.smallSpacing
                    color: Kirigami.Theme.backgroundColor

                    Image {
                        id: infoCover
                        anchors.fill: parent
                        source: root.infoTrack.cover || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        source: "audio-x-generic"
                        width: Kirigami.Units.iconSizes.large
                        height: width
                        visible: !infoCover.visible
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        Layout.fillWidth: true
                        text: root.infoTrack.title || "Без названия"
                        font.bold: true
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                        wrapMode: Text.WordWrap
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        text: (root.infoTrack.artists || []).join(", ") || "Неизвестный исполнитель"
                        color: Kirigami.Theme.disabledTextColor
                        wrapMode: Text.WordWrap
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        text: root.infoTrack.album || "Без альбома"
                        color: Kirigami.Theme.disabledTextColor
                        elide: Text.ElideRight
                    }
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.largeSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: "Длительность"
                    color: Kirigami.Theme.disabledTextColor
                }
                Controls.Label {
                    Layout.fillWidth: true
                    text: root.infoTrack.durationMs ? Format.formatTime(root.infoTrack.durationMs) : "—"
                }

                Controls.Label {
                    text: "ID"
                    color: Kirigami.Theme.disabledTextColor
                }
                Controls.Label {
                    Layout.fillWidth: true
                    text: root.infoTrack.id !== undefined ? String(root.infoTrack.id) : "—"
                    textFormat: Text.PlainText
                }

                Controls.Label {
                    text: "Исполнитель ID"
                    color: Kirigami.Theme.disabledTextColor
                }
                Controls.Label {
                    Layout.fillWidth: true
                    text: root.infoTrack.artistId !== undefined ? String(root.infoTrack.artistId) : "—"
                }

                Controls.Label {
                    text: "Альбом ID"
                    color: Kirigami.Theme.disabledTextColor
                }
                Controls.Label {
                    Layout.fillWidth: true
                    text: root.infoTrack.albumId !== undefined ? String(root.infoTrack.albumId) : "—"
                }

                Controls.Label {
                    text: "Состояние"
                    color: Kirigami.Theme.disabledTextColor
                }
                Controls.Label {
                    Layout.fillWidth: true
                    text: root.infoState(root.infoTrack)
                }

                Controls.Label {
                    text: "Поток"
                    color: Kirigami.Theme.disabledTextColor
                    visible: root.track.id === root.infoTrack.id
                }
                Controls.Label {
                    Layout.fillWidth: true
                    text: Format.streamLabel(root.quality, root.st.codec, root.st.bitrateKbps)
                    visible: root.track.id === root.infoTrack.id
                }
            }
        }
    }

    Controls.Dialog {
        id: cacheDialog
        title: "Офлайн-кэш"
        modal: true
        width: Math.min(440, root.width - Kirigami.Units.largeSpacing * 2)
        height: Math.min(560, root.height - Kirigami.Units.largeSpacing * 2)
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        standardButtons: Controls.Dialog.Close
        property bool loadingCache: false

        onOpened: {
            loadingCache = true;
            client.loadCache();
        }

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true

                Controls.Label {
                    Layout.fillWidth: true
                    text: "Занято " + Format.bytes(client.cacheTotalBytes)
                        + " из " + Format.bytes(client.cacheLimitBytes)
                }

                Controls.Button {
                    text: "Очистить"
                    enabled: client.cacheItems.length > 0
                    onClicked: client.clearCache()
                }
            }

            RowLayout {
                Layout.fillWidth: true

                Controls.Label {
                    text: "Лимит, МБ"
                    color: Kirigami.Theme.disabledTextColor
                }

                Controls.SpinBox {
                    id: cacheLimitSpin
                    from: 0
                    to: 102400
                    stepSize: 256
                    editable: true
                    Layout.fillWidth: true
                }

                Controls.Button {
                    text: "Сохранить"
                    onClicked: client.setCacheLimit(cacheLimitSpin.value)
                }
            }

            Repeater {
                model: root.downloads

                delegate: RowLayout {
                    Layout.fillWidth: true
                    visible: modelData.state === "downloading"
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        Layout.fillWidth: true
                        text: "⤓ " + (modelData.title || modelData.id)
                        elide: Text.ElideRight
                    }

                    Controls.ProgressBar {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                        from: 0
                        to: Math.max(1, modelData.total || 0)
                        value: Math.min(modelData.bytes || 0, modelData.total || 0)
                    }
                }
            }

            ListView {
                id: cacheView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: client.cacheItems

                delegate: Controls.ItemDelegate {
                    width: cacheView.width

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Controls.Label {
                                Layout.fillWidth: true
                                text: modelData.title || modelData.id
                                elide: Text.ElideRight
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                text: (modelData.artists || []).join(", ")
                                color: Kirigami.Theme.disabledTextColor
                                elide: Text.ElideRight
                            }
                        }

                        Controls.Label {
                            text: Format.bytes(modelData.bytes)
                            color: Kirigami.Theme.disabledTextColor
                        }

                        Controls.ToolButton {
                            text: "✕"
                            onClicked: client.removeCached(modelData.id)
                            Controls.ToolTip.text: "Удалить из кэша"
                            Controls.ToolTip.visible: hovered
                        }
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: client.cacheItems.length === 0
                text: cacheDialog.loadingCache ? "Загрузка…" : "Кэш пуст"
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Controls.Dialog {
        id: artistDialog
        title: "Исполнитель"
        modal: true
        width: Math.min(root.width - 32, 560)
        height: Math.min(root.height - 32, 640)
        standardButtons: Controls.Dialog.Close

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Rectangle {
                    Layout.preferredWidth: 72
                    Layout.preferredHeight: 72
                    radius: Kirigami.Units.smallSpacing
                    color: Kirigami.Theme.backgroundColor

                    Image {
                        id: artistCover
                        anchors.fill: parent
                        source: client.artistInfo.cover || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        source: "user-identity"
                        width: Kirigami.Units.iconSizes.large
                        height: width
                        visible: !artistCover.visible
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Controls.Label {
                        Layout.fillWidth: true
                        text: client.artistInfo.name || "Исполнитель"
                        font.bold: true
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                        elide: Text.ElideRight
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        text: client.artistTracks.length + " треков"
                        color: Kirigami.Theme.disabledTextColor
                    }
                }

                Controls.Button {
                    text: "Станция"
                    enabled: client.artistInfo.id !== undefined
                    onClicked: client.startStation("artist:" + String(client.artistInfo.id))
                }
            }

            ListView {
                id: artistTracksView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: client.artistTracks

                delegate: TrackRow {
                    width: artistTracksView.width
                    item: modelData
                    showDownload: true
                    onClicked: client.cmd("play_track", modelData)
                    onPlayRequested: client.cmd("play_track", modelData)
                    onEnqueueRequested: root.enqueueItem(modelData)
                    onDownloadClicked: root.downloadItem(modelData)
                    onLikeRequested: root.likeItem(modelData)
                    onAddToPlaylistRequested: root.openAddToPlaylist(modelData)
                    onCopyLinkRequested: client.copyLink(String(modelData.id))
                    onAlbumRequested: root.openAlbum(modelData)
                    onStationTrackRequested: root.startTrackStation(modelData)
                    onStationArtistRequested: root.startArtistStation(modelData)
                    onInfoRequested: root.openTrackInfo(modelData)
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: client.artistTracks.length === 0
                text: "Загрузка…"
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Controls.Dialog {
        id: albumDialog
        title: "Альбом"
        modal: true
        width: Math.min(root.width - 32, 560)
        height: Math.min(root.height - 32, 640)
        standardButtons: Controls.Dialog.Close

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Rectangle {
                    Layout.preferredWidth: 72
                    Layout.preferredHeight: 72
                    radius: Kirigami.Units.smallSpacing
                    color: Kirigami.Theme.backgroundColor

                    Image {
                        id: albumCover
                        anchors.fill: parent
                        source: client.albumInfo.cover || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    Kirigami.Icon {
                        anchors.centerIn: parent
                        source: "media-optical"
                        width: Kirigami.Units.iconSizes.large
                        height: width
                        visible: !albumCover.visible
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Controls.Label {
                        Layout.fillWidth: true
                        text: client.albumInfo.title || "Альбом"
                        font.bold: true
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
                        elide: Text.ElideRight
                    }

                    Controls.Label {
                        Layout.fillWidth: true
                        text: (client.albumInfo.artists || []).join(", ")
                        color: Kirigami.Theme.disabledTextColor
                        elide: Text.ElideRight
                    }
                }

                Controls.Button {
                    text: "Играть"
                    enabled: client.albumTracks.length > 0
                    onClicked: {
                        client.cmd("queue_set", {
                            "tracks": client.albumTracks,
                            "index": 0,
                            "play": true
                        });
                    }
                }
            }

            ListView {
                id: albumTracksView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: client.albumTracks

                delegate: TrackRow {
                    width: albumTracksView.width
                    item: modelData
                    showIndex: true
                    rowIndex: index
                    showDownload: true
                    onClicked: client.cmd("play_track", modelData)
                    onPlayRequested: client.cmd("play_track", modelData)
                    onEnqueueRequested: root.enqueueItem(modelData)
                    onDownloadClicked: root.downloadItem(modelData)
                    onLikeRequested: root.likeItem(modelData)
                    onAddToPlaylistRequested: root.openAddToPlaylist(modelData)
                    onCopyLinkRequested: client.copyLink(String(modelData.id))
                    onArtistRequested: root.openArtist(modelData)
                    onStationTrackRequested: root.startTrackStation(modelData)
                    onStationArtistRequested: root.startArtistStation(modelData)
                    onInfoRequested: root.openTrackInfo(modelData)
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                visible: client.albumTracks.length === 0
                text: "Загрузка…"
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }
}
