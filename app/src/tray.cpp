#include "tray.h"

#include <QAction>
#include <QIcon>
#include <KStatusNotifierItem>
#include <QMenu>
#include <QWindow>

Tray::Tray(QObject *parent)
    : QObject(parent)
{
    m_item = new KStatusNotifierItem(QStringLiteral("io.github.pbolkhovitin.ymdqt"), this);
    m_item->setCategory(KStatusNotifierItem::ApplicationStatus);
    m_item->setStatus(KStatusNotifierItem::Active);
    m_item->setIconByName(QStringLiteral("audio-x-generic"));
    m_item->setStandardActionsEnabled(false);
    m_item->setToolTip(QStringLiteral("Yandex Music"), QString(), QStringLiteral("audio-x-generic"));

    m_menu = new QMenu();
    QAction *show = m_menu->addAction(QIcon::fromTheme(QStringLiteral("window-new")),
                                      QStringLiteral("Показать окно"));
    connect(show, &QAction::triggered, this, &Tray::showWindow);

    m_menu->addSeparator();

    m_playPause = m_menu->addAction(QIcon::fromTheme(QStringLiteral("media-playback-start")),
                                    QStringLiteral("Играть"));
    connect(m_playPause, &QAction::triggered, this, &Tray::togglePlayback);

    QAction *nextAction = m_menu->addAction(QIcon::fromTheme(QStringLiteral("media-skip-forward")),
                                            QStringLiteral("Следующий"));
    connect(nextAction, &QAction::triggered, this, &Tray::next);

    QAction *prevAction = m_menu->addAction(QIcon::fromTheme(QStringLiteral("media-skip-backward")),
                                            QStringLiteral("Предыдущий"));
    connect(prevAction, &QAction::triggered, this, &Tray::previous);

    m_menu->addSeparator();

    QAction *quitAction = m_menu->addAction(QIcon::fromTheme(QStringLiteral("application-exit")),
                                            QStringLiteral("Выход"));
    connect(quitAction, &QAction::triggered, this, &Tray::quit);

    m_item->setContextMenu(m_menu);
    connect(m_item, &KStatusNotifierItem::activateRequested, this, [this](bool, const QPoint &) {
        emit toggleWindow();
    });
    connect(m_item, &KStatusNotifierItem::secondaryActivateRequested, this,
            [this](const QPoint &) { emit togglePlayback(); });
}

void Tray::setWindow(QWindow *window)
{
    m_window = window;
    if (!m_menu || !m_window) {
        return;
    }

    // On Wayland a popup needs a transient parent; the DBusMenu path is not
    // available in every KStatusNotifierItem build, so keep this best-effort.
    m_menu->winId();
    if (m_menu->windowHandle()) {
        m_menu->windowHandle()->setTransientParent(m_window);
    }
}

Tray::~Tray()
{
    // KStatusNotifierItem owns the menu set with setContextMenu().
    delete m_item;
    m_item = nullptr;
    m_menu = nullptr;
}

void Tray::setState(const QVariantMap &state)
{
    const QVariantMap track = state.value(QStringLiteral("track")).toMap();
    const QString title = track.value(QStringLiteral("title")).toString();
    const QVariantList artists = track.value(QStringLiteral("artists")).toList();
    const QString artist = artists.isEmpty() ? QString() : artists.constFirst().toString();
    const QString status = state.value(QStringLiteral("status")).toString();

    if (m_playPause) {
        m_playPause->setText(status == QLatin1String("playing")
                                 ? QStringLiteral("Пауза")
                                 : QStringLiteral("Играть"));
        m_playPause->setIcon(QIcon::fromTheme(
            status == QLatin1String("playing")
                ? QStringLiteral("media-playback-pause")
                : QStringLiteral("media-playback-start")));
    }

    if (m_item) {
        m_item->setToolTip(title.isEmpty() ? QStringLiteral("Yandex Music") : title,
                           artist, QStringLiteral("audio-x-generic"));
    }
}
