#include "greetdclient.h"
#include <QTest>
#include <QLocalServer>
#include <QTemporaryDir>
#include <QSignalSpy>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonArray>
#include <cstring>

class GreeterTest : public QObject {
    Q_OBJECT
    QTemporaryDir directory;
    QLocalServer server;
    QLocalSocket *peer = nullptr;
    GreetdClient *client = nullptr;
    QByteArray input;
    QJsonObject receive() {
        QElapsedTimer timer;
        timer.start();
        while (timer.elapsed() < 2000) {
            QCoreApplication::processEvents();
            input += peer->readAll();
            if (input.size() >= 4) {
                quint32 size;
                std::memcpy(&size, input.constData(), 4);
                if (input.size() >= 4 + qsizetype(size)) {
                    auto value = QJsonDocument::fromJson(input.mid(4, size)).object();
                    input.remove(0, 4 + size);
                    return value;
                }
            }
            QTest::qWait(1);
        }
        return {};
    }
    void reply(const QJsonObject &value) {
        auto data = QJsonDocument(value).toJson(QJsonDocument::Compact);
        quint32 size = data.size();
        peer->write(reinterpret_cast<const char *>(&size), 4);
        peer->write(data);
        peer->flush();
        QTest::qWait(5);
    }
    void quiet() {
        QTest::qWait(20);
        QCOMPARE(peer->bytesAvailable(), 0);
        QVERIFY(input.isEmpty());
    }
    void prompt(QString style = "secret") {
        reply({{"type", "auth_message"}, {"auth_message_type", style}, {"auth_message", "Synthetic challenge"}});
    }
private slots:
    void init() {
        auto path = directory.filePath("greetd.sock");
        QVERIFY(server.listen(path));
        qputenv("GREETD_SOCK", path.toUtf8());
        client = new GreetdClient;
        QTRY_VERIFY(server.hasPendingConnections());
        peer = server.nextPendingConnection();
#ifdef GREETER_TESTING
        QTRY_VERIFY(client->connected());
        QVERIFY(client->testBuild());
#else
        QTRY_VERIFY(peer->state() == QLocalSocket::UnconnectedState);
        QVERIFY(!client->connected());
        QVERIFY(!client->testBuild());
#endif
    }
    void cleanup() {
        delete client;
        delete peer;
        server.close();
        input.clear();
    }
    void peerAndUnauthenticatedLaunch() {
        client->launch();
        client->respond("synthetic-secret");
        quiet();
#ifndef GREETER_TESTING
        client->begin("alice");
        quiet();
#endif
    }
#ifdef GREETER_TESTING
    void passwordAndFixedSession() {
        QSignalSpy ready(client, &GreetdClient::readyToLaunch), launched(client, &GreetdClient::launched);
        client->begin("alice");
        QCOMPARE(receive(), QJsonObject({{"type", "create_session"}, {"username", "alice"}}));
        client->launch(); quiet();
        prompt();
        QVERIFY(client->responseRequired());
        client->respond("synthetic-secret");
        QCOMPARE(receive().value("response").toString(), QString("synthetic-secret"));
        reply({{"type", "success"}});
        QCOMPARE(ready.count(), 1);
        client->launch();
        const auto launch = receive();
        QCOMPARE(launch.value("type").toString(), QString("start_session"));
        QCOMPARE(launch.value("cmd").toArray(), QJsonArray({"/usr/bin/uwsm", "start", "-e", "-D", "Hyprland", "hyprland.desktop"}));
        QVERIFY(!launch.value("env").toArray().contains("GREETD_SOCK"));
        reply({{"type", "success"}});
        QCOMPARE(launched.count(), 1);
        QCOMPARE(client->state(), QString("launched"));
    }
    void fingerprintAndConversation() {
        client->begin("alice"); receive();
        prompt("info");
        auto ack = receive();
        QCOMPARE(ack.value("type").toString(), QString("post_auth_message_response"));
        QVERIFY(!ack.contains("response"));
        prompt("visible");
        QVERIFY(client->echoResponse());
        client->respond("synthetic-answer"); receive();
        prompt("secret");
        QVERIFY(!client->echoResponse());
        client->respond("synthetic-otp"); receive();
        reply({{"type", "success"}});
        QCOMPARE(client->state(), QString("authenticated"));
    }
    void switchWaitsForCancellationAndIgnoresLateSuccess() {
        QSignalSpy ready(client, &GreetdClient::readyToLaunch);
        client->begin("alice"); receive();
        client->begin("bob");
        client->launch(); quiet();
        reply({{"type", "success"}}); // Alice's delayed result is invalidated.
        QCOMPARE(ready.count(), 0);
        QCOMPARE(receive().value("type").toString(), QString("cancel_session"));
        client->begin("carol");
        client->launch(); quiet();
        reply({{"type", "success"}}); // Cancel ACK must never authorize Carol.
        QCOMPARE(ready.count(), 0);
        QCOMPARE(receive().value("username").toString(), QString("carol"));
        client->launch(); quiet();
        prompt();
        client->respond("synthetic-secret"); receive();
        reply({{"type", "success"}});
        QCOMPARE(ready.count(), 1);
        QCOMPARE(client->user(), QString("carol"));
    }
    void failedPasswordAndRetry() {
        QSignalSpy ready(client, &GreetdClient::readyToLaunch), failed(client, &GreetdClient::authFailure);
        client->begin("alice"); receive(); prompt();
        client->respond("wrong-synthetic-secret"); receive();
        reply({{"type", "error"}, {"error_type", "auth_error"}, {"description", "Synthetic rejection"}});
        QCOMPARE(failed.count(), 1);
        QCOMPARE(receive().value("type").toString(), QString("cancel_session"));
        client->launch(); quiet();
        reply({{"type", "success"}});
        QCOMPARE(ready.count(), 0);
        QCOMPARE(client->state(), QString("idle"));
        quiet(); // No automatic PAM retry.
        client->begin("alice");
        QCOMPARE(receive().value("username").toString(), QString("alice"));
    }
    void invalidUser() {
        for (const auto &name : {"root", "greeter", "alice;touch /tmp/no", "../bob", "", "a\nb"}) client->begin(name);
        quiet();
    }
    void malformed_data() {
        QTest::addColumn<QByteArray>("payload");
        QTest::newRow("invalid-json") << QByteArray("no-json");
        QTest::newRow("non-object") << QByteArray("[]");
        QTest::newRow("unknown-type") << QByteArray("{\"type\":\"other\"}");
        QTest::newRow("bad-style") << QByteArray("{\"type\":\"auth_message\",\"auth_message_type\":\"other\"}");
        QTest::newRow("oversized") << QByteArray(65537, 'a');
        QTest::newRow("empty") << QByteArray();
    }
    void malformed() {
        QFETCH(QByteArray, payload);
        QSignalSpy ready(client, &GreetdClient::readyToLaunch);
        client->begin("alice"); receive();
        quint32 size = payload.size();
        peer->write(reinterpret_cast<const char *>(&size), 4); peer->write(payload); peer->flush();
        QTRY_VERIFY(!client->connected());
        QCOMPARE(ready.count(), 0);
    }
    void disconnectClearsAuthentication() {
        client->begin("alice"); receive(); reply({{"type", "success"}});
        peer->abort();
        QTRY_VERIFY(!client->connected());
        QCOMPARE(client->state(), QString("unavailable"));
        client->launch();
    }
#endif
};
QTEST_GUILESS_MAIN(GreeterTest)
#include "greetd-client.moc"
