#include "editor.h"
#include <QDBusArgument>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QHostAddress>
#include <QRegularExpression>
#include <QtEndian>

static const QString service = QStringLiteral("org.freedesktop.NetworkManager");
static const QString connectionInterface = service + ".Settings.Connection";

QDBusArgument &operator<<(QDBusArgument &a, const NetworkSettingsMap &map) {
    a.beginMap(QMetaType::fromType<QString>(), QMetaType::fromType<QVariantMap>());
    for (auto i = map.cbegin(); i != map.cend(); ++i) {
        a.beginMapEntry(); a << i.key() << i.value(); a.endMapEntry();
    }
    a.endMap(); return a;
}
const QDBusArgument &operator>>(const QDBusArgument &a, NetworkSettingsMap &map) {
    a.beginMap();
    while (!a.atEnd()) {
        QString key; QVariantMap value;
        a.beginMapEntry(); a >> key >> value; a.endMapEntry(); map.insert(key, value);
    }
    a.endMap(); return a;
}

template <typename T> static T dbusValue(const QVariant &value) {
    return value.metaType() == QMetaType::fromType<QDBusArgument>()
        ? qdbus_cast<T>(value.value<QDBusArgument>()) : value.value<T>();
}

static QStringList words(const QString &value) {
    return value.split(QRegularExpression("[,;\\s]+"), Qt::SkipEmptyParts);
}

QVariantMap ProfileEditor::present(const NetworkSettingsMap &map) {
    const auto connection = map.value("connection");
    const auto wifi = map.value("802-11-wireless");
    QVariantMap result{{"name", connection.value("id")}, {"type", connection.value("type")},
        {"autoconnect", connection.value("autoconnect", true)},
        {"hidden", wifi.value("hidden", false)}, {"metered", connection.value("metered", 0)}};
    for (const auto &family : {QString("ipv4"), QString("ipv6")}) {
        const auto ip = map.value(family);
        QStringList addresses;
        for (const auto &address : dbusValue<QList<QVariantMap>>(ip.value("address-data")))
            addresses.append(address.value("address").toString() + '/' + address.value("prefix").toString());
        QStringList dns = dbusValue<QStringList>(ip.value("dns-data"));
        if (!ip.contains("dns-data")) {
            if (family == "ipv4") {
                for (auto address : dbusValue<QList<quint32>>(ip.value("dns")))
                    dns.append(QHostAddress(qFromBigEndian(address)).toString());
            } else {
                for (const auto &address : dbusValue<QList<QByteArray>>(ip.value("dns")))
                    if (address.size() == 16)
                        dns.append(QHostAddress(reinterpret_cast<const quint8 *>(address.constData())).toString());
            }
        }
        result.insert(family, QVariantMap{{"method", ip.value("method", "auto")},
            {"addresses", addresses.join(", ")}, {"gateway", ip.value("gateway", "")},
            {"dns", dns.join(", ")}, {"autoDns", !ip.value("ignore-auto-dns", false).toBool()}});
    }
    return result;
}

QString ProfileEditor::patch(NetworkSettingsMap &map, const QVariantMap &before, const QVariantMap &draft) {
    const auto fresh = present(map);
    // Merge only edited fields into freshly fetched settings. Unknown settings,
    // security, routes and secrets remain under NetworkManager's ownership.
    for (const auto &key : {QString("name"), QString("autoconnect"), QString("hidden"), QString("metered")}) {
        if (!draft.contains(key) || draft.value(key) == before.value(key)) continue;
        if (fresh.value(key) != before.value(key)) return "conflict";
        const auto value = draft.value(key);
        if (key == "name") {
            const auto name = value.toString().trimmed();
            if (name.isEmpty() || name.size() > 128 || name.contains(QRegularExpression("[\\x{0000}-\\x{001f}\\x{007f}]"))) return "name";
            map["connection"]["id"] = name;
        } else if (key == "metered") {
            const int metered = value.toInt();
            if (metered < 0 || metered > 2) return "invalid";
            map["connection"]["metered"] = quint32(metered);
        } else if (key == "hidden") map["802-11-wireless"]["hidden"] = value.toBool();
        else map["connection"]["autoconnect"] = value.toBool();
    }
    for (const auto &family : {QString("ipv4"), QString("ipv6")}) {
        const auto previous = before.value(family).toMap(), next = draft.value(family).toMap();
        if (next.isEmpty()) continue;
        bool edited = false;
        for (const auto &key : {"method", "addresses", "gateway", "dns", "autoDns"})
            edited |= next.contains(key) && next.value(key) != previous.value(key);
        if (!edited) continue;
        const auto current = fresh.value(family).toMap();
        const auto protocol = family == "ipv4" ? QAbstractSocket::IPv4Protocol : QAbstractSocket::IPv6Protocol;
        auto &ip = map[family];
        for (const auto &key : {QString("method"), QString("addresses"), QString("gateway"), QString("dns"), QString("autoDns")}) {
            if (!next.contains(key) || next.value(key) == previous.value(key)) continue;
            if (current.value(key) != previous.value(key)) return "conflict";
            const auto value = next.value(key);
            if (key == "method") {
                if (!QStringList{"auto", "manual", "link-local", "disabled", "dhcp", "ignore", "shared"}.contains(value.toString())) return "invalid";
                ip["method"] = value.toString();
            } else if (key == "addresses") {
                QList<QVariantMap> addresses;
                for (const auto &entry : words(value.toString())) {
                    const auto parts = entry.split('/');
                    bool validPrefix = false;
                    const uint prefix = parts.value(1).toUInt(&validPrefix);
                    const QHostAddress address(parts.value(0));
                    if (parts.size() != 2 || !validPrefix || prefix == 0 || prefix > (family == "ipv4" ? 32u : 128u)
                        || address.protocol() != protocol || address.isNull() || address.isMulticast()) return "address";
                    QVariantMap attributes;
                    // Preserve extra attributes on retained addresses.
                    for (const auto &old : dbusValue<QList<QVariantMap>>(ip.value("address-data")))
                        if (QHostAddress(old.value("address").toString()) == address) { attributes = old; break; }
                    attributes["address"] = address.toString(); attributes["prefix"] = quint32(prefix);
                    addresses.append(attributes);
                }
                ip.remove("addresses");
                ip["address-data"] = QVariant::fromValue(addresses);
            } else if (key == "gateway") {
                const auto gateway = value.toString().trimmed();
                if (!gateway.isEmpty() && QHostAddress(gateway).protocol() != protocol) return "gateway";
                ip.remove("addresses");
                if (gateway.isEmpty()) ip.remove("gateway"); else ip["gateway"] = QHostAddress(gateway).toString();
            } else if (key == "dns") {
                QStringList dns;
                for (const auto &entry : words(value.toString())) {
                    const QHostAddress address(entry);
                    if (address.protocol() != protocol || address.isNull() || address.isMulticast()) return "dns";
                    dns.append(address.toString());
                }
                ip.remove("dns");
                ip["dns-data"] = dns;
            } else ip["ignore-auto-dns"] = !value.toBool();
        }
        const auto method = ip.value("method").toString();
        if (method != previous.value("method").toString()) {
            if ((method == "auto" || method == "dhcp") && previous.value("method") == "manual") {
                ip.remove("addresses"); ip.remove("address-data"); ip.remove("gateway");
            } else if (method == "disabled" || method == "link-local" || method == "ignore") {
                for (const auto &key : {"addresses", "address-data", "gateway", "dns", "dns-data", "dns-search", "dns-options", "routes", "route-data"})
                    ip.remove(key);
                ip["ignore-auto-dns"] = false;
            }
        }
        if (ip.value("method").toString() == "manual"
            && dbusValue<QList<QVariantMap>>(ip.value("address-data")).isEmpty()) return "address";
    }
    return {};
}

ProfileEditor::ProfileEditor(QObject *parent) : QObject(parent), m_deadline(this) {
    qDBusRegisterMetaType<NetworkSettingsMap>();
    qDBusRegisterMetaType<QList<QVariantMap>>();
    qDBusRegisterMetaType<QList<quint32>>();
    qDBusRegisterMetaType<QList<QByteArray>>();
    m_deadline.setSingleShot(true);
    connect(&m_deadline, &QTimer::timeout, this, [this] { complete("timeout"); });
}
ProfileEditor::~ProfileEditor() { cleanup(); }

void ProfileEditor::begin(const QString &operation) {
    cleanup(); m_operation = operation; m_error.clear(); m_clearWhenDone = false;
    m_context = new QObject(this); m_bus = QDBusConnection::systemBus();
    m_deadline.start(45000);
    auto *watcher = new QDBusServiceWatcher(service, m_bus, QDBusServiceWatcher::WatchForOwnerChange, m_context);
    connect(watcher, &QDBusServiceWatcher::serviceOwnerChanged, m_context,
        [this] { complete("unavailable"); });
    emit changed();
}

void ProfileEditor::call(const QString &path, const QString &interface, const QString &method,
    const QVariantList &args, std::function<void(const QDBusMessage &)> callback) {
    const auto generation = m_generation;
    auto message = QDBusMessage::createMethodCall(m_owner.isEmpty() ? service : m_owner, path, interface, method);
    message.setArguments(args);
    if (method == "Update2" || method == "Delete") message.setInteractiveAuthorizationAllowed(true);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message, 30000), m_context);
    connect(watcher, &QDBusPendingCallWatcher::finished, m_context,
        [this, generation, callback](QDBusPendingCallWatcher *done) {
            const auto reply = done->reply(); done->deleteLater();
            if (generation != m_generation || !busy()) return;
            if (reply.type() == QDBusMessage::ErrorMessage) { complete(reply.errorName()); return; }
            if (m_owner.isEmpty()) m_owner = reply.service();
            callback(reply);
        });
}

bool ProfileEditor::load(const QString &uuid) {
    if (busy() || !QRegularExpression("^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$").match(uuid).hasMatch()) return false;
    m_uuid = uuid; m_path.clear(); m_owner.clear(); m_settings.clear(); begin("load");
    call("/org/freedesktop/NetworkManager/Settings", service + ".Settings", "GetConnectionByUuid", {uuid},
        [this](const QDBusMessage &reply) {
            if (reply.arguments().isEmpty()) { complete("unavailable"); return; }
            m_path = qvariant_cast<QDBusObjectPath>(reply.arguments().first()).path();
            call(m_path, connectionInterface, "GetSettings", {}, [this](const QDBusMessage &result) {
                if (result.arguments().isEmpty()) { complete("unavailable"); return; }
                const auto map = dbusValue<NetworkSettingsMap>(result.arguments().first());
                if (map.value("connection").value("uuid").toString() != m_uuid
                    || !QStringList{"802-11-wireless", "vpn", "wireguard"}.contains(map.value("connection").value("type").toString())) { complete("unavailable"); return; }
                m_settings = present(map); complete();
            });
        });
    return true;
}

bool ProfileEditor::save(const QVariantMap &draft) {
    if (busy() || m_path.isEmpty() || m_settings.isEmpty()) return false;
    begin("save");
    call(m_path, "org.freedesktop.DBus.Properties", "Get", {connectionInterface, QString("VersionId")},
        [this, draft](const QDBusMessage &versionReply) {
        if (versionReply.arguments().isEmpty()) { complete("unavailable"); return; }
        const auto version = versionReply.arguments().first().value<QDBusVariant>().variant().toULongLong();
        if (!version) { complete("unavailable"); return; }
        call(m_path, connectionInterface, "GetSettings", {}, [this, draft, version](const QDBusMessage &reply) {
        if (reply.arguments().isEmpty()) { complete("unavailable"); return; }
        auto map = dbusValue<NetworkSettingsMap>(reply.arguments().first());
        if (map.value("connection").value("uuid").toString() != m_uuid) { complete("unavailable"); return; }
        const auto error = patch(map, m_settings, draft);
        if (!error.isEmpty()) { complete(error); return; }
        call(m_path, connectionInterface, "Update2", {QVariant::fromValue(map), quint32(0x1 | 0x40),
                QVariantMap{{"version-id", QVariant::fromValue(version)}}},
            [this](const QDBusMessage &) { complete(); });
        });
    });
    return true;
}

bool ProfileEditor::forget() {
    if (busy() || m_path.isEmpty() || m_settings.isEmpty()) return false;
    begin("forget");
    call(m_path, connectionInterface, "Delete", {}, [this](const QDBusMessage &) { complete(); });
    return true;
}

void ProfileEditor::cleanup() {
    ++m_generation; m_deadline.stop();
    if (m_context) {
        for (auto *child : m_context->children()) child->disconnect(m_context);
        for (auto *watcher : m_context->findChildren<QDBusServiceWatcher *>())
            watcher->setConnection(QDBusConnection(QString()));
        m_context->deleteLater(); m_context = nullptr;
    }
    m_bus = QDBusConnection(QString());
}
void ProfileEditor::clear() {
    // A user-confirmed write may already be executing in NetworkManager.
    // Keep its acknowledgement alive; hiding the form never starts another call.
    if (busy() && m_operation != "load") { m_clearWhenDone = true; return; }
    cleanup(); m_operation.clear(); m_uuid.clear(); m_path.clear(); m_owner.clear();
    m_settings.clear(); m_error.clear(); emit changed();
}
void ProfileEditor::complete(const QString &error) {
    const auto operation = m_operation;
    cleanup(); m_operation.clear(); m_error = error; emit changed();
    if (m_clearWhenDone) { clear(); return; }
    if (error.isEmpty()) {
        if (operation == "load") emit loaded();
        else if (operation == "save") emit saved();
        else if (operation == "forget") emit removed();
    }
}
