#pragma once
#include "editor.h"
#include <QDBusObjectPath>
#include <QDBusServiceWatcher>
#include <QUrl>
#include <QSet>

// QuickShell owns the device/radio model. This adapter only supplies the VPN
// profiles and active VPN connections missing from Quickshell.Networking.
class VpnProfiles : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY changed)
    Q_PROPERTY(QVariantMap preview READ preview NOTIFY changed)
    Q_PROPERTY(bool openVpnAvailable READ openVpnAvailable NOTIFY changed)
public:
    explicit VpnProfiles(QObject *parent = nullptr);
    ~VpnProfiles() override;
    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);
    bool loading() const { return m_loading; }
    bool busy() const { return !m_operation.isEmpty(); }
    QString error() const { return m_error; }
    QVariantList profiles() const;
    QVariantMap preview() const { return m_preview; }
    bool openVpnAvailable() const { return m_openVpnAvailable; }
    Q_INVOKABLE void refresh();
    Q_INVOKABLE bool prepareImport(const QUrl &file, const QString &type);
    Q_INVOKABLE void cancelImport();
    Q_INVOKABLE bool add(const QString &name);
    Q_INVOKABLE bool toggle(const QString &uuid);
    Q_INVOKABLE void clearError();
signals:
    void changed();
    void added();
private slots:
    void connectionAdded(const QDBusObjectPath &path);
    void connectionRemoved(const QDBusObjectPath &path);
    void connectionUpdated(const QDBusMessage &message);
    void propertiesChanged(const QString &interface, const QVariantMap &properties,
                           const QStringList &invalidated, const QDBusMessage &message);
private:
    void watch();
    void unwatch();
    void readProfile(const QString &path);
    void readActive();
    void finish(const QString &error = {});
    void call(const QString &path, const QString &interface, const QString &method, const QVariantList &args,
              std::function<void(const QDBusMessage &)> callback, bool mutation = false);
    QDBusConnection m_bus{QString()};
    QObject *m_context = nullptr;
    QDBusServiceWatcher *m_ownerWatcher = nullptr;
    QTimer m_deadline;
    QMap<QString, QVariantMap> m_profiles, m_active;
    QMap<QString, quint64> m_profileRevisions;
    QSet<QString> m_disconnecting;
    NetworkSettingsMap m_import;
    QVariantMap m_preview;
    QString m_owner, m_error, m_operation;
    quint64 m_generation = 0, m_activeRevision = 0, m_actionRevision = 0;
    bool m_enabled = false, m_loading = false, m_openVpnAvailable = false;
};
