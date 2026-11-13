import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: page
    property alias cfg_daemonPort: portField.value
    implicitWidth: Kirigami.Units.gridUnit * 20
    implicitHeight: Kirigami.Units.gridUnit * 6

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing

        QQC2.Label { text: i18n("Daemon port") }
        QQC2.SpinBox {
            id: portField
            from: 1
            to: 65535
            Layout.fillWidth: true
        }
        Item { Layout.fillHeight: true }
    }
}
