import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import "format.js" as Format

Controls.ItemDelegate {
    id: row
    property var item
    property int rowIndex: -1
    property bool showIndex: false
    property bool current: false

    Layout.fillWidth: true
    text: (showIndex && rowIndex >= 0 ? (rowIndex + 1) + ". " : "") + Format.trackLine(item)
    highlighted: current
}
