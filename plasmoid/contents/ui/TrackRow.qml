import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "format.js" as Format

PlasmaComponents3.ItemDelegate {
    id: row
    property var item
    property int rowIndex: -1
    property bool showIndex: false
    property bool current: false

    text: (showIndex ? (rowIndex + 1) + ". " : "") + Format.trackLine(item)
    highlighted: current
    Layout.fillWidth: true
}
