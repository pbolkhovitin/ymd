#pragma once

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

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void cmd(const QString &op);
    Q_INVOKABLE void cmd(const QString &op, const QVariantMap &payload);
    Q_INVOKABLE void search(const QString &text);
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void retryKey();

signals:
    void stateChanged();
    void searchResultsChanged();
    void searchingChanged();
    void keyChanged();
    void authChanged();
    void errorChanged();

private:
    void readKey();
    void scheduleKeyRetry();
    void handleStateReply(QNetworkReply *reply);
    void sendSearch(const QString &text, bool retried);
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
    QString m_lastError;
    bool m_keyReady = false;
    bool m_authFailed = false;
    bool m_searching = false;
    bool m_authRetried = false;

    QNetworkAccessManager m_nam{this};
    QTimer m_pollTimer;
    QTimer m_keyRetryTimer;
};
