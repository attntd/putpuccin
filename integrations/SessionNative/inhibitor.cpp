#include "inhibitor.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDBusUnixFileDescriptor>
#include <QPointer>

class InhibitorState : public QObject {
    Q_OBJECT
public:
    explicit InhibitorState(QObject *parent) : QObject(parent) {
        auto *owner = new QDBusServiceWatcher(QStringLiteral("org.freedesktop.login1"), bus,
            QDBusServiceWatcher::WatchForOwnerChange, this);
        connect(owner, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &previous, const QString &) {
                if (!previous.isEmpty()) disconnected();
            });
        bus.connect(QString(), QStringLiteral("/org/freedesktop/DBus/Local"),
            QStringLiteral("org.freedesktop.DBus.Local"), QStringLiteral("Disconnected"),
            this, SLOT(disconnected()));
    }

    void setMode(const QString &value, const QString &reason) {
        if (value != "off" && value != "background" && value != "presentation"
            && value != "secure-background") return;
        if (value == requested && !failed) return;
        requested = value;
        failed = false;
        if (value == "off") {
            lease = {};
            mode = "off";
        } else if (lease.isValid()) {
            mode = value;
        } else if (!pending) {
            if (!bus.isConnected() || !(bus.connectionCapabilities()
                & QDBusConnection::UnixFileDescriptorPassing)) {
                reset(true);
                return;
            }
            auto message = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.login1"),
                QStringLiteral("/org/freedesktop/login1"),
                QStringLiteral("org.freedesktop.login1.Manager"), QStringLiteral("Inhibit"));
            // Display and auto-lock policy remains in caffeinate-idle. An idle
            // inhibitor would prevent the wanted screen blanking in background.
            message.setArguments({QStringLiteral("sleep"), QStringLiteral("Quickshell Caffeinate"),
                reason, QStringLiteral("block")});
            pending = new QDBusPendingCallWatcher(bus.asyncCall(message, 3000), this);
            connect(pending, &QDBusPendingCallWatcher::finished, this,
                [this](QDBusPendingCallWatcher *call) {
                    QDBusPendingReply<QDBusUnixFileDescriptor> reply = *call;
                    pending = nullptr;
                    call->deleteLater();
                    if (requested != "off") {
                        if (reply.isError() || !reply.value().isValid()) {
                            requested = "off";
                            failed = true;
                        } else {
                            lease = reply.value();
                            mode = requested;
                        }
                    }
                    // Discarded replies own their FD and close it on destruction.
                    emit changed();
                });
        }
        emit changed();
    }

    void reset(bool error = false) {
        // Deleting the last pending-call reference cancels local delivery;
        // Qt closes descriptors in a late reply without reviving this state.
        delete pending;
        pending = nullptr;
        lease = {};
        requested = mode = QStringLiteral("off");
        failed = error;
        emit changed();
    }

    QString mode = QStringLiteral("off");
    QString requested = QStringLiteral("off");
    bool failed = false;
    int clients = 0;
    QDBusPendingCallWatcher *pending = nullptr;
signals:
    void changed();
private slots:
    void disconnected() {
        // Owner loss and bus disconnect may both arrive for the same outage.
        // Keep the error until a user action, even after the first reset.
        reset(failed || mode != "off" || requested != "off");
    }
private:
    QDBusConnection bus = QDBusConnection::systemBus();
    QDBusUnixFileDescriptor lease;
};

CaffeinateController::CaffeinateController(QObject *parent) : QObject(parent) {
    static QPointer<InhibitorState> shared;
    if (!shared) shared = new InhibitorState(QCoreApplication::instance());
    m_state = shared;
    ++m_state->clients;
    connect(m_state, &InhibitorState::changed, this, &CaffeinateController::changed);
}

CaffeinateController::~CaffeinateController() {
    // Quickshell creates the next generation before destroying the previous
    // one, including hard reloads. Removing the service releases the lease.
    disconnect(m_state, nullptr, this, nullptr);
    if (--m_state->clients == 0) m_state->reset();
}

QString CaffeinateController::mode() const { return m_state->mode; }
bool CaffeinateController::busy() const { return m_state->pending != nullptr; }
bool CaffeinateController::failed() const { return m_state->failed; }
void CaffeinateController::setMode(const QString &mode, const QString &reason) {
    m_state->setMode(mode, reason);
}

#include "inhibitor.moc"
