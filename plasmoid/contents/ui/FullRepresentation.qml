import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import "format.js" as Format

Item {
    id: popup
    property var applet

    implicitWidth: Kirigami.Units.gridUnit * 24
    implicitHeight: column.implicitHeight + Kirigami.Units.largeSpacing * 2

    Component.onCompleted: applet.loadPlaylists()

    PlasmaComponents3.ScrollView {
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth
        padding: Kirigami.Units.largeSpacing

        ColumnLayout {
            id: column
            width: scroll.availableWidth
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

        PlasmaComponents3.TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Поиск"
            onAccepted: applet.search(text)
        }

        Repeater {
            model: applet.searchResults.slice(0, 4)
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
                onClicked: applet.cmd("queue_set", {
                    tracks: applet.playlistTracks,
                    index: 0,
                    play: true
                })
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
            text: "Очередь"
            font.bold: true
        }

        Repeater {
            model: applet.queueItems.slice(0, 4)
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
}
