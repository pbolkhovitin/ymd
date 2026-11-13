import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "format.js" as Format

Controls.ItemDelegate {
    id: row
    property var item
    property int rowIndex: -1
    property bool showIndex: false
    property bool current: false
    property bool showDownload: false
    property bool reorderable: false
    property bool showRemoveFromPlaylist: false
    property bool showRemoveFromQueue: false
    property bool showEnqueue: true
    property bool dragActive: false

    signal downloadClicked()
    signal playRequested()
    signal enqueueRequested()
    signal likeRequested()
    signal addToPlaylistRequested()
    signal copyLinkRequested()
    signal removeFromPlaylistRequested()
    signal removeFromQueueRequested()
    signal moveRequested(int from, int to)

    Layout.fillWidth: true
    highlighted: current

    Drag.active: dragActive
    Drag.source: row
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing

        Controls.ToolButton {
            visible: row.reorderable
            text: "⠿"
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
            opacity: 0.45
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium
            Controls.ToolTip.text: "Перетащить"
            Controls.ToolTip.visible: hovered

            DragHandler {
                id: handleDrag
                target: null
                onActiveChanged: row.dragActive = active
            }
        }

        Controls.Label {
            Layout.fillWidth: true
            text: (row.showIndex && row.rowIndex >= 0 ? (row.rowIndex + 1) + ". " : "")
                + Format.trackLine(row.item)
            elide: Text.ElideRight
            color: row.highlighted ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
        }

        Controls.ToolButton {
            visible: row.showDownload
            text: row.item && row.item.cached ? "✓" : "⤓"
            opacity: row.item && row.item.cached ? 0.6 : 1
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium
            onClicked: row.downloadClicked()
            Controls.ToolTip.text: row.item && row.item.cached ? "Уже в кэше" : "Скачать для офлайна"
            Controls.ToolTip.visible: hovered
        }

        Controls.ToolButton {
            text: "⋮"
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium
            onClicked: menu.popup()
            Controls.ToolTip.text: "Действия"
            Controls.ToolTip.visible: hovered
        }
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: menu.popup()
    }

    DropArea {
        anchors.fill: parent
        onDropped: function(drag) {
            if (drag.source && drag.source !== row && drag.source.rowIndex !== undefined) {
                row.moveRequested(drag.source.rowIndex, row.rowIndex);
            }
        }
    }

    Controls.Menu {
        id: menu

        Controls.MenuItem {
            text: "Играть"
            onTriggered: row.playRequested()
        }

        Controls.MenuItem {
            text: "В очередь"
            visible: row.showEnqueue
            onTriggered: row.enqueueRequested()
        }

        Controls.MenuItem {
            text: row.item && row.item.cached ? "Уже в кэше" : "Скачать"
            visible: row.showDownload && !(row.item && row.item.cached)
            onTriggered: row.downloadClicked()
        }

        Controls.MenuSeparator {}

        Controls.MenuItem {
            text: row.item && row.item.liked ? "Убрать из любимых" : "В любимые"
            enabled: row.item && row.item.id !== undefined
            onTriggered: row.likeRequested()
        }

        Controls.MenuItem {
            text: "Добавить в плейлист…"
            enabled: row.item && row.item.id !== undefined
            onTriggered: row.addToPlaylistRequested()
        }

        Controls.MenuItem {
            text: "Копировать ссылку"
            enabled: row.item && row.item.id !== undefined
            onTriggered: row.copyLinkRequested()
        }

        Controls.MenuSeparator {
            visible: row.showRemoveFromPlaylist || row.showRemoveFromQueue
        }

        Controls.MenuItem {
            text: "Удалить из плейлиста"
            visible: row.showRemoveFromPlaylist
            onTriggered: row.removeFromPlaylistRequested()
        }

        Controls.MenuItem {
            text: "Убрать из очереди"
            visible: row.showRemoveFromQueue
            onTriggered: row.removeFromQueueRequested()
        }
    }
}
