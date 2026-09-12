TEMPLATE = lib
CONFIG += plugin c++17
QT += qml dbus
TARGET = bluetoothagent
HEADERS += agent.h deviceactions.h
SOURCES += agent.cpp deviceactions.cpp plugin.cpp
