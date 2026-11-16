#ifndef YMD_AURORA_BACKEND_H
#define YMD_AURORA_BACKEND_H

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QString>
#include <QTimer>

class QNetworkAccessManager;
class QNetworkReply;
class QMediaPlayer;

class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString trackTitle READ trackTitle NOTIFY trackChanged)
    Q_PROPERTY(QString trackArtist READ trackArtist NOTIFY trackChanged)
    Q_PROPERTY(QString cover READ cover NOTIFY trackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(int volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(int position READ position NOTIFY positionChanged)
    Q_PROPERTY(int duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchResultsChanged)
    Q_PROPERTY(bool authorized READ authorized NOTIFY accountChanged)
    Q_PROPERTY(QString accountLogin READ accountLogin NOTIFY accountChanged)
    Q_PROPERTY(QString authCode READ authCode NOTIFY authChanged)
    Q_PROPERTY(QString authUrl READ authUrl NOTIFY authChanged)
    Q_PROPERTY(QString authStatus READ authStatus NOTIFY authChanged)

public:
    explicit Backend(const QString &dataDir, QObject *parent = 0);

    QString status() const { return m_status; }
    QString trackTitle() const { return m_trackTitle; }
    QString trackArtist() const { return m_trackArtist; }
    QString cover() const { return m_cover; }
    bool playing() const;
    int volume() const;
    int position() const;
    int duration() const;
    QVariantList searchResults() const { return m_searchResults; }
    bool authorized() const { return m_authorized; }
    QString accountLogin() const { return m_accountLogin; }
    QString authCode() const { return m_authCode; }
    QString authUrl() const { return m_authUrl; }
    QString authStatus() const { return m_authStatus; }

    Q_INVOKABLE void search(const QString &text);
    Q_INVOKABLE void playTrack(const QVariantMap &track);
    Q_INVOKABLE void toggle();
    Q_INVOKABLE void next();
    Q_INVOKABLE void prev();
    Q_INVOKABLE void seek(int ms);
    Q_INVOKABLE void setVolume(int value);
    Q_INVOKABLE void startAuth();
    Q_INVOKABLE void pollAuth();
    Q_INVOKABLE void logout();

signals:
    void statusChanged();
    void trackChanged();
    void playingChanged();
    void volumeChanged();
    void positionChanged();
    void durationChanged();
    void searchResultsChanged();
    void accountChanged();
    void authChanged();

private:
    void setStatus(const QString &status);
    void setTrack(const QVariantMap &track);
    void setToken(const QString &token, bool save);
    void loadToken();
    void fetchAccount();
    void playIndex(int index);
    void requestStream(const QString &trackId);
    void handleSearch(QNetworkReply *reply);
    void handleStream(QNetworkReply *reply, const QString &trackId);
    void handleAccount(QNetworkReply *reply);
    void handleDeviceCode(QNetworkReply *reply);
    void handleTokenPoll(QNetworkReply *reply);
    QNetworkReply *apiGet(const QString &path);
    QNetworkReply *apiPost(const QString &url, const QByteArray &body,
                           const QString &contentType);

    QString m_dataDir;
    QString m_status;
    QString m_trackTitle;
    QString m_trackArtist;
    QString m_cover;
    QString m_token;
    QString m_uid;
    QString m_accountLogin;
    QString m_authCode;
    QString m_authUrl;
    QString m_authStatus;
    QString m_deviceCode;
    QString m_pendingTrackId;
    QVariantList m_searchResults;
    QVariantList m_queue;
    int m_index;
    int m_volume;
    int m_authInterval;
    bool m_authorized;
    QTimer m_authTimer;
    QNetworkAccessManager *m_nam;
    QMediaPlayer *m_player;
};

#endif // YMD_AURORA_BACKEND_H
