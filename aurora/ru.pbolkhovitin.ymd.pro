TARGET = ru.pbolkhovitin.ymd
CONFIG += auroraapp auroraapp_i18n c++11 link_pkgconfig
QT += network qml quick multimedia

PKGCONFIG += auroraapp

QMAKE_CXXFLAGS += -fPIC

SOURCES += \
    src/main.cpp \
    src/backend.cpp

HEADERS += \
    src/backend.h

DISTFILES += \
    qml/ru.pbolkhovitin.ymd.qml \
    ru.pbolkhovitin.ymd.desktop \
    rpm/ru.pbolkhovitin.ymd.spec

qml.files = qml
qml.path = /usr/share/$$TARGET
INSTALLS += qml

desktop.files = ru.pbolkhovitin.ymd.desktop
desktop.path = /usr/share/applications
INSTALLS += desktop

icons86.files = icons/86x86/ru.pbolkhovitin.ymd.png
icons86.path = /usr/share/icons/hicolor/86x86/apps
INSTALLS += icons86

icons108.files = icons/108x108/ru.pbolkhovitin.ymd.png
icons108.path = /usr/share/icons/hicolor/108x108/apps
INSTALLS += icons108

icons128.files = icons/128x128/ru.pbolkhovitin.ymd.png
icons128.path = /usr/share/icons/hicolor/128x128/apps
INSTALLS += icons128

icons172.files = icons/172x172/ru.pbolkhovitin.ymd.png
icons172.path = /usr/share/icons/hicolor/172x172/apps
INSTALLS += icons172
