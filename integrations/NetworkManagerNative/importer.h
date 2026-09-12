#pragma once
#include "editor.h"
bool openVpnInstalled();
NetworkSettingsMap importVpn(const QString &path, const QString &type, QString &error);
