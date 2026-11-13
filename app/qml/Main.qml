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
        + " · " + Format.qualityLabel(quality)

    function send(op) {
        client.cmd(op, {});
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
                    onClicked: root.send("like")
                    Controls.ToolTip.text: "Нравится"
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
                    onClicked: client.cmd("play_track", client.searchResults[index])
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
                    onClicked: client.cmd("queue_play", { "index": index })
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
}
