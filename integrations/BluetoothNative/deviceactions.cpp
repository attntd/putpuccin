#include "deviceactions.h"

#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QRegularExpression>

DeviceActions::DeviceActions(QObject *parent) : QObject(parent), m_deadline(this) {
    m_deadline.setSingleShot(true);
    connect(&m_deadline, &QTimer::timeout, this, [this] { finish("timeout"); });
}

DeviceActions::~DeviceActions() { cleanup(true); }

bool DeviceActions::start(const QString &operation, const QString &path, const QString &value) {
    static const QRegularExpression devicePattern(
        "^/org/bluez/hci[0-9]+/dev_[0-9A-Fa-f]{2}(?:_[0-9A-Fa-f]{2}){5}$");
    static const QRegularExpression controls("[\\x{0000}-\\x{001f}\\x{007f}]");
    if (busy() || !devicePattern.match(path).hasMatch()
        || !QStringList{"rename", "forget", "connect", "disconnect"}.contains(operation)
        || (operation == "rename" && (value.toUtf8().size() > 248 || controls.match(value).hasMatch())))
        return false;
    m_context = new QObject(this);
    const auto generation = ++m_generation;
    m_device = path;
    m_operation = operation;
    m_bus = QDBusConnection::systemBus();
    m_deadline.start(operation == "connect" ? 35000 : 10000);
    emit changed();
    auto *service = new QDBusServiceWatcher("org.bluez", m_bus,
        QDBusServiceWatcher::WatchForOwnerChange, m_context);
    connect(service, &QDBusServiceWatcher::serviceOwnerChanged, m_context,
        [this, generation](const QString &, const QString &, const QString &) {
            if (generation == m_generation) finish("unavailable");
        });
    auto owner = QDBusMessage::createMethodCall("org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetNameOwner");
    owner << QStringLiteral("org.bluez");
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(owner, 5000), m_context);
    connect(watcher, &QDBusPendingCallWatcher::finished, m_context,
        [this, value, generation](QDBusPendingCallWatcher *done) {
            const auto reply = done->reply();
            done->deleteLater();
            if (generation != m_generation || !busy()) return;
            if (reply.type() == QDBusMessage::ErrorMessage || reply.arguments().isEmpty()) {
                finish("unavailable");
                return;
            }
            m_owner = reply.arguments().first().toString();
            QString path = m_device, interface = "org.bluez.Device1", method;
            QVariantList args;
            if (m_operation == "rename") {
                interface = "org.freedesktop.DBus.Properties";
                method = "Set";
                args = {QStringLiteral("org.bluez.Device1"), QStringLiteral("Alias"),
                    QVariant::fromValue(QDBusVariant(value))};
            } else if (m_operation == "forget") {
                path = m_device.left(m_device.lastIndexOf('/'));
                interface = "org.bluez.Adapter1";
                method = "RemoveDevice";
                args = {QVariant::fromValue(QDBusObjectPath(m_device))};
            } else method = m_operation == "connect" ? "Connect" : "Disconnect";
            auto command = QDBusMessage::createMethodCall(m_owner, path, interface, method);
            command.setArguments(args);
            m_dispatched = true;
            auto *pending = new QDBusPendingCallWatcher(
                m_bus.asyncCall(command, m_operation == "connect" ? 30000 : 5000), m_context);
            connect(pending, &QDBusPendingCallWatcher::finished, m_context,
                [this, generation](QDBusPendingCallWatcher *result) {
                    if (generation != m_generation || !busy()) return;
                    const auto reply = result->reply();
                    QString error = reply.type() == QDBusMessage::ErrorMessage ? reply.errorName() : QString();
                    if (m_operation == "connect" && error == "org.bluez.Error.AlreadyConnected") error.clear();
                    if (m_operation == "disconnect" && error == "org.bluez.Error.NotConnected") error.clear();
                    finish(error);
                });
        });
    return true;
}

void DeviceActions::cleanup(bool abort) {
    ++m_generation;
    m_deadline.stop();
    if (abort && m_dispatched && m_operation == "connect" && !m_owner.isEmpty()) {
        auto disconnect = QDBusMessage::createMethodCall(m_owner, m_device, "org.bluez.Device1", "Disconnect");
        m_bus.asyncCall(disconnect, 5000);
    }
    // A service watcher can be delivering the signal which led here. Deleting
    // it inside that signal is unsafe; disconnect now, then defer destruction.
    // Generation checks also reject signals which were already queued.
    if (m_context) {
        for (auto *child : m_context->children()) child->disconnect(m_context);
        for (auto *watcher : m_context->findChildren<QDBusServiceWatcher *>())
            watcher->setConnection(QDBusConnection(QString()));
        m_context->deleteLater();
    }
    m_context = nullptr;
    m_bus = QDBusConnection(QString());
    m_device.clear(); m_operation.clear(); m_owner.clear();
    m_dispatched = false;
}

void DeviceActions::finish(const QString &error) {
    if (!busy()) return;
    const auto device = m_device, operation = m_operation;
    cleanup(error == "timeout" || error == "org.freedesktop.DBus.Error.NoReply");
    emit changed();
    emit finished(device, operation, error);
}
