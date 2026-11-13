#include "ymdclient.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSharedPointer>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QUrl>

namespace {

struct FakeResponse
{
    int status = 200;
    QByteArray body = "{}";
};

class FakeServer : public QTcpServer
{
public:
    QList<FakeResponse> responses;
    QList<QByteArray> requestBodies;
    QList<QString> requestPaths;
    int requestCount = 0;

    void enqueue(int status, const QByteArray &body)
    {
        responses.append(FakeResponse{status, body});
    }

protected:
    void incomingConnection(qintptr socketDescriptor) override
    {
        auto *socket = new QTcpSocket(this);
        socket->setSocketDescriptor(socketDescriptor);

        auto buffer = QSharedPointer<QByteArray>::create();
        auto handled = QSharedPointer<bool>::create(false);

        connect(socket, &QTcpSocket::readyRead, this, [this, socket, buffer, handled]() {
            buffer->append(socket->readAll());
            if (*handled) {
                return;
            }

            const int headerEnd = buffer->indexOf("\r\n\r\n");
            if (headerEnd < 0) {
                return;
            }

            int contentLength = 0;
            const QList<QByteArray> lines = buffer->left(headerEnd).split('\n');
            for (const QByteArray &line : lines) {
                if (line.toLower().startsWith("content-length:")) {
                    contentLength = line.mid(15).trimmed().toInt();
                }
            }

            const int total = headerEnd + 4 + contentLength;
            if (buffer->size() < total) {
                return;
            }
            *handled = true;

            const QByteArray requestLine = lines.value(0).trimmed();
            const QList<QByteArray> parts = requestLine.split(' ');
            requestPaths.append(QString::fromUtf8(parts.value(1)));
            requestBodies.append(buffer->mid(headerEnd + 4, contentLength));
            ++requestCount;

            const FakeResponse response =
                responses.isEmpty() ? FakeResponse{500, "no response"} : responses.takeFirst();
            const QByteArray reason = response.status == 200
                ? "OK"
                : (response.status == 401 ? "Unauthorized" : "Error");
            QByteArray out = "HTTP/1.1 " + QByteArray::number(response.status) + " "
                + reason + "\r\nContent-Type: application/json\r\nContent-Length: "
                + QByteArray::number(response.body.size())
                + "\r\nConnection: close\r\n\r\n" + response.body;
            socket->write(out);
            socket->flush();
            socket->disconnectFromHost();
        });

        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
    }
};

const QByteArray kState = R"({
    "rev": 1,
    "status": "playing",
    "track": {"id": 7, "title": "Track", "artists": ["Artist"], "durationMs": 2000},
    "positionMs": 1000,
    "durationMs": 2000,
    "quality": "lossless"
})";

QString writeKey(const QTemporaryDir &dir)
{
    const QString path = dir.path() + QStringLiteral("/session.key");
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return QString();
    }
    file.write("0123456789abcdef0123456789abcdef\n");
    return path;
}

QUrl baseUrl(const FakeServer &server)
{
    return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort()));
}

} // namespace

class TestYmdClient : public QObject
{
    Q_OBJECT

private slots:
    void parsesState();
    void sendsCommandPayload();
    void sendsDownloadAllPayload();
    void parsesSearchResults();
    void retriesOnceOn401();
    void reportsAuthFailureAfterSecond401();
    void reportsMissingKey();
};

void TestYmdClient::parsesState()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));
    server.enqueue(200, kState);

    QTemporaryDir dir;
    YmdClient client(baseUrl(server), writeKey(dir), QString());

    QTRY_COMPARE(client.state().value(QStringLiteral("status")).toString(),
                 QStringLiteral("playing"));
    QCOMPARE(client.state().value(QStringLiteral("track")).toMap()
                 .value(QStringLiteral("title")).toString(),
             QStringLiteral("Track"));
    QVERIFY(client.keyReady());
    QVERIFY(!client.authFailed());
}

void TestYmdClient::sendsCommandPayload()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));
    server.enqueue(200, kState);
    server.enqueue(200, R"({"ok":true,"rev":2})");
    server.enqueue(200, kState);

    QTemporaryDir dir;
    YmdClient client(baseUrl(server), writeKey(dir), QString());
    QTRY_COMPARE(server.requestCount, 1);

    client.cmd(QStringLiteral("seek"),
               QVariantMap{{QStringLiteral("positionMs"), 1234}});
    QTRY_VERIFY(server.requestCount >= 2);

    const QJsonDocument document = QJsonDocument::fromJson(server.requestBodies.value(1));
    QVERIFY(document.isObject());
    QCOMPARE(document.object().value(QStringLiteral("op")).toString(),
             QStringLiteral("seek"));
    QCOMPARE(document.object().value(QStringLiteral("payload")).toObject()
                 .value(QStringLiteral("positionMs")).toInt(),
             1234);
}

void TestYmdClient::sendsDownloadAllPayload()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));
    server.enqueue(200, kState);
    server.enqueue(200, R"({"ok":true,"rev":2})");
    server.enqueue(200, kState);

    QTemporaryDir dir;
    YmdClient client(baseUrl(server), writeKey(dir), QString());
    QTRY_COMPARE(server.requestCount, 1);

    const QVariantList tracks{
        QVariantMap{{QStringLiteral("id"), QStringLiteral("1")},
                    {QStringLiteral("title"), QStringLiteral("One")}},
        QVariantMap{{QStringLiteral("id"), QStringLiteral("2")},
                    {QStringLiteral("title"), QStringLiteral("Two")}},
    };
    client.downloadAll(tracks);
    QTRY_VERIFY(server.requestCount >= 2);

    const QJsonDocument document = QJsonDocument::fromJson(server.requestBodies.value(1));
    QVERIFY(document.isObject());
    QCOMPARE(document.object().value(QStringLiteral("op")).toString(),
             QStringLiteral("download_tracks"));
    const QJsonArray sent = document.object().value(QStringLiteral("payload")).toObject()
                                .value(QStringLiteral("tracks")).toArray();
    QCOMPARE(sent.size(), 2);
    QCOMPARE(sent.at(1).toObject().value(QStringLiteral("id")).toString(),
             QStringLiteral("2"));
}

void TestYmdClient::parsesSearchResults()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));
    server.enqueue(200, kState);
    server.enqueue(200, R"({
        "query": "track",
        "tracks": [
            {"id": 1, "title": "One", "artists": ["A"]},
            {"id": 2, "title": "Two", "artists": ["B"]}
        ]
    })");

    QTemporaryDir dir;
    YmdClient client(baseUrl(server), writeKey(dir), QString());
    QTRY_COMPARE(server.requestCount, 1);

    QSignalSpy spy(&client, &YmdClient::searchResultsChanged);
    client.search(QStringLiteral("track"));
    QTRY_COMPARE(spy.count(), 1);
    QCOMPARE(client.searchResults().size(), 2);
    QVERIFY(server.requestPaths.value(1).startsWith(QStringLiteral("/v1/search?")));
}

void TestYmdClient::retriesOnceOn401()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));
    server.enqueue(401, R"({"error":"bad key"})");
    server.enqueue(200, kState);

    QTemporaryDir dir;
    YmdClient client(baseUrl(server), writeKey(dir), QString());

    QTRY_COMPARE(server.requestCount, 2);
    QTRY_COMPARE(client.state().value(QStringLiteral("rev")).toInt(), 1);
    QVERIFY(!client.authFailed());
}

void TestYmdClient::reportsAuthFailureAfterSecond401()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));
    server.enqueue(401, R"({"error":"bad key"})");
    server.enqueue(401, R"({"error":"bad key"})");

    QTemporaryDir dir;
    YmdClient client(baseUrl(server), writeKey(dir), QString());

    QTRY_VERIFY(client.authFailed());
    QCOMPARE(server.requestCount, 2);
    QVERIFY(client.lastError().contains(QStringLiteral("Ключ")));
}

void TestYmdClient::reportsMissingKey()
{
    FakeServer server;
    QVERIFY(server.listen(QHostAddress::LocalHost, 0));

    QTemporaryDir dir;
    const QString missing = dir.path() + QStringLiteral("/missing.key");
    YmdClient client(baseUrl(server), missing, QString());

    QVERIFY(!client.keyReady());
    QVERIFY(client.lastError().contains(QStringLiteral("Ключ")));
    QCOMPARE(server.requestCount, 0);
}

QTEST_GUILESS_MAIN(TestYmdClient)
#include "test_ymdclient.moc"
