TEMPLATE = lib
CONFIG += plugin c++17
QT += qml dbus
TARGET = sessioninhibitor
HEADERS += inhibitor.h
SOURCES += inhibitor.cpp plugin.cpp
