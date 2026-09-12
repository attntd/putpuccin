// Private-bus logind double: real FD passing, including observable EOF.
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusUnixFileDescriptor>
#include <QDBusVirtualObject>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSocketNotifier>
#include <QTimer>
#include <functional>
#include <vector>
#include <fcntl.h>
#include <unistd.h>

class Logind : public QDBusVirtualObject {
public:
    explicit Logind(QString directory) : directory(std::move(directory)) { save(); }
    QString introspect(const QString &) const override {
        return QStringLiteral("<interface name=\"org.freedesktop.login1.Manager\">"
            "<method name=\"Inhibit\"><arg type=\"s\" direction=\"in\"/>"
            "<arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/>"
            "<arg type=\"s\" direction=\"in\"/><arg type=\"h\" direction=\"out\"/>"
            "</method></interface>");
    }
    bool handleMessage(const QDBusMessage &message, const QDBusConnection &bus) override {
        if (message.interface() == "org.quickshell.test.Logind") {
            bool ok = false;
            auto connection = bus;
            if (message.member() == "ReleaseName") ok = connection.unregisterService("org.freedesktop.login1");
            if (message.member() == "AcquireName") ok = connection.registerService("org.freedesktop.login1");
            if (message.member() == "FinishPending") {
                auto replies = std::move(waiting);
                waiting.clear();
                for (const auto &reply : replies) reply();
                ok = true;
            }
            bus.send(message.createReply(QVariantList{ok}));
            return true;
        }
        if (message.member() != "Inhibit") return false;
        ++calls;
        QJsonArray args;
        for (const auto &arg : message.arguments()) args.append(arg.toString());
        requests.append(args);
        save();
        QFile file(directory + "/behavior");
        if (!file.open(QIODevice::ReadOnly)) qFatal("Cannot read test behavior");
        const auto behavior = file.readAll().trimmed();
        if (behavior == "fail" || behavior == "missing") {
            bus.send(message.createErrorReply(behavior == "fail"
                ? "org.freedesktop.DBus.Error.AccessDenied" : "org.freedesktop.DBus.Error.ServiceUnknown",
                "Synthetic inhibitor failure"));
        } else if (behavior == "malformed") {
            bus.send(message.createReply(QVariantList{QStringLiteral("not a descriptor")}));
        } else {
            const int delay = behavior == "timeout" ? 4500 : behavior == "slow" ? 250 : 0;
            auto reply = [this, message, bus] {
                int descriptors[2];
                if (pipe2(descriptors, O_CLOEXEC | O_NONBLOCK) != 0) qFatal("pipe2 failed");
                const int id = ++issued;
                active.append(id);
                save();
                const int reader = descriptors[0];
                auto *notifier = new QSocketNotifier(reader, QSocketNotifier::Read, this);
                connect(notifier, &QSocketNotifier::activated, this, [this, notifier, reader, id] {
                    char byte;
                    if (read(reader, &byte, 1) == 0) {
                        notifier->setEnabled(false);
                        notifier->deleteLater();
                        close(reader);
                        for (qsizetype index = 0; index < active.size(); ++index) {
                            if (active[index].toInt() == id) { active.removeAt(index); break; }
                        }
                        released.append(id);
                        save();
                    }
                });
                QDBusUnixFileDescriptor descriptor(descriptors[1]);
                close(descriptors[1]); // QDBusUnixFileDescriptor duplicates its input.
                bus.send(message.createReply(QVariantList{QVariant::fromValue(descriptor)}));
            };
            if (behavior == "held") waiting.push_back(reply);
            else QTimer::singleShot(delay, this, reply);
        }
        return true;
    }
private:
    void save() {
        QSaveFile file(directory + "/leases.json");
        if (!file.open(QIODevice::WriteOnly)) qFatal("Cannot save lease evidence");
        file.write(QJsonDocument(QJsonObject{{"calls", calls}, {"issued", issued},
            {"active", active}, {"released", released}, {"requests", requests}}).toJson());
        if (!file.commit()) qFatal("Cannot commit lease evidence");
    }
    QString directory;
    int calls = 0;
    int issued = 0;
    QJsonArray active, released, requests;
    std::vector<std::function<void()>> waiting;
};

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc != 2) return 2;
    auto bus = QDBusConnection::sessionBus();
    Logind mock(QString::fromLocal8Bit(argv[1]));
    if (!bus.registerVirtualObject("/org/freedesktop/login1", &mock)
        || !bus.registerService("org.freedesktop.login1")
        || !bus.registerService("org.quickshell.test.Logind")) return 3;
    QFile ready(QString::fromLocal8Bit(argv[1]) + "/bus-ready");
    if (!ready.open(QIODevice::WriteOnly)) return 4;
    ready.write("ready");
    ready.close();
    return app.exec();
}
