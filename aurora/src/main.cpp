#include <auroraapp.h>

#include <QDir>
#include <QGuiApplication>
#include <QQmlContext>
#include <QQuickView>
#include <QScopedPointer>
#include <QUrl>

#include "backend.h"

int main(int argc, char *argv[])
{
    QScopedPointer<QGuiApplication> app(Aurora::Application::application(argc, argv));
    if (!app) {
        return 2;
    }

    app->setOrganizationName(QStringLiteral("ru.pbolkhovitin"));
    app->setApplicationName(QStringLiteral("ymd"));
    app->setApplicationDisplayName(QStringLiteral("ymd"));
    app->setApplicationVersion(QStringLiteral("0.2.1"));

    QString dataDir = Aurora::Application::filesDir(false).absolutePath();
    QDir().mkpath(dataDir);

    QScopedPointer<QQuickView> view(Aurora::Application::createView());
    if (!view) {
        return 2;
    }

    Backend *backend = new Backend(dataDir, view.data());
    view->rootContext()->setContextProperty(QStringLiteral("backendCpp"), backend);

    view->setSource(Aurora::Application::pathTo(
        QStringLiteral("qml/ru.pbolkhovitin.ymd.qml")));
    if (view->status() == QQuickView::Error) {
        return 2;
    }

    view->showFullScreen();
    return app->exec();
}
