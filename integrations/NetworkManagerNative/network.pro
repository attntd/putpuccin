QT += qml dbus network
CONFIG += plugin c++17 link_pkgconfig
PKGCONFIG += libnm
TEMPLATE = lib
TARGET = networkmanager
HEADERS += editor.h vpn.h importer.h
SOURCES += editor.cpp vpn.cpp importer.cpp plugin.cpp
