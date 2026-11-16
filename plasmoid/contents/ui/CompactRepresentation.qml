import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

Item {
    id: compact
    property var applet

    implicitWidth: 28
    implicitHeight: 28
    Layout.preferredWidth: implicitWidth
    Layout.preferredHeight: implicitHeight

    Kirigami.Icon {
        anchors.centerIn: parent
        width: Kirigami.Units.iconSizes.smallMedium
        height: Kirigami.Units.iconSizes.smallMedium
        source: "audio-x-generic"
        isMask: true
        color: Kirigami.Theme.textColor
        active: mouse.containsMouse
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        onClicked: function(event) {
            if (event.button === Qt.LeftButton) {
                Plasmoid.expanded = !Plasmoid.expanded;
            } else {
                applet.cmd("toggle");
            }
        }

        onWheel: function(event) {
            if (event.angleDelta.y !== 0) {
                applet.cmd(event.angleDelta.y > 0 ? "prev" : "next");
                event.accepted = true;
            }
        }
    }
}
