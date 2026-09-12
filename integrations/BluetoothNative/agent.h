#pragma once

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVirtualObject>
#include <QTimer>
#include <functional>

class PairingAgent : public QDBusVirtualObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString devicePath READ devicePath NOTIFY changed)
    Q_PROPERTY(QString phase READ phase NOTIFY changed)
    Q_PROPERTY(QString prompt READ prompt NOTIFY changed)
    Q_PROPERTY(QString code READ code NOTIFY changed)
    Q_PROPERTY(int entered READ entered NOTIFY changed)
    Q_PROPERTY(uint requestId READ requestId NOTIFY changed)
public:
    explicit PairingAgent(QObject *parent = nullptr);
    ~PairingAgent() override;
    bool busy() const { return !m_device.isEmpty(); }
    QString devicePath() const { return m_device; }
    QString phase() const { return m_phase; }
    QString prompt() const { return m_prompt; }
    QString code() const { return m_code; }
    int entered() const { return m_entered; }
    uint requestId() const { return m_requestId; }
    Q_INVOKABLE bool start(const QString &devicePath);
    Q_INVOKABLE bool respond(uint requestId, const QString &value = QString());
    Q_INVOKABLE void cancel();
    QString introspect(const QString &path) const override;
    bool handleMessage(const QDBusMessage &, const QDBusConnection &) override;
signals:
    void changed();
    void finished(const QString &devicePath, const QString &error,
                  const QString &failedPhase, bool paired);
private:
    void call(const QString &path, const QString &interface, const QString &method,
              const QVariantList &args, int timeout,
              std::function<void(const QDBusMessage &)> callback);
    void finish(const QString &error = QString());
    void cleanup(bool abort = true);
    void clearPrompt();
    QDBusConnection m_bus{QString()};
    QString m_connectionName, m_owner, m_device, m_phase, m_prompt, m_code;
    QDBusMessage m_pending;
    QTimer m_deadline;
    uint m_generation = 0, m_requestId = 0;
    int m_entered = 0;
    bool m_registered = false, m_paired = false;
};
