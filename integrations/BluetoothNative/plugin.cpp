#include "agent.h"
#include "deviceactions.h"
#include <QQmlExtensionPlugin>
#include <qqml.h>

class BluetoothPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override {
        qmlRegisterType<PairingAgent>(uri, 1, 0, "PairingAgent");
        qmlRegisterType<DeviceActions>(uri, 1, 0, "DeviceActions");
    }
};
#include "plugin.moc"
