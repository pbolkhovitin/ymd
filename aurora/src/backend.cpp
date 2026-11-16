#include "backend.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMediaContent>
#include <QMediaPlayer>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrlQuery>
#include <QDebug>

namespace {

const char *kApiBase = "https://api.music.yandex.ru";
const char *kDeviceCodeUrl = "https://oauth.yandex.ru/device/code";
const char *kTokenUrl = "https://oauth.yandex.ru/token";
const char *kClientId = "23cabbbdc6cd418abb4b39c32c41195d";
const char *kClientSecret = "53bc75238f0c4d08a118e51fe9203300";
const char *kSignKey = "kzqU4XhfCaY6B6JTHODeq5";
const char *kCodecs = "flac,flac-mp4,aac-mp4,he-aac-mp4,aac,he-aac,mp3";
const char *kUserAgent = "YandexMusicDesktopAppWindows/5.95.0";

QByteArray hmacSha256(const QByteArray &key, const QByteArray &message)
{
    QByteArray normalized = key;
    if (normalized.size() > 64)
        normalized = QCryptographicHash::hash(normalized, QCryptographicHash::Sha256);
    normalized = normalized.leftJustified(64, '\0');

    QByteArray outer(64, '\0');
    QByteArray inner(64, '\0');
    for (int i = 0; i < 64; ++i) {
        outer[i] = static_cast<char>(normalized.at(i) ^ 0x5c);
        inner[i] = static_cast<char>(normalized.at(i) ^ 0x36);
    }

    const QByteArray innerHash =
        QCryptographicHash::hash(inner + message, QCryptographicHash::Sha256);
    return QCryptographicHash::hash(outer + innerHash, QCryptographicHash::Sha256);
}

QByteArray stripFileInfoPadding(QByteArray encoded)
{
    const bool hadPadding = encoded.endsWith('=');
    while (encoded.endsWith('='))
        encoded.chop(1);
    if (!hadPadding && !encoded.isEmpty())
        encoded.chop(1);
    return encoded;
}

QString signFileInfo(const QString &ts, const QString &trackId, const QString &quality)
{
    const QByteArray payload =
        (ts + trackId + quality + QString::fromLatin1(kCodecs) + QStringLiteral("raw")).toUtf8();
    const QByteArray mac = hmacSha256(QByteArray(kSignKey), payload);
    return QString::fromLatin1(stripFileInfoPadding(mac.toBase64()));
}

QString valueId(const QJsonValue &value)
{
    if (value.isString())
        return value.toString();
    if (value.isDouble())
        return QString::number(static_cast<qint64>(value.toDouble()));
    return QString();
}

QString artistLine(const QJsonValue &value)
{
    QStringList names;
    if (value.isArray()) {
        const QJsonArray array = value.toArray();
        for (int i = 0; i < array.size(); ++i) {
            const QJsonValue item = array.at(i);
            if (item.isString())
                names.append(item.toString());
            else if (item.isObject())
                names.append(item.toObject().value(QStringLiteral("name")).toString());
        }
    } else if (value.isString()) {
        names.append(value.toString());
    }
    names.removeAll(QString());
    return names.join(QStringLiteral(", "));
}

QString normalizedCover(const QString &raw)
{
    if (raw.trimmed().isEmpty())
        return QString();
    QString cover = raw.trimmed();
    if (!cover.startsWith(QStringLiteral("http://")) && !cover.startsWith(QStringLiteral("https://")))
        cover = QStringLiteral("https://") + cover;
    cover.replace(QStringLiteral("%%"), QStringLiteral("400x400"));
    return cover;
}

QString trackCover(const QJsonObject &track)
{
    QString cover = track.value(QStringLiteral("coverUri")).toString();
    if (cover.isEmpty())
        cover = track.value(QStringLiteral("cover")).toString();
    if (cover.isEmpty()) {
        const QJsonArray albums = track.value(QStringLiteral("albums")).toArray();
        if (!albums.isEmpty())
            cover = albums.first().toObject().value(QStringLiteral("coverUri")).toString();
    }
    return normalizedCover(cover);
}

QVariantMap simplifyTrack(const QJsonObject &track)
{
    QVariantMap item;
    item.insert(QStringLiteral("id"), valueId(track.value(QStringLiteral("id"))));
    item.insert(QStringLiteral("title"), track.value(QStringLiteral("title")).toString());
    item.insert(QStringLiteral("artist"), artistLine(track.value(QStringLiteral("artists"))));
    item.insert(QStringLiteral("cover"), trackCover(track));
    item.insert(QStringLiteral("durationMs"),
                static_cast<qint64>(track.value(QStringLiteral("durationMs")).toDouble()));
    return item;
}

QJsonObject unwrapResult(const QJsonObject &root)
{
    const QJsonObject result = root.value(QStringLiteral("result")).toObject();
    return result.isEmpty() ? root : result;
}

QString replyError(QNetworkReply *reply)
{
    if (!reply)
        return QStringLiteral("Нет ответа сети");
    if (reply->error() != QNetworkReply::NoError)
        return reply->errorString();
    return QStringLiteral("HTTP %1").arg(reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt());
}

} // namespace

Backend::Backend(const QString &dataDir, QObject *parent)
    : QObject(parent)
    , m_dataDir(dataDir)
    , m_status(QStringLiteral("Готово"))
    , m_trackTitle(QStringLiteral("Ничего не играет"))
    , m_index(-1)
    , m_volume(80)
    , m_authInterval(5)
    , m_authorized(false)
    , m_nam(new QNetworkAccessManager(this))
    , m_player(new QMediaPlayer(this))
{
    m_player->setVolume(m_volume);
    connect(m_player, &QMediaPlayer::stateChanged, this, [this](QMediaPlayer::State state) {
        emit playingChanged();
        if (state == QMediaPlayer::PlayingState)
            setStatus(QStringLiteral("Играет"));
        else if (state == QMediaPlayer::PausedState)
            setStatus(QStringLiteral("Пауза"));
    });
    connect(m_player, &QMediaPlayer::positionChanged, this, &Backend::positionChanged);
    connect(m_player, &QMediaPlayer::durationChanged, this, &Backend::durationChanged);
    connect(m_player, &QMediaPlayer::mediaStatusChanged, this, [this](QMediaPlayer::MediaStatus status) {
        if (status == QMediaPlayer::EndOfMedia)
            next();
    });
    connect(&m_authTimer, &QTimer::timeout, this, &Backend::pollAuth);
    loadToken();
}

bool Backend::playing() const
{
    return m_player && m_player->state() == QMediaPlayer::PlayingState;
}

int Backend::volume() const
{
    return m_volume;
}

int Backend::position() const
{
    return m_player ? static_cast<int>(m_player->position()) : 0;
}

int Backend::duration() const
{
    return m_player ? static_cast<int>(m_player->duration()) : 0;
}

void Backend::setStatus(const QString &status)
{
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

void Backend::setTrack(const QVariantMap &track)
{
    m_trackTitle = track.value(QStringLiteral("title")).toString();
    m_trackArtist = track.value(QStringLiteral("artist")).toString();
    m_cover = track.value(QStringLiteral("cover")).toString();
    if (m_trackTitle.isEmpty())
        m_trackTitle = QStringLiteral("Ничего не играет");
    emit trackChanged();
}

void Backend::search(const QString &text)
{
    const QString query = text.trimmed();
    if (query.isEmpty()) {
        setStatus(QStringLiteral("Введите запрос"));
        return;
    }
    if (m_token.isEmpty()) {
        setStatus(QStringLiteral("Сначала войдите в аккаунт"));
        return;
    }

    QUrl url(QString::fromLatin1(kApiBase) + QStringLiteral("/search"));
    QUrlQuery params;
    params.addQueryItem(QStringLiteral("text"), query);
    params.addQueryItem(QStringLiteral("type"), QStringLiteral("all"));
    params.addQueryItem(QStringLiteral("page"), QStringLiteral("0"));
    url.setQuery(params);

    QNetworkReply *reply = apiGet(url.path() + QLatin1Char('?') + url.query());
    if (!reply)
        return;
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleSearch(reply);
    });
    setStatus(QStringLiteral("Поиск: %1").arg(query));
}

void Backend::handleSearch(QNetworkReply *reply)
{
    const QByteArray body = reply->readAll();
    if (reply->error() != QNetworkReply::NoError) {
        setStatus(QStringLiteral("Поиск не выполнен: %1").arg(replyError(reply)));
        reply->deleteLater();
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(body).object();
    const QJsonObject result = unwrapResult(root);
    QJsonArray tracks = result.value(QStringLiteral("tracks")).toArray();
    if (tracks.isEmpty()) {
        const QJsonObject tracksObject = result.value(QStringLiteral("tracks")).toObject();
        tracks = tracksObject.value(QStringLiteral("results")).toArray();
    }

    m_searchResults.clear();
    for (int i = 0; i < tracks.size(); ++i) {
        const QJsonObject track = tracks.at(i).toObject();
        if (track.isEmpty())
            continue;
        m_searchResults.append(simplifyTrack(track));
    }
    emit searchResultsChanged();
    setStatus(QStringLiteral("Найдено: %1").arg(m_searchResults.size()));
    reply->deleteLater();
}

void Backend::playTrack(const QVariantMap &track)
{
    m_queue = m_searchResults;
    m_index = -1;
    const QString id = track.value(QStringLiteral("id")).toString();
    for (int i = 0; i < m_queue.size(); ++i) {
        if (m_queue.at(i).toMap().value(QStringLiteral("id")).toString() == id) {
            m_index = i;
            break;
        }
    }
    if (m_index < 0 && !track.isEmpty()) {
        m_queue.append(track);
        m_index = m_queue.size() - 1;
    }
    setTrack(track);
    requestStream(id);
}

void Backend::toggle()
{
    if (!m_player)
        return;
    if (m_player->state() == QMediaPlayer::PlayingState) {
        m_player->pause();
    } else if (m_player->state() == QMediaPlayer::PausedState) {
        m_player->play();
    } else if (m_player->mediaStatus() != QMediaPlayer::NoMedia) {
        m_player->play();
    } else {
        setStatus(QStringLiteral("Нет трека для воспроизведения"));
    }
}

void Backend::next()
{
    if (m_queue.isEmpty()) {
        setStatus(QStringLiteral("Очередь пуста"));
        return;
    }
    m_index = (m_index + 1) % m_queue.size();
    const QVariantMap track = m_queue.at(m_index).toMap();
    setTrack(track);
    requestStream(track.value(QStringLiteral("id")).toString());
}

void Backend::prev()
{
    if (m_queue.isEmpty()) {
        setStatus(QStringLiteral("Очередь пуста"));
        return;
    }
    m_index = (m_index <= 0) ? m_queue.size() - 1 : m_index - 1;
    const QVariantMap track = m_queue.at(m_index).toMap();
    setTrack(track);
    requestStream(track.value(QStringLiteral("id")).toString());
}

void Backend::seek(int ms)
{
    if (m_player)
        m_player->setPosition(qMax(0, ms));
}

void Backend::setVolume(int value)
{
    m_volume = qBound(0, value, 100);
    if (m_player)
        m_player->setVolume(m_volume);
    emit volumeChanged();
}

void Backend::requestStream(const QString &trackId)
{
    if (trackId.isEmpty()) {
        setStatus(QStringLiteral("Нет идентификатора трека"));
        return;
    }
    if (m_token.isEmpty()) {
        setStatus(QStringLiteral("Сначала войдите в аккаунт"));
        return;
    }

    const QString ts = QString::number(QDateTime::currentDateTimeUtc().toTime_t());
    const QString quality = QStringLiteral("hq");
    const QString sign = signFileInfo(ts, trackId, quality);

    QUrlQuery params;
    params.addQueryItem(QStringLiteral("ts"), ts);
    params.addQueryItem(QStringLiteral("trackId"), trackId);
    params.addQueryItem(QStringLiteral("quality"), quality);
    params.addQueryItem(QStringLiteral("codecs"), QString::fromLatin1(kCodecs));
    params.addQueryItem(QStringLiteral("transports"), QStringLiteral("raw"));
    params.addQueryItem(QStringLiteral("sign"), sign);

    m_pendingTrackId = trackId;
    QNetworkReply *reply = apiGet(QStringLiteral("/get-file-info?") + params.query());
    if (!reply)
        return;
    connect(reply, &QNetworkReply::finished, this, [this, reply, trackId]() {
        handleStream(reply, trackId);
    });
    setStatus(QStringLiteral("Получение потока…"));
}

void Backend::handleStream(QNetworkReply *reply, const QString &trackId)
{
    const QByteArray body = reply->readAll();
    if (reply->error() != QNetworkReply::NoError) {
        setStatus(QStringLiteral("Поток не получен: %1").arg(replyError(reply)));
        reply->deleteLater();
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(body).object();
    QJsonObject info = root.value(QStringLiteral("result")).toObject();
    if (info.isEmpty())
        info = root;
    const QJsonObject downloadInfo = info.value(QStringLiteral("downloadInfo")).toObject();
    QString url = downloadInfo.value(QStringLiteral("url")).toString();
    if (url.isEmpty())
        url = info.value(QStringLiteral("url")).toString();

    if (url.isEmpty()) {
        setStatus(QStringLiteral("Нет ссылки на поток"));
        reply->deleteLater();
        return;
    }

    if (m_pendingTrackId == trackId) {
        m_player->setMedia(QMediaContent(QUrl(url)));
        m_player->play();
        setStatus(QStringLiteral("Играет"));
    }
    reply->deleteLater();
}

void Backend::startAuth()
{
    if (!m_nam)
        return;

    QUrlQuery form;
    form.addQueryItem(QStringLiteral("client_id"), QString::fromLatin1(kClientId));
    form.addQueryItem(QStringLiteral("device_id"),
                      QString::number(qrand() % 9000000000LL + 1000000000LL));
    form.addQueryItem(QStringLiteral("device_name"), QStringLiteral("ymd"));

    m_authStatus = QStringLiteral("Запрос кода…");
    emit authChanged();

    QNetworkReply *reply = apiPost(QString::fromLatin1(kDeviceCodeUrl),
                                   form.query(QUrl::FullyEncoded).toUtf8(),
                                   QStringLiteral("application/x-www-form-urlencoded"));
    if (!reply)
        return;
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleDeviceCode(reply);
    });
}

void Backend::handleDeviceCode(QNetworkReply *reply)
{
    const QByteArray body = reply->readAll();
    if (reply->error() != QNetworkReply::NoError) {
        m_authStatus = QStringLiteral("Не удалось получить код: %1").arg(replyError(reply));
        emit authChanged();
        reply->deleteLater();
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(body).object();
    m_deviceCode = root.value(QStringLiteral("device_code")).toString();
    m_authCode = root.value(QStringLiteral("user_code")).toString();
    m_authUrl = root.value(QStringLiteral("verification_url")).toString();
    if (m_authUrl.isEmpty())
        m_authUrl = root.value(QStringLiteral("verification_uri")).toString();
    m_authInterval = qMax(2, root.value(QStringLiteral("interval")).toInt(5));
    m_authStatus = QStringLiteral("Подтвердите код на сайте");
    emit authChanged();

    m_authTimer.start(m_authInterval * 1000);
    reply->deleteLater();
}

void Backend::pollAuth()
{
    if (m_deviceCode.isEmpty()) {
        m_authTimer.stop();
        return;
    }

    QUrlQuery form;
    form.addQueryItem(QStringLiteral("grant_type"), QStringLiteral("device_code"));
    form.addQueryItem(QStringLiteral("code"), m_deviceCode);
    form.addQueryItem(QStringLiteral("client_id"), QString::fromLatin1(kClientId));
    form.addQueryItem(QStringLiteral("client_secret"), QString::fromLatin1(kClientSecret));

    QNetworkReply *reply = apiPost(QString::fromLatin1(kTokenUrl),
                                   form.query(QUrl::FullyEncoded).toUtf8(),
                                   QStringLiteral("application/x-www-form-urlencoded"));
    if (!reply)
        return;
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleTokenPoll(reply);
    });
}

void Backend::handleTokenPoll(QNetworkReply *reply)
{
    const QByteArray body = reply->readAll();
    const QJsonObject root = QJsonDocument::fromJson(body).object();
    const QString token = root.value(QStringLiteral("access_token")).toString();

    if (!token.isEmpty()) {
        m_authTimer.stop();
        m_deviceCode.clear();
        m_authCode.clear();
        m_authStatus = QStringLiteral("Вход выполнен");
        setToken(token, true);
        emit authChanged();
        reply->deleteLater();
        return;
    }

    const QString error = root.value(QStringLiteral("error")).toString();
    if (error == QStringLiteral("authorization_pending")) {
        m_authStatus = QStringLiteral("Ожидание подтверждения…");
    } else if (error == QStringLiteral("slow_down")) {
        m_authInterval += 2;
        m_authTimer.start(m_authInterval * 1000);
        m_authStatus = QStringLiteral("Ожидание подтверждения…");
    } else if (error == QStringLiteral("expired_token")) {
        m_authTimer.stop();
        m_authStatus = QStringLiteral("Код истёк, запросите новый");
    } else if (!error.isEmpty()) {
        m_authStatus = QStringLiteral("Ошибка входа: %1").arg(error);
    } else {
        m_authStatus = QStringLiteral("Ожидание подтверждения…");
    }
    emit authChanged();
    reply->deleteLater();
}

void Backend::setToken(const QString &token, bool save)
{
    m_token = token.trimmed();
    if (save && !m_token.isEmpty()) {
        QDir().mkpath(m_dataDir);
        QFile file(m_dataDir + QStringLiteral("/token"));
        if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            file.write(m_token.toUtf8());
            file.close();
            file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        }
    }
    if (!m_token.isEmpty())
        fetchAccount();
}

void Backend::loadToken()
{
    QString token;
    QFile local(m_dataDir + QStringLiteral("/token"));
    if (local.open(QIODevice::ReadOnly))
        token = QString::fromUtf8(local.readAll()).trimmed();
    if (token.isEmpty()) {
        QFile legacy(QDir::homePath() + QStringLiteral("/.local/state/ymd/token"));
        if (legacy.open(QIODevice::ReadOnly))
            token = QString::fromUtf8(legacy.readAll()).trimmed();
    }
    if (token.isEmpty()) {
        m_authStatus = QStringLiteral("Требуется вход");
        return;
    }
    setToken(token, false);
}

void Backend::fetchAccount()
{
    QNetworkReply *reply = apiGet(QStringLiteral("/account/about"));
    if (!reply)
        return;
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleAccount(reply);
    });
}

void Backend::handleAccount(QNetworkReply *reply)
{
    const QByteArray body = reply->readAll();
    if (reply->error() != QNetworkReply::NoError) {
        m_authorized = false;
        m_accountLogin.clear();
        m_authStatus = QStringLiteral("Требуется вход");
        emit accountChanged();
        reply->deleteLater();
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(body).object();
    const QJsonObject result = unwrapResult(root);
    m_uid = valueId(result.value(QStringLiteral("uid")));
    m_accountLogin = result.value(QStringLiteral("login")).toString();
    m_authorized = !m_uid.isEmpty();
    m_authStatus = m_authorized ? QStringLiteral("Вход выполнен") : QStringLiteral("Требуется вход");
    emit accountChanged();
    emit authChanged();
    if (m_authorized)
        setStatus(QStringLiteral("Аккаунт: %1").arg(m_accountLogin));
    reply->deleteLater();
}

void Backend::logout()
{
    m_authTimer.stop();
    m_token.clear();
    m_uid.clear();
    m_accountLogin.clear();
    m_authorized = false;
    m_authStatus = QStringLiteral("Требуется вход");
    m_authCode.clear();
    m_authUrl.clear();
    m_deviceCode.clear();
    QFile::remove(m_dataDir + QStringLiteral("/token"));
    emit accountChanged();
    emit authChanged();
    setStatus(QStringLiteral("Выход выполнен"));
}

QNetworkReply *Backend::apiGet(const QString &path)
{
    QNetworkRequest request(QUrl(QString::fromLatin1(kApiBase) + path));
    request.setRawHeader("Authorization", QByteArray("OAuth ") + m_token.toUtf8());
    request.setRawHeader("X-Yandex-Music-Client", kUserAgent);
    request.setRawHeader("Accept-Language", "ru");
    return m_nam->get(request);
}

QNetworkReply *Backend::apiPost(const QString &url, const QByteArray &body,
                                const QString &contentType)
{
    QNetworkRequest request((QUrl(url)));
    request.setHeader(QNetworkRequest::ContentTypeHeader, contentType);
    request.setRawHeader("X-Yandex-Music-Client", kUserAgent);
    request.setRawHeader("Accept-Language", "ru");
    return m_nam->post(request, body);
}
