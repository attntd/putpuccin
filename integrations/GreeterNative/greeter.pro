TEMPLATE = lib
CONFIG += plugin c++17
QT += qml network
TARGET = greetdclient
HEADERS += greetdclient.h
SOURCES += greetdclient.cpp plugin.cpp
contains(CONFIG, greeter_test) { DEFINES += GREETER_TESTING }
