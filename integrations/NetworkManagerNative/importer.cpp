// libnm is used only for the installed OpenVPN file importer; no NMClient,
// device model, external editor, process, or secret agent is created here.
#include <NetworkManager.h>
#include "importer.h"
#include <QDBusMetaType>
#include <QFile>
#include <QFileInfo>
#include <QHostAddress>
#include <QRegularExpression>
#include <QUuid>
#include <QSet>

using StringMap = QMap<QString, QString>;
static bool keyValid(const QString &key) {
    return QRegularExpression("^[A-Za-z0-9+/]{43}=$").match(key).hasMatch()
        && QByteArray::fromBase64(key.toLatin1()).size() == 32;
}
static QStringList entries(const QString &text) { return text.split(QRegularExpression("[,\\s]+"), Qt::SkipEmptyParts); }

static NetworkSettingsMap wireguard(const QString &path, QString &error) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) { error = "vpn-file"; return {}; }
    const QByteArray bytes = file.read(1024 * 1024 + 1);
    if (bytes.size() > 1024 * 1024 || bytes.contains('\0')) { error = "vpn-file"; return {}; }
    QMap<QString, QString> interface;
    QList<QMap<QString, QString>> peers;
    QMap<QString, QString> *section = nullptr;
    for (const auto &raw : QString::fromUtf8(bytes).split('\n')) {
        const auto line = raw.section('#', 0, 0).trimmed();
        if (line.isEmpty()) continue;
        if (line == "[Interface]") {
            if (!interface.isEmpty() || section) { error = "vpn-config"; return {}; }
            section = &interface; continue;
        }
        if (line == "[Peer]") { peers.append(QMap<QString, QString>{}); section = &peers.last(); continue; }
        const auto equals = line.indexOf('=');
        if (!section || equals <= 0) { error = "vpn-config"; return {}; }
        const auto key = line.left(equals).trimmed(), val = line.mid(equals + 1).trimmed();
        const QStringList supported = section == &interface
            ? QStringList{"PrivateKey", "Address", "DNS", "MTU", "ListenPort", "Table"}
            : QStringList{"PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive"};
        if (!supported.contains(key)) { error = "vpn-unsupported"; return {}; }
        if (section->contains(key)) {
            if (key == "Address" || key == "DNS" || key == "AllowedIPs") (*section)[key] += "," + val;
            else { error = "vpn-config"; return {}; }
        } else (*section)[key] = val;
    }
    if (!keyValid(interface.value("PrivateKey")) || peers.isEmpty() || peers.size() > 128) { error = "vpn-config"; return {}; }
    NetworkSettingsMap map;
    map["connection"] = {{"id", QFileInfo(path).completeBaseName()}, {"type", "wireguard"}, {"autoconnect", false}};
    // Generate a valid, short and unique interface name; the displayed name is independent.
    map["connection"]["interface-name"] = "wg" + QUuid::createUuid().toString(QUuid::WithoutBraces).left(10);
    map["wireguard"] = {{"private-key", interface.value("PrivateKey")}, {"private-key-flags", quint32(0)}, {"peer-routes", true}};
    const auto table = interface.value("Table", "auto");
    if (table == "off") map["wireguard"]["peer-routes"] = false;
    else if (table != "auto") { error = "vpn-unsupported"; return {}; }
    for (const auto &field : {QString("ListenPort"), QString("MTU")}) {
        if (!interface.contains(field)) continue;
        bool ok = false; const auto number = interface.value(field).toUInt(&ok);
        if (!ok || number > 65535 || (field == "MTU" && number < 576)) { error = "vpn-config"; return {}; }
        map["wireguard"][field == "MTU" ? "mtu" : "listen-port"] = quint32(number);
    }
    QList<QVariantMap> ipv4, ipv6, resultPeers;
    for (const auto &entry : entries(interface.value("Address"))) {
        const auto parts = entry.split('/'); const QHostAddress ip(parts.value(0));
        const bool v4 = ip.protocol() == QAbstractSocket::IPv4Protocol;
        bool ok = parts.size() == 1; uint prefix = v4 ? 32 : 128;
        if (parts.size() == 2) prefix = parts[1].toUInt(&ok);
        if (ip.isNull() || ip.isMulticast() || !ok || prefix == 0 || prefix > (v4 ? 32u : 128u)) { error = "vpn-config"; return {}; }
        (v4 ? ipv4 : ipv6).append({{"address", ip.toString()}, {"prefix", quint32(prefix)}});
    }
    if (ipv4.isEmpty() && ipv6.isEmpty()) { error = "vpn-config"; return {}; }
    QStringList dns4, dns6, search;
    for (const auto &entry : entries(interface.value("DNS"))) {
        const QHostAddress ip(entry);
        if (!ip.isNull() && !ip.isMulticast()) (ip.protocol() == QAbstractSocket::IPv4Protocol ? dns4 : dns6).append(ip.toString());
        else if (QRegularExpression("^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$").match(entry).hasMatch()
                 && !QRegularExpression("^[0-9.]+$").match(entry).hasMatch()) search.append(entry);
        else { error = "vpn-config"; return {}; }
    }
    for (const auto &family : {QString("ipv4"), QString("ipv6")}) {
        const auto &addresses = family == "ipv4" ? ipv4 : ipv6;
        const auto &dns = family == "ipv4" ? dns4 : dns6;
        if (addresses.isEmpty() && !dns.isEmpty()) { error = "vpn-config"; return {}; }
        map[family] = {{"method", addresses.isEmpty() ? "disabled" : "manual"}};
        if (!addresses.isEmpty()) {
            map[family]["address-data"] = QVariant::fromValue(addresses);
            map[family]["dns-data"] = dns;
            if (!search.isEmpty()) map[family]["dns-search"] = search;
        }
    }
    QSet<QString> publicKeys;
    for (const auto &peer : peers) {
        const auto pub = peer.value("PublicKey"), psk = peer.value("PresharedKey");
        if (!keyValid(pub) || publicKeys.contains(pub) || (!psk.isEmpty() && !keyValid(psk))) { error = "vpn-config"; return {}; }
        publicKeys.insert(pub);
        QVariantMap result{{"public-key", pub}};
        if (!psk.isEmpty()) { result["preshared-key"] = psk; result["preshared-key-flags"] = quint32(0); }
        QStringList allowed;
        for (const auto &cidr : entries(peer.value("AllowedIPs"))) {
            const auto parts = cidr.split('/'); const QHostAddress ip(parts.value(0));
            bool ok = parts.size() == 1; uint prefix = ip.protocol() == QAbstractSocket::IPv4Protocol ? 32 : 128;
            if (parts.size() == 2) prefix = parts[1].toUInt(&ok);
            if (ip.protocol() == QAbstractSocket::UnknownNetworkLayerProtocol || !ok || prefix > (ip.protocol() == QAbstractSocket::IPv4Protocol ? 32u : 128u)) { error = "vpn-config"; return {}; }
            allowed.append(ip.toString() + '/' + QString::number(prefix));
        }
        if (allowed.isEmpty()) { error = "vpn-config"; return {}; }
        result["allowed-ips"] = allowed;
        if (peer.contains("Endpoint")) {
            const auto endpoint = peer.value("Endpoint");
            const auto match = QRegularExpression("^(\\[[0-9a-fA-F:]+\\]|[A-Za-z0-9_.-]+):([0-9]{1,5})$").match(endpoint);
            if (!match.hasMatch() || match.captured(2).toUInt() == 0 || match.captured(2).toUInt() > 65535) { error = "vpn-config"; return {}; }
            result["endpoint"] = endpoint;
        }
        if (peer.contains("PersistentKeepalive")) {
            bool ok = false; const auto keepalive = peer.value("PersistentKeepalive").toUInt(&ok);
            if (!ok || keepalive > 65535) { error = "vpn-config"; return {}; }
            result["persistent-keepalive"] = quint32(keepalive);
        }
        resultPeers.append(result);
    }
    map["wireguard"]["peers"] = QVariant::fromValue(resultPeers);
    return map;
}

bool openVpnInstalled() {
    bool found = false; GSList *list = nm_vpn_plugin_info_list_load();
    for (auto *item = list; item; item = item->next)
        found |= QString::fromUtf8(nm_vpn_plugin_info_get_service(NM_VPN_PLUGIN_INFO(item->data))) == "org.freedesktop.NetworkManager.openvpn";
    g_slist_free_full(list, g_object_unref); return found;
}

// Public libnm serialization produces these modern settings types. Reject an
// unsupported value rather than silently dropping a VPN option or its routes.
static QVariant fromVariant(GVariant *v, bool &ok) {
    const auto signature = QByteArray(g_variant_get_type_string(v));
    if (signature == "v") { auto *child = g_variant_get_variant(v); auto out = fromVariant(child, ok); g_variant_unref(child); return out; }
    if (signature == "s") return QString::fromUtf8(g_variant_get_string(v, nullptr));
    if (signature == "b") return bool(g_variant_get_boolean(v));
    if (signature == "u") return quint32(g_variant_get_uint32(v));
    if (signature == "i") return qint32(g_variant_get_int32(v));
    if (signature == "t") return quint64(g_variant_get_uint64(v));
    if (signature == "x") return qint64(g_variant_get_int64(v));
    if (signature == "ay") { gsize size; const auto *data = static_cast<const char *>(g_variant_get_fixed_array(v, &size, 1)); return QByteArray(data, size); }
    if (signature == "as") { QStringList list; GVariantIter it; const gchar *text; g_variant_iter_init(&it, v); while (g_variant_iter_next(&it, "&s", &text)) list.append(QString::fromUtf8(text)); return list; }
    if (signature == "a{ss}") { StringMap map; GVariantIter it; const gchar *key, *text; g_variant_iter_init(&it, v); while (g_variant_iter_next(&it, "{&s&s}", &key, &text)) map[QString::fromUtf8(key)] = QString::fromUtf8(text); return QVariant::fromValue(map); }
    if (signature == "a{sv}") { QVariantMap map; GVariantIter it; const gchar *key; GVariant *child; g_variant_iter_init(&it, v); while (g_variant_iter_next(&it, "{&sv}", &key, &child)) { map[QString::fromUtf8(key)] = fromVariant(child, ok); g_variant_unref(child); } return map; }
    if (signature == "aa{sv}") { QList<QVariantMap> list; for (gsize i = 0; i < g_variant_n_children(v); ++i) { auto *child = g_variant_get_child_value(v, i); list.append(fromVariant(child, ok).toMap()); g_variant_unref(child); } return QVariant::fromValue(list); }
    if (signature == "au") { QList<quint32> list; gsize size; const auto *data = static_cast<const guint32 *>(g_variant_get_fixed_array(v, &size, sizeof(guint32))); for (gsize i = 0; i < size; ++i) list.append(data[i]); return QVariant::fromValue(list); }
    if (signature == "aay") { QList<QByteArray> list; for (gsize i = 0; i < g_variant_n_children(v); ++i) { auto *child = g_variant_get_child_value(v, i); list.append(fromVariant(child, ok).toByteArray()); g_variant_unref(child); } return QVariant::fromValue(list); }
    ok = false; return {};
}
NetworkSettingsMap importVpn(const QString &path, const QString &type, QString &error) {
    if (type == "wireguard") return wireguard(path, error);
    if (type != "openvpn") { error = "vpn-config"; return {}; }
    qDBusRegisterMetaType<StringMap>();
    GSList *list = nm_vpn_plugin_info_list_load(); NMConnection *connection = nullptr;
    bool found = false; GError *failure = nullptr;
    for (auto *item = list; item; item = item->next) {
        auto *info = NM_VPN_PLUGIN_INFO(item->data);
        if (QString::fromUtf8(nm_vpn_plugin_info_get_service(info)) != "org.freedesktop.NetworkManager.openvpn") continue;
        found = true;
        auto *plugin = nm_vpn_plugin_info_load_editor_plugin(info, &failure);
        if (plugin) connection = nm_vpn_editor_plugin_import(plugin, QFile::encodeName(path).constData(), &failure);
        break;
    }
    g_slist_free_full(list, g_object_unref);
    if (failure) g_error_free(failure); // Plugin diagnostics can contain credentials: never log them.
    if (!connection) { error = found ? "vpn-config" : "vpn-plugin"; return {}; }
    GVariant *serialized = nm_connection_to_dbus(connection, NM_CONNECTION_SERIALIZE_ALL);
    NetworkSettingsMap map; bool ok = true;
    GVariantIter iter; const gchar *section; GVariant *settings;
    g_variant_iter_init(&iter, serialized);
    while (g_variant_iter_next(&iter, "{&s@a{sv}}", &section, &settings)) {
        map[QString::fromUtf8(section)] = fromVariant(settings, ok).toMap(); g_variant_unref(settings);
    }
    g_variant_unref(serialized); g_object_unref(connection);
    if (!ok) { error = "vpn-unsupported"; return {}; }
    return map;
}
