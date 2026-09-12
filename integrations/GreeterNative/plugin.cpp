#include "greetdclient.h"
#include <QQmlExtensionPlugin>
#include <qqml.h>

class GreeterPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override {
        qmlRegisterType<GreetdClient>(uri, 1, 0, "GreetdClient");
    }
};
#include "plugin.moc"
