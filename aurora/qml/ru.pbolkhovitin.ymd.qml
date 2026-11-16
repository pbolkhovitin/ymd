import QtQuick 2.0
import Sailfish.Silica 1.0

ApplicationWindow {
    id: app
    readonly property var backend: backendCpp

    initialPage: Page {
        id: page

        PageHeader {
            title: "ymd"
        }

        Column {
            anchors {
                left: parent.left
                right: parent.right
                top: page.header.bottom
                margins: Theme.horizontalPageMargin
            }
            spacing: Theme.paddingLarge

            Label {
                width: parent.width
                text: app.backend.trackTitle
                font.pixelSize: Theme.fontSizeLarge
                wrapMode: Text.Wrap
            }

            Label {
                width: parent.width
                text: app.backend.trackArtist
                color: Theme.secondaryColor
                wrapMode: Text.Wrap
            }

            Label {
                width: parent.width
                text: app.backend.status
                color: Theme.highlightColor
                wrapMode: Text.Wrap
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.paddingLarge

                IconButton {
                    icon.source: "image://theme/icon-m-previous"
                    onClicked: app.backend.prev()
                }

                IconButton {
                    icon.source: app.backend.playing
                        ? "image://theme/icon-m-pause"
                        : "image://theme/icon-m-play"
                    onClicked: app.backend.toggle()
                }

                IconButton {
                    icon.source: "image://theme/icon-m-next"
                    onClicked: app.backend.next()
                }
            }

            TextField {
                id: searchField
                width: parent.width
                placeholderText: "Поиск"
                onAccepted: app.backend.search(text)
            }

            Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Найти"
                onClicked: app.backend.search(searchField.text)
            }
        }
    }
}
