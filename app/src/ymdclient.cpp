#include "ymdclient.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QProcess>
#include <QStandardPaths>
#include <QUrlQuery>

namespace {
constexpr int kPollPlayingMs = 1000;
constexpr int kPollIdleMs = 3000;
constexpr int kKeyRetryMs = 5000;
constexpr int kRequestTimeoutMs = 5000;
constexpr int kMinKeyLength = 16;
} // namespace

YmdClient::YmdClient(QObject *parent)
    : YmdClient(QUrl(QStringLiteral("http://127.0.0.1:8765")), QString(),
                QStringLiteral("ymd"), parent)
{
}

YmdClient::YmdClient(const QUrl &baseUrl, const QString &keyPath,
                     const QString &keyCommand, QObject *parent)
    : QObject(parent)
    , m_baseUrl(baseUrl)
    , m_keyPath(keyPath)
    , m_keyCommand(keyCommand)
{
    m_pollTimer.setInterval(kPollIdleMs);
    connect(&m_pollTimer, &QTimer::timeout, this, &YmdClient::refresh);

    m_keyRetryTimer.setSingleShot(true);
    m_keyRetryTimer.setInterval(kKeyRetryMs);
    connect(&m_keyRetryTimer, &QTimer::timeout, this, &YmdClient::retryKey);

    readKey();
    if (m_keyReady) {
        m_pollTimer.start();
        refresh();
    } else {
        scheduleKeyRetry();
    }
}

QVariantMap YmdClient::state() const
{
    return m_state;
}

bool YmdClient::keyReady() const
{
    return m_keyReady;
}

bool YmdClient::authFailed() const
{
    return m_authFailed;
}

QString YmdClient::lastError() const
{
    return m_lastError;
}

QVariantList YmdClient::searchResults() const
{
    return m_searchResults;
}

bool YmdClient::searching() const
{
    return m_searching;
}

QVariantList YmdClient::playlists() const
{
    return m_playlists;
}

QVariantList YmdClient::playlistTracks() const
{
    return m_playlistTracks;
}

QString YmdClient::playlistTitle() const
{
    return m_playlistTitle;
}

QVariantList YmdClient::cacheItems() const
{
    return m_cacheItems;
}

qint64 YmdClient::cacheTotalBytes() const
{
    return m_cacheTotalBytes;
}

qint64 YmdClient::cacheLimitBytes() const
{
    return m_cacheLimitBytes;
}

void YmdClient::refresh()
{
    if (!m_keyReady) {
        readKey();
        if (!m_keyReady) {
            return;
        }
    }

    QNetworkReply *reply = m_nam.get(makeRequest(QStringLiteral("/v1/state")));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleStateReply(reply);
    });
}

void YmdClient::cmd(const QString &op)
{
    cmd(op, QVariantMap());
}

void YmdClient::cmd(const QString &op, const QVariantMap &payload)
{
    sendCmd(op, payload, {});
}

void YmdClient::sendCmd(const QString &op, const QVariantMap &payload,
                        const std::function<void()> &onSuccess)
{
    if (!m_keyReady) {
        readKey();
        if (!m_keyReady) {
            return;
        }
    }

    QJsonObject body;
    body.insert(QStringLiteral("op"), op);
    body.insert(QStringLiteral("payload"), QJsonObject::fromVariantMap(payload));

    QNetworkRequest request = makeRequest(QStringLiteral("/v1/cmd"));
    QNetworkReply *reply =
        m_nam.post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, onSuccess]() {
        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 401) {
            setAuthFailed(true);
            m_pollTimer.stop();
            setError(QStringLiteral("Ключ устарел. Перезапустите ymd."));
        } else if (status >= 400 || reply->error() != QNetworkReply::NoError) {
            setError(errorText(reply));
        } else {
            setError(QString());
            if (onSuccess) {
                onSuccess();
            }
            refresh();
        }
        reply->deleteLater();
    });
}

void YmdClient::search(const QString &text)
{
    if (!m_keyReady) {
        readKey();
        if (!m_keyReady) {
            return;
        }
    }

    const QString query = text.trimmed();
    if (query.isEmpty()) {
        if (!m_searchResults.isEmpty()) {
            m_searchResults.clear();
            emit searchResultsChanged();
        }
        setSearching(false);
        return;
    }

    setSearching(true);
    sendSearch(query, false);
}

void YmdClient::sendSearch(const QString &text, bool retried)
{
    QUrl url = m_baseUrl;
    url.setPath(QStringLiteral("/v1/search"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("q"), text);
    query.addQueryItem(QStringLiteral("page"), QStringLiteral("0"));
    url.setQuery(query);

    QNetworkRequest request(url);
    request.setRawHeader("X-YMD-Session", m_key.toUtf8());
    request.setTransferTimeout(kRequestTimeoutMs);

    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, text, retried]() {
        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 401 && !retried) {
            readKey();
            if (m_keyReady) {
                reply->deleteLater();
                sendSearch(text, true);
                return;
            }
            setAuthFailed(true);
        } else if (status >= 400 || reply->error() != QNetworkReply::NoError) {
            setError(errorText(reply));
            if (!m_searchResults.isEmpty()) {
                m_searchResults.clear();
                emit searchResultsChanged();
            }
        } else {
            const QJsonDocument document = QJsonDocument::fromJson(reply->readAll());
            if (!document.isObject()) {
                setError(QStringLiteral("Некорректный ответ поиска"));
            } else {
                m_searchResults =
                    document.object().value(QStringLiteral("tracks")).toArray().toVariantList();
                setError(QString());
                emit searchResultsChanged();
            }
        }
        setSearching(false);
        reply->deleteLater();
    });
}

void YmdClient::getJson(const QString &path,
                        const std::function<void(const QJsonObject &)> &handler,
                        bool retried)
{
    if (!m_keyReady) {
        readKey();
        if (!m_keyReady) {
            scheduleKeyRetry();
            return;
        }
    }

    QNetworkReply *reply = m_nam.get(makeRequest(path));
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, path, handler, retried]() {
        const int status =
            reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 401 && !retried) {
            readKey();
            if (m_keyReady) {
                reply->deleteLater();
                getJson(path, handler, true);
                return;
            }
            setAuthFailed(true);
        } else if (status >= 400 || reply->error() != QNetworkReply::NoError) {
            setError(errorText(reply));
        } else {
            const QJsonDocument document = QJsonDocument::fromJson(reply->readAll());
            if (!document.isObject()) {
                setError(QStringLiteral("Некорректный ответ демона"));
            } else {
                setAuthFailed(false);
                setError(QString());
                handler(document.object());
            }
        }
        reply->deleteLater();
    });
}

void YmdClient::loadPlaylists()
{
    getJson(QStringLiteral("/v1/playlists"), [this](const QJsonObject &object) {
        m_playlists =
            object.value(QStringLiteral("playlists")).toArray().toVariantList();
        emit playlistsChanged();
    });
}

void YmdClient::loadPlaylist(qint64 uid, qint64 kind)
{
    const QString path = QStringLiteral("/v1/playlist?uid=%1&kind=%2")
                             .arg(uid)
                             .arg(kind);
    getJson(path, [this](const QJsonObject &object) {
        const QJsonObject meta =
            object.value(QStringLiteral("playlist")).toObject();
        m_playlistTitle =
            meta.value(QStringLiteral("title")).toString(QStringLiteral("Плейлист"));
        m_playlistTracks =
            object.value(QStringLiteral("tracks")).toArray().toVariantList();
        emit playlistTracksChanged();
    });
}

void YmdClient::loadCache()
{
    getJson(QStringLiteral("/v1/cache"), [this](const QJsonObject &object) {
        m_cacheItems =
            object.value(QStringLiteral("items")).toArray().toVariantList();
        m_cacheTotalBytes = static_cast<qint64>(
            object.value(QStringLiteral("totalBytes")).toDouble());
        m_cacheLimitBytes = static_cast<qint64>(
            object.value(QStringLiteral("limitBytes")).toDouble());
        emit cacheChanged();
    });
}

void YmdClient::download(const QVariantMap &item)
{
    QVariantMap payload;
    payload.insert(QStringLiteral("track"), item);
    sendCmd(QStringLiteral("download_track"), payload, {});
}

void YmdClient::downloadAll(const QVariantList &tracks)
{
    QVariantMap payload;
    payload.insert(QStringLiteral("tracks"), tracks);
    sendCmd(QStringLiteral("download_tracks"), payload, {});
}

void YmdClient::removeCached(const QString &id)
{
    sendCmd(QStringLiteral("cache_remove"),
            QVariantMap{{QStringLiteral("id"), id}},
            [this]() { loadCache(); });
}

void YmdClient::clearCache()
{
    sendCmd(QStringLiteral("cache_clear"), {}, [this]() { loadCache(); });
}

void YmdClient::setCacheLimit(qint64 limitMb)
{
    sendCmd(QStringLiteral("cache_limit"),
            QVariantMap{{QStringLiteral("limitMb"), limitMb}},
            [this]() { loadCache(); });
}

void YmdClient::seek(qint64 positionMs)
{
    cmd(QStringLiteral("seek"),
        QVariantMap{{QStringLiteral("positionMs"), positionMs}});
}

void YmdClient::retryKey()
{
    readKey();
    if (!m_keyReady) {
        scheduleKeyRetry();
        return;
    }

    m_authRetried = false;
    setAuthFailed(false);
    setError(QString());
    if (!m_pollTimer.isActive()) {
        m_pollTimer.start();
    }
    refresh();
}

void YmdClient::readKey()
{
    QString path = m_keyPath;
    if (path.isEmpty()) {
        const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        if (!runtime.isEmpty()) {
            path = runtime + QStringLiteral("/ymd/session.key");
        }
    }

    QString key;
    if (!path.isEmpty()) {
        QFile file(path);
        if (file.open(QIODevice::ReadOnly)) {
            key = QString::fromUtf8(file.readAll()).trimmed();
        }
    }

    if (key.size() < kMinKeyLength && !m_keyCommand.isEmpty()) {
        QProcess process;
        process.start(m_keyCommand, {QStringLiteral("session-key")});
        if (process.waitForStarted(1000) && process.waitForFinished(3000)) {
            key = QString::fromUtf8(process.readAllStandardOutput()).trimmed();
        }
    }

    const bool ready = key.size() >= kMinKeyLength;
    if (m_key != key || m_keyReady != ready) {
        m_key = key;
        m_keyReady = ready;
        emit keyChanged();
    }

    if (ready) {
        m_keyRetryTimer.stop();
        setError(QString());
        return;
    }

    setError(QStringLiteral("Ключ не найден. Запущен ли ymd?"));
    scheduleKeyRetry();
}

void YmdClient::scheduleKeyRetry()
{
    if (!m_keyRetryTimer.isActive()) {
        m_keyRetryTimer.start();
    }
}

void YmdClient::handleStateReply(QNetworkReply *reply)
{
    const int status =
        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();

    if (status == 401) {
        if (!m_authRetried) {
            m_authRetried = true;
            readKey();
            if (m_keyReady) {
                reply->deleteLater();
                refresh();
                return;
            }
        }
        setAuthFailed(true);
        m_pollTimer.stop();
        setError(QStringLiteral("Ключ устарел. Перезапустите ymd."));
        reply->deleteLater();
        return;
    }

    if (status >= 400 || reply->error() != QNetworkReply::NoError) {
        setError(errorText(reply));
        reply->deleteLater();
        return;
    }

    const QJsonDocument document = QJsonDocument::fromJson(reply->readAll());
    if (!document.isObject()) {
        setError(QStringLiteral("Некорректный ответ демона"));
        reply->deleteLater();
        return;
    }

    m_state = document.object().toVariantMap();
    m_authRetried = false;
    setAuthFailed(false);
    setError(QString());
    emit stateChanged();
    updatePolling();
    reply->deleteLater();
}

void YmdClient::updatePolling()
{
    const QString status = m_state.value(QStringLiteral("status")).toString();
    const int interval = status == QLatin1String("playing") ? kPollPlayingMs : kPollIdleMs;
    if (m_pollTimer.interval() != interval) {
        m_pollTimer.setInterval(interval);
    }
    if (!m_pollTimer.isActive()) {
        m_pollTimer.start();
    }
}

void YmdClient::setAuthFailed(bool value)
{
    if (m_authFailed == value) {
        return;
    }
    m_authFailed = value;
    emit authChanged();
}

void YmdClient::setError(const QString &error)
{
    if (m_lastError == error) {
        return;
    }
    m_lastError = error;
    emit errorChanged();
}

void YmdClient::setSearching(bool value)
{
    if (m_searching == value) {
        return;
    }
    m_searching = value;
    emit searchingChanged();
}

QNetworkRequest YmdClient::makeRequest(const QString &path) const
{
    QNetworkRequest request(QUrl(m_baseUrl.toString() + path));
    request.setRawHeader("X-YMD-Session", m_key.toUtf8());
    request.setHeader(QNetworkRequest::ContentTypeHeader,
                      QStringLiteral("application/json"));
    request.setTransferTimeout(kRequestTimeoutMs);
    return request;
}

QString YmdClient::errorText(QNetworkReply *reply) const
{
    const QString body = QString::fromUtf8(reply->readAll()).trimmed();
    if (!body.isEmpty()) {
        return body;
    }
    return reply->errorString();
}
