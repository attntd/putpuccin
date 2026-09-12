#pragma once
#include <QObject>
#include <QVariantMap>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QTimer>
#include <functional>

using NetworkSettingsMap = QMap<QString, QVariantMap>;
Q_DECLARE_METATYPE(NetworkSettingsMap)

class ProfileEditor : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString uuid READ uuid NOTIFY changed)
    Q_PROPERTY(QString operation READ operation NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY changed)
public:
    explicit ProfileEditor(QObject *parent = nullptr);
    ~ProfileEditor() override;
    bool busy() const { return !m_operation.isEmpty(); }
    QString uuid() const { return m_uuid; }
    QString operation() const { return m_operation; }
    QString error() const { return m_error; }
    QVariantMap settings() const { return m_settings; }
    Q_INVOKABLE bool load(const QString &uuid);
    Q_INVOKABLE bool save(const QVariantMap &draft);
    Q_INVOKABLE bool forget();
    Q_INVOKABLE void clear();
signals:
    void changed();
    void loaded();
    void saved();
    void removed();
private:
    void begin(const QString &operation);
    void call(const QString &path, const QString &interface, const QString &method,
              const QVariantList &args, std::function<void(const QDBusMessage &)> callback);
    void complete(const QString &error = {});
    void cleanup();
    static QVariantMap present(const NetworkSettingsMap &settings);
    static QString patch(NetworkSettingsMap &current, const QVariantMap &before, const QVariantMap &draft);
    QDBusConnection m_bus{QString()};
    QObject *m_context = nullptr;
    QTimer m_deadline;
    QString m_uuid, m_path, m_owner, m_operation, m_error;
    QVariantMap m_settings;
    quint64 m_generation = 0;
    bool m_clearWhenDone = false;
};
