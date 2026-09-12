#pragma once

#include <QDBusConnection>
#include <QObject>
#include <QTimer>

// Commands only. Quickshell.Bluetooth owns all adapter/device state.
class DeviceActions : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString devicePath READ devicePath NOTIFY changed)
    Q_PROPERTY(QString operation READ operation NOTIFY changed)
public:
    explicit DeviceActions(QObject *parent = nullptr);
    ~DeviceActions() override;
    bool busy() const { return m_context != nullptr; }
    QString devicePath() const { return m_device; }
    QString operation() const { return m_operation; }
    Q_INVOKABLE bool start(const QString &operation, const QString &path,
                           const QString &value = QString());
signals:
    void changed();
    void finished(const QString &path, const QString &operation, const QString &error);
private:
    void finish(const QString &error = QString());
    void cleanup(bool abort);
    QDBusConnection m_bus{QString()};
    QObject *m_context = nullptr;
    QTimer m_deadline;
    QString m_device, m_operation, m_owner;
    bool m_dispatched = false;
    uint m_generation = 0;
};
