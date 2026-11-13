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
    title: "Yandex Music"
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

    Controls.ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

        ColumnLayout {
            x: Kirigami.Units.largeSpacing
            width: scroll.availableWidth - Kirigami.Units.largeSpacing * 2
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true

                Kirigami.Heading {
                    text: "Yandex Music"
                    level: 2
                    Layout.fillWidth: true
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
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    text: "Громкость"
                    color: Kirigami.Theme.disabledTextColor
                }

                Controls.Slider {
                    id: volumeSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    value: root.volume
                    onPressedChanged: {
                        if (!pressed) {
                            client.cmd("volume", { "value": value });
                        }
                    }
                }

                Controls.Label {
                    text: Math.round(volumeSlider.value * 100) + "%"
                    color: Kirigami.Theme.disabledTextColor
                    horizontalAlignment: Text.AlignRight
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                }
            }

            Binding {
                target: volumeSlider
                property: "value"
                value: root.volume
                when: !volumeSlider.pressed
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Kirigami.Units.largeSpacing

                Controls.ToolButton {
                    text: "⏮"
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 4
                    onClicked: root.send("prev")
                    Controls.ToolTip.text: "Предыдущий"
                    Controls.ToolTip.visible: hovered
                }

                Controls.ToolButton {
                    text: root.playing ? "⏸" : "▶"
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 6
                    onClicked: root.send("toggle")
                    Controls.ToolTip.text: root.playing ? "Пауза" : "Играть"
                    Controls.ToolTip.visible: hovered
                }

                Controls.ToolButton {
                    text: "⏭"
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 4
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

                Controls.Button {
                    text: "Волна"
                    onClicked: root.send("wave_start")
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Kirigami.Units.largeSpacing

                Controls.Button {
                    text: "Повтор: " + root.repeatLabel
                    onClicked: client.cmd("repeat", { "value": Format.repeatNext(root.repeatMode) })
                }

                Controls.Button {
                    text: "Перемешать: " + (root.shuffle ? "вкл" : "выкл")
                    onClicked: client.cmd("shuffle", { "value": !root.shuffle })
                }

                Controls.Button {
                    text: "Качество: " + Format.qualityLabel(root.quality)
                    onClicked: client.cmd("quality", { "value": Format.qualityNext(root.quality) })
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Kirigami.Units.largeSpacing

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
                }
            }

            Controls.Label {
                text: "Очередь"
                font.bold: true
                visible: root.queueItems.length > 0
            }

            Repeater {
                model: Math.min(8, root.queueItems.length)

                delegate: TrackRow {
                    Layout.fillWidth: true
                    item: root.queueItems[index]
                    rowIndex: index
                    showIndex: true
                    current: index === root.queueIndex
                    showDownload: true
                    reorderable: true
                    showRemoveFromQueue: true
                    showEnqueue: false
                    onClicked: client.cmd("queue_play", { "index": index })
                    onDownloadClicked: root.downloadItem(root.queueItems[index])
                    onPlayRequested: client.cmd("queue_play", { "index": index })
                    onLikeRequested: root.likeItem(root.queueItems[index])
                    onAddToPlaylistRequested: root.openAddToPlaylist(root.queueItems[index])
                    onCopyLinkRequested: client.copyLink(String(root.queueItems[index].id))
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

        onOpened: {
            showingTracks = false;
            loadingTracks = false;
            loadingPlaylists = true;
            root.playlistFilter = "";
            playlistSearchField.text = "";
            client.loadPlaylists();
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
}
