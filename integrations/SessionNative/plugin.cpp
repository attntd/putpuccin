#include "inhibitor.h"
#include <QQmlExtensionPlugin>
#include <qqml.h>

class SessionPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override {
        qmlRegisterType<CaffeinateController>(uri, 1, 0, "CaffeinateController");
    }
};
#include "plugin.moc"
