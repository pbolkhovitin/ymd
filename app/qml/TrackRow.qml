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
    signal downloadClicked()

    Layout.fillWidth: true
    highlighted: current

    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing

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
    }
}
