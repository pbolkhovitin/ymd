#pragma once

#include <functional>

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QObject>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class QNetworkReply;

/// Тонкий клиент локального HTTP API демона `ymd`.
///
/// Приложение не знает про Яндекс Музыку: только ключ, `/v1/state`,
/// `/v1/search` и `/v1/cmd`. Ключ читается из runtime-каталога, резервный
/// путь — `ymd session-key`.
class YmdClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
    Q_PROPERTY(bool keyReady READ keyReady NOTIFY keyChanged)
    Q_PROPERTY(bool authFailed READ authFailed NOTIFY authChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY errorChanged)
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchResultsChanged)
    Q_PROPERTY(bool searching READ searching NOTIFY searchingChanged)
    Q_PROPERTY(QVariantList playlists READ playlists NOTIFY playlistsChanged)
    Q_PROPERTY(QVariantList playlistTracks READ playlistTracks NOTIFY playlistTracksChanged)
    Q_PROPERTY(QString playlistTitle READ playlistTitle NOTIFY playlistTracksChanged)
    Q_PROPERTY(QVariantList cacheItems READ cacheItems NOTIFY cacheChanged)
    Q_PROPERTY(qint64 cacheTotalBytes READ cacheTotalBytes NOTIFY cacheChanged)
    Q_PROPERTY(qint64 cacheLimitBytes READ cacheLimitBytes NOTIFY cacheChanged)

public:
    explicit YmdClient(QObject *parent = nullptr);
    YmdClient(const QUrl &baseUrl, const QString &keyPath,
              const QString &keyCommand, QObject *parent = nullptr);

    QVariantMap state() const;
    bool keyReady() const;
    bool authFailed() const;
    QString lastError() const;
    QVariantList searchResults() const;
    bool searching() const;
    QVariantList playlists() const;
    QVariantList playlistTracks() const;
    QString playlistTitle() const;
    QVariantList cacheItems() const;
    qint64 cacheTotalBytes() const;
    qint64 cacheLimitBytes() const;

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void cmd(const QString &op);
    Q_INVOKABLE void cmd(const QString &op, const QVariantMap &payload);
    Q_INVOKABLE void search(const QString &text);
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void retryKey();
    Q_INVOKABLE void loadPlaylists();
    Q_INVOKABLE void loadPlaylist(qint64 uid, qint64 kind);
    Q_INVOKABLE void loadCache();
    Q_INVOKABLE void download(const QVariantMap &item);
    Q_INVOKABLE void removeCached(const QString &id);
    Q_INVOKABLE void clearCache();
    Q_INVOKABLE void setCacheLimit(qint64 limitMb);

signals:
    void stateChanged();
    void searchResultsChanged();
    void searchingChanged();
    void playlistsChanged();
    void playlistTracksChanged();
    void cacheChanged();
    void keyChanged();
    void authChanged();
    void errorChanged();

private:
    void readKey();
    void scheduleKeyRetry();
    void handleStateReply(QNetworkReply *reply);
    void sendSearch(const QString &text, bool retried);
    void getJson(const QString &path,
                 const std::function<void(const QJsonObject &)> &handler,
                 bool retried = false);
    void sendCmd(const QString &op, const QVariantMap &payload,
                 const std::function<void()> &onSuccess);
    void updatePolling();
    void setAuthFailed(bool value);
    void setError(const QString &error);
    void setSearching(bool value);
    QNetworkRequest makeRequest(const QString &path) const;
    QString errorText(QNetworkReply *reply) const;

    QUrl m_baseUrl{QStringLiteral("http://127.0.0.1:8765")};
    QString m_keyPath;
    QString m_keyCommand{QStringLiteral("ymd")};
    QString m_key;
    QVariantMap m_state;
    QVariantList m_searchResults;
    QVariantList m_playlists;
    QVariantList m_playlistTracks;
    QString m_playlistTitle;
    QVariantList m_cacheItems;
    qint64 m_cacheTotalBytes = 0;
    qint64 m_cacheLimitBytes = 0;
    QString m_lastError;
    bool m_keyReady = false;
    bool m_authFailed = false;
    bool m_searching = false;
    bool m_authRetried = false;

    QNetworkAccessManager m_nam{this};
    QTimer m_pollTimer;
    QTimer m_keyRetryTimer;
};
