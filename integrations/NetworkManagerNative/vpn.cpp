#include "vpn.h"
#include "importer.h"
#include <QDBusArgument>
#include <QDBusConnectionInterface>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QFileInfo>
#include <QUuid>
#include <QRegularExpression>
#include <QSet>
#include <algorithm>

static const QString service = QStringLiteral("org.freedesktop.NetworkManager");
static const QString managerPath = QStringLiteral("/org/freedesktop/NetworkManager");
static const QString settingsPath = managerPath + "/Settings";
static const QString settingsInterface = service + ".Settings";
static const QString connectionInterface = settingsInterface + ".Connection";
static const QString activeInterface = service + ".Connection.Active";
static const QString propertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");
template<typename T> static T value(const QVariant &v) {
    return v.metaType() == QMetaType::fromType<QDBusArgument>() ? qdbus_cast<T>(v.value<QDBusArgument>()) : v.value<T>();
}

VpnProfiles::VpnProfiles(QObject *parent) : QObject(parent), m_deadline(this) {
    m_deadline.setSingleShot(true);
    connect(&m_deadline, &QTimer::timeout, this, [this] {
        // The daemon may have committed an import without returning in time.
        // Discard the draft so a retry cannot create a duplicate profile.
        m_import.clear(); m_preview.clear(); finish("timeout");
    });
}
VpnProfiles::~VpnProfiles() { unwatch(); }

QVariantList VpnProfiles::profiles() const {
    QVariantList result;
    for (auto row : m_profiles) {
        row["state"] = 0;
        for (const auto &active : m_active) {
            if (active.value("Uuid") == row.value("uuid")) {
                row["state"] = active.value("State"); break;
            }
        }
        result.append(row);
    }
    std::sort(result.begin(), result.end(), [](const auto &a, const auto &b) {
        return QString::localeAwareCompare(a.toMap().value("name").toString(), b.toMap().value("name").toString()) < 0;
    });
    return result;
}

void VpnProfiles::setEnabled(bool enabled) {
    if (m_enabled == enabled) return;
    m_enabled = enabled;
    if (enabled && !m_context) watch();
    // Confirmed calls remain alive until acknowledged. Never repeat a write.
    if (!enabled && !busy()) { cancelImport(); unwatch(); }
    emit changed();
}
void VpnProfiles::watch() {
    m_context = new QObject(this); m_bus = QDBusConnection::systemBus();
    m_openVpnAvailable = openVpnInstalled();
    m_ownerWatcher = new QDBusServiceWatcher(service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, m_context);
    connect(m_ownerWatcher, &QDBusServiceWatcher::serviceOwnerChanged, m_context,
        [this](const QString &, const QString &, const QString &) {
            const bool enabled = m_enabled;
            if (busy()) { m_import.clear(); m_preview.clear(); finish("unavailable"); }
            unwatch();
            if (enabled) watch();
        });
    m_bus.connect(service, settingsPath, settingsInterface, "NewConnection", this, SLOT(connectionAdded(QDBusObjectPath)));
    m_bus.connect(service, settingsPath, settingsInterface, "ConnectionRemoved", this, SLOT(connectionRemoved(QDBusObjectPath)));
    m_bus.connect(service, "", connectionInterface, "Updated", this, SLOT(connectionUpdated(QDBusMessage)));
    m_bus.connect(service, "", propertiesInterface, "PropertiesChanged", this, SLOT(propertiesChanged(QString,QVariantMap,QStringList,QDBusMessage)));
    refresh();
}
void VpnProfiles::unwatch() {
    ++m_generation; ++m_activeRevision;
    if (m_context) {
        m_bus.disconnect(service, settingsPath, settingsInterface, "NewConnection", this, SLOT(connectionAdded(QDBusObjectPath)));
        m_bus.disconnect(service, settingsPath, settingsInterface, "ConnectionRemoved", this, SLOT(connectionRemoved(QDBusObjectPath)));
        m_bus.disconnect(service, "", connectionInterface, "Updated", this, SLOT(connectionUpdated(QDBusMessage)));
        m_bus.disconnect(service, "", propertiesInterface, "PropertiesChanged", this, SLOT(propertiesChanged(QString,QVariantMap,QStringList,QDBusMessage)));
        if (m_ownerWatcher) m_ownerWatcher->setConnection(QDBusConnection(QString()));
        m_context->deleteLater(); m_context = nullptr; m_ownerWatcher = nullptr;
    }
    m_profiles.clear(); m_active.clear(); m_profileRevisions.clear(); m_disconnecting.clear(); m_owner.clear();
    m_loading = false; m_bus = QDBusConnection(QString()); emit changed();
}
void VpnProfiles::call(const QString &path, const QString &interface, const QString &method, const QVariantList &args,
                       std::function<void(const QDBusMessage &)> callback, bool mutation) {
    if (!m_context) return;
    const auto generation = m_generation;
    const auto actionRevision = m_actionRevision;
    auto message = QDBusMessage::createMethodCall(m_owner.isEmpty() ? service : m_owner, path, interface, method);
    message.setArguments(args); message.setInteractiveAuthorizationAllowed(mutation);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message, 30000), m_context);
    connect(watcher, &QDBusPendingCallWatcher::finished, m_context, [this, generation, actionRevision, mutation, callback](QDBusPendingCallWatcher *done) {
        const auto reply = done->reply(); done->deleteLater();
        if (generation != m_generation) return;
        if (mutation && (!busy() || actionRevision != m_actionRevision)) return;
        if (reply.type() != QDBusMessage::ErrorMessage && m_owner.isEmpty()) m_owner = reply.service();
        callback(reply);
    });
}
void VpnProfiles::refresh() {
    if (!m_context) return;
    m_loading = true; m_error.clear(); emit changed();
    call(settingsPath, settingsInterface, "ListConnections", {}, [this](const QDBusMessage &reply) {
        m_loading = false;
        if (reply.type() == QDBusMessage::ErrorMessage) { m_error = "unavailable"; emit changed(); return; }
        QSet<QString> paths;
        for (const auto &path : value<QList<QDBusObjectPath>>(reply.arguments().value(0))) {
            paths.insert(path.path()); readProfile(path.path());
        }
        for (const auto &path : m_profiles.keys()) if (!paths.contains(path)) connectionRemoved(QDBusObjectPath(path));
        emit changed();
    });
    readActive();
}
void VpnProfiles::connectionAdded(const QDBusObjectPath &path) { readProfile(path.path()); }
void VpnProfiles::connectionRemoved(const QDBusObjectPath &path) {
    ++m_profileRevisions[path.path()]; m_profiles.remove(path.path()); emit changed();
}
void VpnProfiles::connectionUpdated(const QDBusMessage &message) { readProfile(message.path()); }
void VpnProfiles::readProfile(const QString &path) {
    const auto revision = ++m_profileRevisions[path];
    call(path, connectionInterface, "GetSettings", {}, [this, path, revision](const QDBusMessage &reply) {
        if (m_profileRevisions.value(path) != revision) return;
        if (reply.type() == QDBusMessage::ErrorMessage) { m_profiles.remove(path); emit changed(); return; }
        const auto map = value<NetworkSettingsMap>(reply.arguments().value(0));
        const auto connection = map.value("connection"); const auto type = connection.value("type").toString();
        if (type != "wireguard" && type != "vpn") { m_profiles.remove(path); return; }
        m_profiles[path] = {{"uuid", connection.value("uuid")}, {"name", connection.value("id")},
            {"type", type}, {"kind", type == "wireguard" ? "WireGuard" : map.value("vpn").value("service-type").toString().section('.', -1)}, {"path", path}};
        emit changed();
    });
}
void VpnProfiles::readActive() {
    const auto revision = ++m_activeRevision;
    call(managerPath, propertiesInterface, "Get", {service, QString("ActiveConnections")}, [this, revision](const QDBusMessage &reply) {
        if (revision != m_activeRevision || reply.type() == QDBusMessage::ErrorMessage) return;
        QSet<QString> paths;
        for (const auto &object : value<QList<QDBusObjectPath>>(reply.arguments().value(0).value<QDBusVariant>().variant())) {
            const auto path = object.path(); paths.insert(path);
            call(path, propertiesInterface, "GetAll", {activeInterface}, [this, path, revision](const QDBusMessage &result) {
                if (revision != m_activeRevision || result.type() == QDBusMessage::ErrorMessage) return;
                const auto properties = value<QVariantMap>(result.arguments().value(0));
                const auto type = properties.value("Type").toString();
                if (type == "vpn" || type == "wireguard") m_active[path] = properties;
                emit changed();
            });
        }
        for (const auto &path : m_active.keys()) if (!paths.contains(path)) m_active.remove(path);
        emit changed();
    });
}
void VpnProfiles::propertiesChanged(const QString &interface, const QVariantMap &properties,
                                    const QStringList &invalidated, const QDBusMessage &message) {
    if (interface == service && (properties.contains("ActiveConnections") || invalidated.contains("ActiveConnections"))) readActive();
    else if (interface == activeInterface) {
        if (!m_active.contains(message.path())) { readActive(); return; }
        if (!invalidated.isEmpty()) { readActive(); return; }
        auto &active = m_active[message.path()];
        for (auto i = properties.begin(); i != properties.end(); ++i) active[i.key()] = i.value();
        if (properties.value("State").toUInt() == 4 && !m_disconnecting.remove(active.value("Uuid").toString()))
            m_error = "vpn-disconnected";
        emit changed();
    }
}
bool VpnProfiles::prepareImport(const QUrl &file, const QString &type) {
    if (!m_enabled || busy()) return false;
    cancelImport();
    if (!file.isLocalFile()) { m_error = "vpn-file"; emit changed(); return false; }
    const QFileInfo info(file.toLocalFile());
    if (!info.isFile() || info.size() <= 0 || info.size() > 1024 * 1024) { m_error = "vpn-file"; emit changed(); return false; }
    m_import = importVpn(info.absoluteFilePath(), type, m_error);
    if (!m_error.isEmpty()) { m_import.clear(); emit changed(); return false; }
    m_import["connection"]["uuid"] = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_import["connection"]["autoconnect"] = false;
    m_preview = {{"name", m_import.value("connection").value("id")}, {"type", type}, {"fileName", info.fileName()}};
    emit changed(); return true;
}
void VpnProfiles::cancelImport() {
    if (busy()) return;
    m_import.clear(); m_preview.clear(); m_error.clear(); emit changed();
}
void VpnProfiles::clearError() { m_error.clear(); emit changed(); }
bool VpnProfiles::add(const QString &name) {
    if (!m_enabled || busy() || m_import.isEmpty()) return false;
    const auto trimmed = name.trimmed();
    if (trimmed.isEmpty() || trimmed.size() > 128 || trimmed.contains(QRegularExpression("[\\x{0000}-\\x{001f}\\x{007f}]"))) {
        m_error = "name"; emit changed(); return false;
    }
    m_import["connection"]["id"] = trimmed;
    m_operation = "add"; m_error.clear(); m_deadline.start(45000); emit changed();
    call(settingsPath, settingsInterface, "AddConnection2", {QVariant::fromValue(m_import), quint32(0x1 | 0x20), QVariantMap{}},
         [this](const QDBusMessage &reply) {
             if (reply.type() == QDBusMessage::ErrorMessage) { finish(reply.errorName()); return; }
             const auto path = reply.arguments().value(0).value<QDBusObjectPath>().path();
             m_import.clear(); m_preview.clear(); finish();
             if (m_enabled) { readProfile(path); emit added(); }
         }, true);
    return true;
}
bool VpnProfiles::toggle(const QString &uuid) {
    if (!m_enabled || busy()) return false;
    QString path, activePath;
    for (auto i = m_profiles.begin(); i != m_profiles.end(); ++i) if (i->value("uuid").toString() == uuid) path = i.key();
    if (path.isEmpty()) return false;
    for (auto i = m_active.begin(); i != m_active.end(); ++i) if (i->value("Uuid").toString() == uuid && i->value("State").toUInt() < 4) activePath = i.key();
    m_operation = activePath.isEmpty() ? "connect" : "disconnect"; m_error.clear(); m_deadline.start(45000); emit changed();
    if (!activePath.isEmpty()) m_disconnecting.insert(uuid);
    call(managerPath, service, activePath.isEmpty() ? "ActivateConnection" : "DeactivateConnection",
         activePath.isEmpty() ? QVariantList{QVariant::fromValue(QDBusObjectPath(path)), QVariant::fromValue(QDBusObjectPath("/")), QVariant::fromValue(QDBusObjectPath("/"))}
                              : QVariantList{QVariant::fromValue(QDBusObjectPath(activePath))},
         [this](const QDBusMessage &reply) {
             finish(reply.type() == QDBusMessage::ErrorMessage ? reply.errorName() : QString());
             if (m_enabled) readActive();
         }, true);
    return true;
}
void VpnProfiles::finish(const QString &error) {
    ++m_actionRevision;
    m_deadline.stop(); m_operation.clear(); m_error = error;
    if (!m_enabled) { m_import.clear(); m_preview.clear(); unwatch(); }
    emit changed();
}
