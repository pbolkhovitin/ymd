cmake_minimum_required(VERSION 3.22)

project(ymd-qt VERSION 0.4.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Network Qml Quick QuickControls2 Widgets Test)
find_package(KF6Kirigami REQUIRED)
find_package(KF6StatusNotifierItem REQUIRED)

qt_standard_project_setup()
qt_policy(SET QTP0001 NEW)

qt_add_executable(ymd-qt
    src/main.cpp
    src/ymdclient.cpp
    src/tray.cpp
)

qt_add_qml_module(ymd-qt
    URI YmdQt
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/TransportButton.qml
        qml/TrackRow.qml
    RESOURCES
        qml/format.js
)

target_include_directories(ymd-qt PRIVATE src)
target_compile_definitions(ymd-qt PRIVATE YMD_QT_VERSION="${PROJECT_VERSION}")
target_link_libraries(ymd-qt PRIVATE
    Qt6::Core
    Qt6::Network
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Widgets
    KF6::Kirigami
    KF6::StatusNotifierItem
)

install(TARGETS ymd-qt RUNTIME DESTINATION bin)
install(FILES ymd-qt.desktop DESTINATION share/applications)
install(FILES icons/ymd-qt.svg DESTINATION share/icons/hicolor/scalable/apps)

enable_testing()

qt_add_executable(test_ymdclient
    tests/test_ymdclient.cpp
    src/ymdclient.cpp
)
target_include_directories(test_ymdclient PRIVATE src)
target_link_libraries(test_ymdclient PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Network
    Qt6::Test
)
add_test(NAME test_ymdclient COMMAND test_ymdclient)
