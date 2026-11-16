import QtQuick 2.0
import Sailfish.Silica 1.0

ApplicationWindow {
    id: app
    readonly property var backend: backendCpp

    initialPage: Component {
        Page {
            id: page
            allowedOrientations: Orientation.All

            SilicaListView {
                id: list
                anchors.fill: parent
                model: backend.searchResults
                clip: true

                header: Column {
                    id: header
                    width: list.width
                    spacing: Theme.paddingMedium

                    PageHeader {
                        title: "ymd"
                    }

                    Row {
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        x: Theme.horizontalPageMargin
                        spacing: Theme.paddingMedium

                        Image {
                            id: cover
                            width: Theme.itemSizeLarge
                            height: Theme.itemSizeLarge
                            source: backend.cover.length > 0
                                ? backend.cover
                                : "image://theme/icon-m-music"
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }

                        Column {
                            width: parent.width - cover.width - Theme.paddingMedium
                            spacing: Theme.paddingSmall

                            Label {
                                width: parent.width
                                text: backend.trackTitle
                                font.pixelSize: Theme.fontSizeLarge
                                truncationMode: TruncationMode.Elide
                            }

                            Label {
                                width: parent.width
                                text: backend.trackArtist
                                color: Theme.secondaryColor
                                truncationMode: TruncationMode.Elide
                            }

                            Label {
                                width: parent.width
                                text: backend.status
                                color: Theme.secondaryColor
                                font.pixelSize: Theme.fontSizeSmall
                                truncationMode: TruncationMode.Elide
                            }
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.paddingLarge

                        IconButton {
                            icon.source: "image://theme/icon-m-previous"
                            enabled: backend.authorized
                            onClicked: backend.prev()
                        }

                        IconButton {
                            icon.source: backend.playing
                                ? "image://theme/icon-m-pause"
                                : "image://theme/icon-m-play"
                            enabled: backend.authorized
                            onClicked: backend.toggle()
                        }

                        IconButton {
                            icon.source: "image://theme/icon-m-next"
                            enabled: backend.authorized
                            onClicked: backend.next()
                        }
                    }

                    Slider {
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        x: Theme.horizontalPageMargin
                        label: "Громкость"
                        minimumValue: 0
                        maximumValue: 100
                        stepSize: 1
                        value: backend.volume
                        valueText: Math.round(value) + "%"
                        onValueChanged: backend.setVolume(Math.round(value))
                    }

                    Column {
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        x: Theme.horizontalPageMargin
                        spacing: Theme.paddingMedium
                        visible: !backend.authorized

                        Label {
                            width: parent.width
                            text: backend.authStatus
                            color: Theme.secondaryColor
                            wrapMode: Text.WordWrap
                        }

                        Button {
                            text: "Войти в Яндекс Музыку"
                            onClicked: backend.startAuth()
                        }

                        Label {
                            width: parent.width
                            visible: backend.authCode.length > 0
                            text: "Код: " + backend.authCode
                            font.pixelSize: Theme.fontSizeLarge
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Label {
                            width: parent.width
                            visible: backend.authUrl.length > 0
                            text: backend.authUrl
                            color: Theme.highlightColor
                            wrapMode: Text.WrapAnywhere
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Button {
                            text: "Проверить"
                            visible: backend.authCode.length > 0
                            onClicked: backend.pollAuth()
                        }
                    }

                    TextField {
                        id: searchField
                        width: parent.width - 2 * Theme.horizontalPageMargin
                        x: Theme.horizontalPageMargin
                        placeholderText: "Поиск в Яндекс Музыке"
                        enabled: backend.authorized
                        onAccepted: backend.search(text)
                    }

                    Button {
                        text: "Найти"
                        enabled: backend.authorized && searchField.text.length > 0
                        onClicked: backend.search(searchField.text)
                    }

                    Label {
                        width: parent.width
                        text: backend.searchResults.length > 0
                            ? "Результаты"
                            : "Введите запрос и нажмите «Найти»"
                        color: Theme.secondaryColor
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                delegate: ListItem {
                    id: trackItem
                    contentHeight: Theme.itemSizeMedium

                    Column {
                        anchors {
                            left: parent.left
                            right: parent.right
                            leftMargin: Theme.horizontalPageMargin
                            rightMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: Theme.paddingSmall

                        Label {
                            width: parent.width
                            text: modelData.title
                            truncationMode: TruncationMode.Elide
                        }

                        Label {
                            width: parent.width
                            text: modelData.artist
                            color: Theme.secondaryColor
                            font.pixelSize: Theme.fontSizeSmall
                            truncationMode: TruncationMode.Elide
                        }
                    }

                    onClicked: backend.playTrack(modelData)
                }
            }
        }
    }
}
