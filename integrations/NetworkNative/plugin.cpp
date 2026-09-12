#include "editor.h"
#include <QQmlExtensionPlugin>
#include <qqml.h>
class NetworkPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override { qmlRegisterType<ProfileEditor>(uri, 1, 0, "ProfileEditor"); }
};
#include "plugin.moc"
