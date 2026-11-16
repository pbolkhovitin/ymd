#ifndef BACKEND_H
#define BACKEND_H

#include <QObject>
#include <QString>

// C++ backend for the Aurora OS client. It will own the Yandex API client,
// authentication, queue and QtMultimedia playback; for now it exposes the
// minimal state needed by the buildable Silica skeleton.
class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString trackTitle READ trackTitle NOTIFY trackChanged)
    Q_PROPERTY(QString trackArtist READ trackArtist NOTIFY trackChanged)
    Q_PROPERTY(QString cover READ cover NOTIFY trackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)

public:
    explicit Backend(const QString &dataDir, QObject *parent = nullptr);

    QString status() const { return m_status; }
    QString trackTitle() const { return m_trackTitle; }
    QString trackArtist() const { return m_trackArtist; }
    QString cover() const { return m_cover; }
    bool playing() const { return m_playing; }

    Q_INVOKABLE void toggle();
    Q_INVOKABLE void next();
    Q_INVOKABLE void prev();
    Q_INVOKABLE void search(const QString &text);

signals:
    void statusChanged();
    void trackChanged();
    void playingChanged();

private:
    QString m_dataDir;
    QString m_status = QStringLiteral("Готово");
    QString m_trackTitle = QStringLiteral("Ничего не играет");
    QString m_trackArtist;
    QString m_cover;
    bool m_playing = false;
};

#endif // BACKEND_H
