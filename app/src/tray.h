#pragma once

#include <QObject>
#include <QVariantMap>

class KStatusNotifierItem;
class QAction;
class QMenu;
class QWindow;

/// Иконка в системном трее и меню управления демоном.
class Tray : public QObject
{
    Q_OBJECT

public:
    explicit Tray(QObject *parent = nullptr);
    ~Tray() override;

    void setState(const QVariantMap &state);
    void setWindow(QWindow *window);

signals:
    void showWindow();
    void toggleWindow();
    void togglePlayback();
    void next();
    void previous();
    void quit();

private:
    KStatusNotifierItem *m_item = nullptr;
    QMenu *m_menu = nullptr;
    QAction *m_playPause = nullptr;
    QWindow *m_window = nullptr;
};
