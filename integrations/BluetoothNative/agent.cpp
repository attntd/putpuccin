#include "agent.h"

#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QRegularExpression>
#include <QUuid>

static const QString agentPath = QStringLiteral("/org/quickshell/BluetoothAgent");
static const QString deviceInterface = QStringLiteral("org.bluez.Device1");
static const QString managerInterface = QStringLiteral("org.bluez.AgentManager1");

PairingAgent::PairingAgent(QObject *parent) : QDBusVirtualObject(parent), m_deadline(this) {
    m_deadline.setSingleShot(true);
    m_deadline.setInterval(120000);
    connect(&m_deadline, &QTimer::timeout, this, [this] { finish("timeout"); });
}

PairingAgent::~PairingAgent() { cleanup(); }

bool PairingAgent::start(const QString &path) {
    static const QRegularExpression devicePattern(
        "^/org/bluez/hci[0-9]+/dev_[0-9A-Fa-f]{2}(?:_[0-9A-Fa-f]{2}){5}$");
    if (busy() || !devicePattern.match(path).hasMatch()) return false;
    ++m_generation;
    m_device = path;
    m_phase = "registering";
    m_paired = false;
    m_connectionName = "quickshell-pairing-" + QUuid::createUuid().toString(QUuid::Id128);
    m_bus = QDBusConnection::connectToBus(QDBusConnection::SystemBus, m_connectionName);
    emit changed();
    if (!m_bus.isConnected() || !m_bus.registerVirtualObject(agentPath, this)) {
        finish("unavailable");
        return false;
    }
    m_deadline.start();
    auto *ownerWatcher = new QDBusServiceWatcher("org.bluez", m_bus,
        QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(ownerWatcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
        [this](const QString &, const QString &, const QString &) { finish("unavailable"); });
    // Resolve BlueZ once. All calls and callbacks belong to this exact daemon
    // and private connection, never to a replacement service or another app.
    auto msg = QDBusMessage::createMethodCall("org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner");
    msg << QStringLiteral("org.bluez");
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg, 5000), this);
    const auto generation = m_generation;
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
        [this, generation](QDBusPendingCallWatcher *done) {
            const auto reply = done->reply();
            done->deleteLater();
            if (generation != m_generation || !busy()) return;
            if (reply.type() == QDBusMessage::ErrorMessage || reply.arguments().isEmpty()) {
                finish("unavailable");
                return;
            }
            m_owner = reply.arguments().first().toString();
            call("/org/bluez", managerInterface, "RegisterAgent",
                {QVariant::fromValue(QDBusObjectPath(agentPath)), QStringLiteral("KeyboardDisplay")},
                5000, [this](const QDBusMessage &reply) {
                    if (reply.type() == QDBusMessage::ErrorMessage) {
                        finish(reply.errorName());
                        return;
                    }
                    m_registered = true;
                    m_phase = "pairing";
                    emit changed();
                    call(m_device, deviceInterface, "Pair", {}, 120000,
                        [this](const QDBusMessage &reply) {
                            if (reply.type() == QDBusMessage::ErrorMessage) {
                                finish(reply.errorName());
                                return;
                            }
                            m_paired = true;
                            clearPrompt();
                            m_phase = "trusting";
                            emit changed();
                            call(m_device, "org.freedesktop.DBus.Properties", "Set",
                                {deviceInterface, QStringLiteral("Trusted"),
                                 QVariant::fromValue(QDBusVariant(true))}, 5000,
                                [this](const QDBusMessage &reply) {
                                    if (reply.type() == QDBusMessage::ErrorMessage) {
                                        finish(reply.errorName());
                                        return;
                                    }
                                    m_phase = "connecting";
                                    emit changed();
                                    call(m_device, deviceInterface, "Connect", {}, 30000,
                                        [this](const QDBusMessage &reply) {
                                            finish(reply.type() == QDBusMessage::ErrorMessage
                                                && reply.errorName() != "org.bluez.Error.AlreadyConnected"
                                                ? reply.errorName() : QString());
                                        });
                                });
                        });
                });
        });
    return true;
}

void PairingAgent::call(const QString &path, const QString &interface,
        const QString &method, const QVariantList &args, int timeout,
        std::function<void(const QDBusMessage &)> callback) {
    auto msg = QDBusMessage::createMethodCall(m_owner, path, interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg, timeout), this);
    const auto generation = m_generation;
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
        [this, generation, callback](QDBusPendingCallWatcher *done) {
            const auto reply = done->reply();
            done->deleteLater();
            if (generation == m_generation && busy()) callback(reply);
        });
}

void PairingAgent::clearPrompt() {
    m_pending = QDBusMessage();
    m_prompt.clear();
    m_code.clear();
    m_entered = 0;
    ++m_requestId;
}

void PairingAgent::cleanup(bool abort) {
    ++m_generation;
    m_deadline.stop();
    if (m_pending.type() == QDBusMessage::MethodCallMessage)
        m_bus.send(m_pending.createErrorReply("org.bluez.Error.Canceled", "Pairing canceled"));
    if (abort && !m_owner.isEmpty() && m_phase == "pairing") {
        auto cancel = QDBusMessage::createMethodCall(m_owner, m_device, deviceInterface, "CancelPairing");
        m_bus.asyncCall(cancel, 5000);
    }
    if (abort && !m_owner.isEmpty() && m_phase == "connecting") {
        auto disconnect = QDBusMessage::createMethodCall(m_owner, m_device, deviceInterface, "Disconnect");
        m_bus.asyncCall(disconnect, 5000);
    }
    if (m_registered) {
        auto unregister = QDBusMessage::createMethodCall(m_owner, "/org/bluez", managerInterface, "UnregisterAgent");
        unregister << QVariant::fromValue(QDBusObjectPath(agentPath));
        m_bus.asyncCall(unregister, 5000);
    }
    // Drop watchers as well as the bus: no outstanding timers, registration or
    // late result may survive closing the panel, reloading or destroying QML.
    for (auto *watcher : findChildren<QDBusPendingCallWatcher *>(QString(), Qt::FindDirectChildrenOnly))
        watcher->deleteLater();
    for (auto *watcher : findChildren<QDBusServiceWatcher *>(QString(), Qt::FindDirectChildrenOnly)) {
        watcher->disconnect(this);
        watcher->setConnection(QDBusConnection(QString()));
        watcher->deleteLater();
    }
    m_bus.unregisterObject(agentPath);
    if (!m_connectionName.isEmpty()) QDBusConnection::disconnectFromBus(m_connectionName);
    m_bus = QDBusConnection(QString());
    m_registered = false;
    m_connectionName.clear();
    m_owner.clear();
    m_device.clear();
    m_phase.clear();
    clearPrompt();
}

void PairingAgent::finish(const QString &error) {
    if (!busy()) return;
    const auto path = m_device, phase = m_phase;
    const auto paired = m_paired;
    cleanup(!error.isEmpty());
    emit changed();
    emit finished(path, error, phase, paired);
}

void PairingAgent::cancel() { finish("canceled"); }

bool PairingAgent::respond(uint request, const QString &value) {
    if (!busy() || request != m_requestId || m_pending.type() != QDBusMessage::MethodCallMessage)
        return false;
    QVariantList args;
    if (m_prompt == "pin") {
        if (value.isEmpty() || value.size() > 16 || value.contains(QChar::Null)) return false;
        args << value;
    } else if (m_prompt == "passkey") {
        static const QRegularExpression digits("^[0-9]{1,6}$");
        if (!digits.match(value).hasMatch()) return false;
        args << value.toUInt();
    }
    m_bus.send(m_pending.createReply(args));
    clearPrompt();
    emit changed();
    return true;
}

QString PairingAgent::introspect(const QString &) const {
    return QStringLiteral(R"(<interface name="org.bluez.Agent1">
      <method name="Release"/>
      <method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
      <method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
      <method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
      <method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
      <method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
      <method name="RequestAuthorization"><arg type="o" direction="in"/></method>
      <method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
      <method name="Cancel"/>
    </interface>)");
}

bool PairingAgent::handleMessage(const QDBusMessage &msg, const QDBusConnection &bus) {
    if (msg.interface() != "org.bluez.Agent1") return false;
    const auto reject = [&](const QString &name = "org.bluez.Error.Rejected") {
        bus.send(msg.createErrorReply(name, "Pairing request rejected"));
        return true;
    };
    if (!busy() || msg.service() != m_owner) return reject();
    const auto method = msg.member();
    if (method == "Cancel" || method == "Release") {
        if (!msg.signature().isEmpty()) return reject();
        bus.send(msg.createReply());
        if (method == "Release") {
            m_registered = false;
            finish("canceled");
        } else {
            // BlueZ also sends Cancel when a displayed code is no longer needed.
            // The outstanding Pair reply determines success or failure.
            if (m_pending.type() == QDBusMessage::MethodCallMessage)
                m_bus.send(m_pending.createErrorReply("org.bluez.Error.Canceled", "Request canceled"));
            clearPrompt();
            emit changed();
        }
        return true;
    }
    static const QHash<QString, QString> signatures{
        {"RequestPinCode", "o"}, {"RequestPasskey", "o"},
        {"DisplayPinCode", "os"}, {"DisplayPasskey", "ouq"},
        {"RequestConfirmation", "ou"}, {"RequestAuthorization", "o"},
        {"AuthorizeService", "os"}};
    if (!signatures.contains(method)) return false;
    if (msg.signature() != signatures.value(method) || m_phase != "pairing") return reject();
    const auto args = msg.arguments();
    if (qvariant_cast<QDBusObjectPath>(args[0]).path() != m_device) return reject();
    if (m_pending.type() == QDBusMessage::MethodCallMessage) return reject();
    clearPrompt();
    if (method == "RequestPinCode") m_prompt = "pin";
    else if (method == "RequestPasskey") m_prompt = "passkey";
    else if (method == "RequestAuthorization") m_prompt = "authorization";
    else if (method == "AuthorizeService") m_prompt = "service";
    else {
        m_code = method == "DisplayPinCode" ? args[1].toString()
            : QString::number(args[1].toUInt()).rightJustified(6, '0');
        if (method == "RequestConfirmation") m_prompt = "confirmation";
        else if (method == "DisplayPinCode") m_prompt = "displayPin";
        else {
            m_prompt = "displayPasskey";
            m_entered = qMin(6, args[2].toInt());
        }
    }
    if (method.startsWith("Display")) bus.send(msg.createReply());
    else {
        msg.setDelayedReply(true);
        m_pending = msg;
    }
    emit changed();
    return true;
}
