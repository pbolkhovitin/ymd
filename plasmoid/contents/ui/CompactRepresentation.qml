import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "format.js" as Format

Item {
    id: compact
    property var applet

    implicitWidth: row.implicitWidth + Kirigami.Units.smallSpacing * 2
    implicitHeight: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: "audio-x-generic"
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium
            color: Kirigami.Theme.textColor
        }

        PlasmaComponents3.Label {
            visible: Plasmoid.formFactor !== PlasmaCore.Types.Vertical
            text: applet.title
                ? Format.truncate(applet.title + (applet.artistLine ? " — " + applet.artistLine : ""), 34)
                : (applet.keyReady ? "" : "ymd")
            color: Kirigami.Theme.textColor
            elide: Text.ElideRight
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) {
                Plasmoid.expanded = !Plasmoid.expanded;
            } else if (mouse.button === Qt.MiddleButton) {
                applet.cmd("toggle");
            }
        }
        onWheel: function(wheel) {
            if (wheel.angleDelta.y !== 0) {
                applet.cmd(wheel.angleDelta.y > 0 ? "prev" : "next");
            }
        }
    }
}
