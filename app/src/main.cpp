#include "tray.h"
#include "ymdclient.h"

#include <QApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QUrl>

int main(int argc, char *argv[])
{
    // Kirigami takes the KDE color scheme from the platform theme.
    if (qEnvironmentVariableIsEmpty("XDG_CURRENT_DESKTOP")) {
        qputenv("XDG_CURRENT_DESKTOP", QByteArrayLiteral("KDE"));
    }

    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("ymd-qt"));
    QApplication::setApplicationDisplayName(QStringLiteral("ymd"));
    QApplication::setOrganizationName(QStringLiteral("pbolkhovitin"));
    QApplication::setDesktopFileName(QStringLiteral("io.github.pbolkhovitin.ymdqt"));
    QApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("ymd-qt"), QIcon::fromTheme(QStringLiteral("audio-x-generic"))));
    QApplication::setQuitOnLastWindowClosed(false);

    YmdClient client;
    Tray tray;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("client"), &client);
    engine.rootContext()->setContextProperty(QStringLiteral("tray"), &tray);
    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/YmdQt/qml/Main.qml")));

    if (engine.rootObjects().isEmpty()) {
        return 1;
    }

    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!window) {
        return 1;
    }

    tray.setWindow(window);

    QObject::connect(&tray, &Tray::showWindow, window, [window]() {
        window->show();
        window->raise();
        window->requestActivate();
    });
    QObject::connect(&tray, &Tray::toggleWindow, window, [window]() {
        if (window->isVisible()) {
            window->hide();
        } else {
            window->show();
            window->raise();
            window->requestActivate();
        }
    });
    QObject::connect(&tray, &Tray::togglePlayback, &client, [&client]() {
        client.cmd(QStringLiteral("toggle"));
    });
    QObject::connect(&tray, &Tray::next, &client, [&client]() {
        client.cmd(QStringLiteral("next"));
    });
    QObject::connect(&tray, &Tray::previous, &client, [&client]() {
        client.cmd(QStringLiteral("prev"));
    });
    QObject::connect(&tray, &Tray::quit, &app, &QCoreApplication::quit);
    QObject::connect(&client, &YmdClient::stateChanged, &tray, [&client, &tray]() {
        tray.setState(client.state());
    });

    tray.setState(client.state());
    return app.exec();
}
