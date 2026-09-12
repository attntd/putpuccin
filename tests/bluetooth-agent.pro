TEMPLATE = app
CONFIG += console testcase c++17
QT += dbus testlib
QT -= gui
TARGET = bluetooth-agent-test
HEADERS += ../integrations/BluetoothNative/agent.h ../integrations/BluetoothNative/deviceactions.h
SOURCES += bluetooth_agent_test.cpp ../integrations/BluetoothNative/agent.cpp ../integrations/BluetoothNative/deviceactions.cpp
