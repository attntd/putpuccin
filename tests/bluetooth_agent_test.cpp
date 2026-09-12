#include "../integrations/BluetoothNative/agent.h"
#include "../integrations/BluetoothNative/deviceactions.h"
#include <QtTest>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QDBusServiceWatcher>

static const QString device = "/org/bluez/hci0/dev_01_02_03_04_05_06";

class BluezMock : public QDBusVirtualObject {
    Q_OBJECT
public:
    QDBusConnection bus = QDBusConnection::sessionBus();
    QString agent, agentPath, mode, failAt, error = "org.bluez.Error.AuthenticationFailed";
    QStringList calls;
    QList<QDBusMessage> messages;
    QVariantList response;
    QDBusMessage pendingPair, pendingRegister, pendingConnect;
    QSet<QString> registrations;
    bool holdRegistration = false, holdConnect = false, finishDisplay = true;
    uint serial = 0;
    QString introspect(const QString &) const override { return {}; }

    void replyPair(const QString &failure = QString()) {
        if (pendingPair.type() != QDBusMessage::MethodCallMessage) return;
        bus.send(failure.isEmpty() ? pendingPair.createReply() : pendingPair.createErrorReply(failure, "Synthetic error"));
        pendingPair = {};
    }
    QDBusPendingCall request(const QString &method, const QVariantList &args) {
        auto msg = QDBusMessage::createMethodCall(agent, agentPath, "org.bluez.Agent1", method);
        msg.setArguments(args);
        return bus.asyncCall(msg, 3000);
    }
    bool handleMessage(const QDBusMessage &msg, const QDBusConnection &) override {
        const auto method = msg.member();
        calls << method;
        messages << msg;
        if (method == failAt) {
            bus.send(msg.createErrorReply(error, "Synthetic error"));
            return true;
        }
        if (method == "RegisterAgent") {
            agent = msg.service();
            agentPath = qvariant_cast<QDBusObjectPath>(msg.arguments()[0]).path();
            if (msg.arguments()[1].toString() != "KeyboardDisplay") return false;
            registrations.insert(agent);
            auto *watcher = new QDBusServiceWatcher(agent, bus, QDBusServiceWatcher::WatchForUnregistration, this);
            connect(watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this, watcher](const QString &name) {
                registrations.remove(name);
                watcher->deleteLater();
            });
            if (holdRegistration) { msg.setDelayedReply(true); pendingRegister = msg; return true; }
        } else if (method == "UnregisterAgent") {
            registrations.remove(msg.service());
        } else if (method == "Pair") {
            msg.setDelayedReply(true);
            pendingPair = msg;
            if (mode == "hold") return true;
            if (mode.isEmpty()) { replyPair(); return true; }
            QVariantList args{QVariant::fromValue(QDBusObjectPath(device))};
            if (mode == "DisplayPinCode") args << QStringLiteral("000042");
            else if (mode == "RequestConfirmation" || mode == "DisplayPasskey") args << uint(42);
            else if (mode == "AuthorizeService") args << QStringLiteral("00001124-0000-1000-8000-00805f9b34fb");
            if (mode == "DisplayPasskey") args << QVariant::fromValue(ushort(0));
            auto *watcher = new QDBusPendingCallWatcher(request(mode, args), this);
            const auto generation = serial;
            connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, generation](QDBusPendingCallWatcher *done) {
                const auto reply = done->reply();
                done->deleteLater();
                if (generation != serial) return;
                response = reply.arguments();
                if (reply.type() == QDBusMessage::ErrorMessage) replyPair(reply.errorName());
                else if (!mode.startsWith("Display") || finishDisplay) replyPair();
            });
            return true;
        } else if (method == "CancelPairing") {
            replyPair("org.bluez.Error.AuthenticationCanceled");
        } else if (method == "Connect" && holdConnect) {
            msg.setDelayedReply(true); pendingConnect = msg; return true;
        } else if (method == "Set") {
            const auto property = msg.arguments()[1].toString();
            if (property != "Alias" && (property != "Trusted"
                || !qvariant_cast<QDBusVariant>(msg.arguments()[2]).variant().toBool())) return false;
        }
        bus.send(msg.createReply());
        return true;
    }
};

class BluetoothAgentTest : public QObject {
    Q_OBJECT
    BluezMock mock;
private slots:
    void initTestCase() {
        QVERIFY(mock.bus.isConnected());
        QVERIFY(mock.bus.registerService("org.bluez"));
        QVERIFY(mock.bus.registerVirtualObject("/org/bluez", &mock, QDBusConnection::SubPath));
    }
    void init() {
        ++mock.serial;
        mock.mode.clear(); mock.failAt.clear(); mock.calls.clear(); mock.messages.clear(); mock.response.clear();
        mock.pendingPair = {}; mock.pendingRegister = {}; mock.pendingConnect = {};
        mock.error = "org.bluez.Error.AuthenticationFailed";
        mock.holdRegistration = false; mock.holdConnect = false; mock.finishDisplay = true;
    }
    void cleanup() { QTRY_VERIFY(mock.registrations.isEmpty()); }
    void deviceActions_data() {
        QTest::addColumn<QString>("operation"); QTest::addColumn<QString>("method");
        QTest::newRow("rename") << "rename" << "Set";
        QTest::newRow("forget") << "forget" << "RemoveDevice";
        QTest::newRow("connect") << "connect" << "Connect";
        QTest::newRow("disconnect") << "disconnect" << "Disconnect";
    }
    void deviceActions() {
        QFETCH(QString, operation); QFETCH(QString, method);
        DeviceActions actions; QSignalSpy finished(&actions, &DeviceActions::finished);
        QVERIFY(actions.start(operation, device, "Słuchawki <biurko>"));
        QVERIFY(!actions.start("forget", device));
        QTRY_COMPARE(finished.count(), 1);
        QVERIFY(finished.first()[2].toString().isEmpty());
        QVERIFY(!actions.busy()); QVERIFY(actions.operation().isEmpty());
        QVERIFY(!actions.findChild<QTimer *>()->isActive());
        QCOMPARE(mock.calls, QStringList{method});
        const auto message = mock.messages.first();
        if (operation == "forget") {
            QCOMPARE(message.path(), "/org/bluez/hci0");
            QCOMPARE(message.interface(), "org.bluez.Adapter1");
            QCOMPARE(qvariant_cast<QDBusObjectPath>(message.arguments().first()).path(), device);
        } else if (operation == "rename") {
            QCOMPARE(message.path(), device);
            QCOMPARE(message.arguments()[1].toString(), "Alias");
            QCOMPARE(qvariant_cast<QDBusVariant>(message.arguments()[2]).variant().toString(), "Słuchawki <biurko>");
            QVERIFY(actions.start("rename", device, ""));
            QTRY_COMPARE(finished.count(), 2);
            QVERIFY(qvariant_cast<QDBusVariant>(mock.messages.last().arguments()[2]).variant().toString().isEmpty());
        }
    }
    void deviceActionErrors_data() {
        deviceActions_data();
    }
    void deviceActionErrors() {
        QFETCH(QString, operation); QFETCH(QString, method);
        mock.failAt = method; mock.error = "org.bluez.Error.NotAuthorized";
        DeviceActions actions; QSignalSpy finished(&actions, &DeviceActions::finished);
        QVERIFY(actions.start(operation, device, "Alias"));
        QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[2].toString(), mock.error);
        QVERIFY(!actions.busy());
        mock.failAt.clear();
        QVERIFY(actions.start(operation, device, "Alias"));
        QTRY_COMPARE(finished.count(), 2);
        QVERIFY(finished.last()[2].toString().isEmpty());
    }
    void deviceActionValidation() {
        DeviceActions actions;
        QVERIFY(!actions.start("forget", "/org/bluez/hci0"));
        QVERIFY(!actions.start("Pair", device));
        QVERIFY(!actions.start("rename", device, "line\nline"));
        QVERIFY(!actions.start("rename", device, QString(249, 'a')));
        QVERIFY(!actions.start("rename", device, QString(125, QChar(0x0105))));
        QVERIFY(mock.calls.isEmpty());
    }
    void deviceActionLateReply() {
        mock.holdConnect = true;
        DeviceActions actions; QSignalSpy finished(&actions, &DeviceActions::finished);
        QVERIFY(actions.start("connect", device));
        QTRY_VERIFY(mock.calls.contains("Connect"));
        actions.findChild<QTimer *>()->start(1);
        QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[2].toString(), "timeout");
        QTRY_VERIFY(mock.calls.contains("Disconnect"));
        QVERIFY(actions.start("rename", device, "Nowa nazwa"));
        mock.bus.send(mock.pendingConnect.createReply());
        QTRY_COMPARE(finished.count(), 2);
        QCOMPARE(finished.last()[1].toString(), "rename");
        QTest::qWait(30);
        QCOMPARE(finished.count(), 2);
    }
    void deviceActionDaemonLoss() {
        mock.holdConnect = true;
        DeviceActions actions; QSignalSpy finished(&actions, &DeviceActions::finished);
        QVERIFY(actions.start("connect", device));
        QTRY_VERIFY(mock.calls.contains("Connect"));
        QVERIFY(mock.bus.unregisterService("org.bluez"));
        QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[2].toString(), "unavailable");
        QVERIFY(mock.bus.registerService("org.bluez"));
    }
    void deviceActionDestruction() {
        mock.holdConnect = true;
        auto *actions = new DeviceActions;
        QVERIFY(actions->start("connect", device));
        QTRY_VERIFY(mock.calls.contains("Connect"));
        delete actions;
        QTRY_VERIFY(mock.calls.contains("Disconnect"));
        mock.bus.send(mock.pendingConnect.createReply());
        QTest::qWait(30);
    }
    void deviceActionCycles() {
        DeviceActions actions; QSignalSpy finished(&actions, &DeviceActions::finished);
        for (int cycle = 0; cycle < 20; ++cycle) {
            QVERIFY(actions.start("rename", device, "Alias"));
            QTRY_COMPARE(finished.count(), cycle + 1);
            QTRY_COMPARE(actions.findChildren<QDBusServiceWatcher *>().size(), 0);
            QTRY_COMPARE(actions.findChildren<QDBusPendingCallWatcher *>().size(), 0);
            QVERIFY(!actions.findChild<QTimer *>()->isActive());
        }
    }
    void prompts_data() {
        QTest::addColumn<QString>("method"); QTest::addColumn<QString>("prompt");
        QTest::newRow("PIN") << "RequestPinCode" << "pin";
        QTest::newRow("passkey") << "RequestPasskey" << "passkey";
        QTest::newRow("comparison") << "RequestConfirmation" << "confirmation";
        QTest::newRow("authorization") << "RequestAuthorization" << "authorization";
        QTest::newRow("service") << "AuthorizeService" << "service";
        QTest::newRow("keyboard PIN") << "DisplayPinCode" << "displayPin";
        QTest::newRow("keyboard passkey") << "DisplayPasskey" << "displayPasskey";
    }
    void prompts() {
        QFETCH(QString, method); QFETCH(QString, prompt);
        mock.mode = method; mock.finishDisplay = false;
        PairingAgent agent;
        QSignalSpy finished(&agent, &PairingAgent::finished);
        QVERIFY(agent.start(device));
        QVERIFY(!agent.start(device));
        QTRY_COMPARE(agent.prompt(), prompt);
        if (method.startsWith("Display") || method == "RequestConfirmation") QCOMPARE(agent.code(), "000042");
        if (method == "DisplayPasskey") {
            QDBusPendingCallWatcher update(mock.request(method,
                {QVariant::fromValue(QDBusObjectPath(device)), uint(42), QVariant::fromValue(ushort(4))}));
            QTRY_COMPARE(agent.entered(), 4);
            QCOMPARE(agent.code(), "000042");
        }
        if (method.startsWith("Display")) {
            QDBusPendingCallWatcher clear(mock.request("Cancel", {}));
            QTRY_VERIFY(agent.prompt().isEmpty());
            QVERIFY(agent.busy());
            mock.replyPair();
        } else {
            QVERIFY(!agent.respond(agent.requestId() + 1, "42"));
            if (prompt == "pin" || prompt == "passkey") {
                QVERIFY(!agent.respond(agent.requestId(), ""));
                QVERIFY(!agent.respond(agent.requestId(), "12345678901234567"));
            }
            if (prompt == "passkey") QVERIFY(!agent.respond(agent.requestId(), "abc"));
            QVERIFY(agent.respond(agent.requestId(), prompt == "pin" ? "00Ab" : "000042"));
            QVERIFY(!agent.respond(agent.requestId(), "000042"));
        }
        QTRY_COMPARE(finished.count(), 1);
        QVERIFY(finished.first()[1].toString().isEmpty());
        QCOMPARE(finished.first()[3].toBool(), true);
        QCOMPARE(mock.calls.mid(0, 4), QStringList({"RegisterAgent", "Pair", "Set", "Connect"}));
        if (prompt == "pin") QCOMPARE(mock.response.first().toString(), "00Ab");
        if (prompt == "passkey") QCOMPARE(mock.response.first().toUInt(), 42u);
        QVERIFY(!agent.busy()); QVERIFY(agent.code().isEmpty());
    }
    void failures_data() {
        QTest::addColumn<QString>("stage");
        for (const auto &stage : {"RegisterAgent", "Pair", "Set", "Connect"}) QTest::newRow(stage) << QString(stage);
    }
    void failures() {
        QFETCH(QString, stage); mock.failAt = stage;
        PairingAgent agent; QSignalSpy finished(&agent, &PairingAgent::finished);
        QVERIFY(agent.start(device));
        QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[1].toString(), mock.error);
        QCOMPARE(finished.first()[3].toBool(), stage == "Set" || stage == "Connect");
        if (stage == "RegisterAgent" || stage == "Pair") QVERIFY(!mock.calls.contains("Set"));
        if (stage != "Connect") QVERIFY(!mock.calls.contains("Connect"));
    }
    void cancellationAndRestart() {
        mock.mode = "RequestConfirmation";
        PairingAgent agent; QSignalSpy finished(&agent, &PairingAgent::finished);
        for (int cycle = 0; cycle < 20; ++cycle) {
            ++mock.serial;
            QVERIFY(agent.start(device));
            QTRY_COMPARE(agent.prompt(), "confirmation");
            const auto request = agent.requestId();
            agent.cancel();
            QVERIFY(!agent.busy()); QVERIFY(!agent.respond(request, ""));
            QTRY_VERIFY(mock.registrations.isEmpty());
        }
        QCOMPARE(finished.count(), 20);
        QVERIFY(!mock.calls.contains("Set")); QVERIFY(!mock.calls.contains("Connect"));
    }
    void destruction() {
        mock.mode = "RequestPinCode";
        auto *agent = new PairingAgent;
        QVERIFY(agent->start(device));
        QTRY_COMPARE(agent->prompt(), "pin");
        delete agent;
        QTRY_VERIFY(mock.registrations.isEmpty());
        QVERIFY(!mock.calls.contains("Set"));
    }
    void cancelRegistration() {
        mock.holdRegistration = true;
        PairingAgent agent; QVERIFY(agent.start(device));
        QTRY_VERIFY(mock.pendingRegister.type() == QDBusMessage::MethodCallMessage);
        agent.cancel();
        mock.bus.send(mock.pendingRegister.createReply());
        QTRY_VERIFY(mock.registrations.isEmpty());
        QVERIFY(!mock.calls.contains("Pair"));
    }
    void cancelConnection() {
        mock.holdConnect = true;
        PairingAgent agent; QSignalSpy finished(&agent, &PairingAgent::finished);
        QVERIFY(agent.start(device));
        QTRY_VERIFY(mock.pendingConnect.type() == QDBusMessage::MethodCallMessage);
        agent.cancel();
        QTRY_VERIFY(mock.calls.contains("Disconnect"));
        mock.bus.send(mock.pendingConnect.createReply());
        QTest::qWait(20);
        QCOMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[1].toString(), "canceled");
        QCOMPARE(finished.first()[3].toBool(), true);
    }
    void unsolicitedRequests() {
        mock.mode = "hold";
        PairingAgent agent; QVERIFY(agent.start(device));
        QTRY_VERIFY(mock.calls.contains("Pair"));
        QDBusPendingCallWatcher wrongDevice(mock.request("RequestPinCode",
            {QVariant::fromValue(QDBusObjectPath("/org/bluez/hci0/dev_00_00_00_00_00_00"))}));
        QTRY_VERIFY(wrongDevice.isFinished());
        QCOMPARE(wrongDevice.reply().errorName(), "org.bluez.Error.Rejected");
        auto foreign = QDBusConnection::connectToBus(QDBusConnection::SessionBus, "foreign");
        auto msg = QDBusMessage::createMethodCall(mock.agent, mock.agentPath, "org.bluez.Agent1", "RequestPinCode");
        msg << QVariant::fromValue(QDBusObjectPath(device));
        QDBusPendingCallWatcher spoof(foreign.asyncCall(msg, 2000));
        QTRY_VERIFY(spoof.isFinished()); QCOMPARE(spoof.reply().errorName(), "org.bluez.Error.Rejected");
        QVERIFY(agent.prompt().isEmpty());
        agent.cancel(); QDBusConnection::disconnectFromBus("foreign");
    }
    void deadline() {
        mock.mode = "hold";
        PairingAgent agent; QSignalSpy finished(&agent, &PairingAgent::finished);
        QVERIFY(agent.start(device)); QTRY_VERIFY(mock.calls.contains("Pair"));
        agent.findChild<QTimer *>()->start(1);
        QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[1].toString(), "timeout"); QVERIFY(!agent.busy());
    }
    void daemonRestart() {
        mock.mode = "hold";
        PairingAgent agent; QSignalSpy finished(&agent, &PairingAgent::finished);
        QVERIFY(agent.start(device)); QTRY_VERIFY(mock.calls.contains("Pair"));
        QVERIFY(mock.bus.unregisterService("org.bluez"));
        QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[1].toString(), "unavailable");
        QVERIFY(mock.bus.registerService("org.bluez"));
    }
    void unavailableAndBadPath() {
        PairingAgent agent; QSignalSpy finished(&agent, &PairingAgent::finished);
        QVERIFY(!agent.start("/org/bluez")); QVERIFY(!agent.start("bad; path"));
        QVERIFY(mock.bus.unregisterService("org.bluez"));
        QVERIFY(agent.start(device)); QTRY_COMPARE(finished.count(), 1);
        QCOMPARE(finished.first()[1].toString(), "unavailable");
        QVERIFY(mock.bus.registerService("org.bluez"));
    }
};
QTEST_GUILESS_MAIN(BluetoothAgentTest)
#include "bluetooth_agent_test.moc"
