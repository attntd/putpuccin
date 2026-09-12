#include "greetdclient.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QRegularExpression>
#include <cstring>
#include <sys/socket.h>
#include <unistd.h>

namespace { constexpr quint32 maxFrame = 65536; }

// A deployment check must not load an untrusted QML plugin into the root installer.
// This exported marker distinguishes test artifacts without executing their code.
extern "C" Q_DECL_EXPORT const char *quickshell_greeter_build_kind() {
#ifdef GREETER_TESTING
    return "QUICKSHELL_GREETER_TEST_ONLY_PEER";
#else
    return "QUICKSHELL_GREETER_ROOT_PEER_ONLY";
#endif
}

GreetdClient::GreetdClient(QObject *parent) : QObject(parent) {
    m_deadline.setSingleShot(true);
    m_deadline.setInterval(15000);
    connect(&m_deadline, &QTimer::timeout, this, &GreetdClient::fail);
    connect(&m_socket, &QLocalSocket::readyRead, this, &GreetdClient::read);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this] { fail(); });
    connect(&m_socket, &QLocalSocket::disconnected, this, [this] {
        if (!m_launched) fail();
    });
    connect(&m_socket, &QLocalSocket::connected, this, [this] {
        struct ucred peer {};
        socklen_t length = sizeof(peer);
        if (getsockopt(m_socket.socketDescriptor(), SOL_SOCKET, SO_PEERCRED, &peer, &length) != 0) {
            fail(); return;
        }
#ifndef GREETER_TESTING
        if (peer.uid != 0 || geteuid() == 0) { fail(); return; }
#else
        if (peer.uid != geteuid()) { fail(); return; }
#endif
        m_deadline.stop();
        m_connected = true;
        emit changed();
        advance();
    });
    const auto path = qEnvironmentVariable("GREETD_SOCK");
    if (!path.startsWith('/') || path.contains(QChar::Null)) return;
    m_deadline.start();
    m_socket.setReadBufferSize(maxFrame + sizeof(quint32));
    m_socket.connectToServer(path);
}

bool GreetdClient::testBuild() const {
#ifdef GREETER_TESTING
    return true;
#else
    return false;
#endif
}

QString GreetdClient::state() const {
    if (m_launched) return QStringLiteral("launched");
    if (!m_connected) return QStringLiteral("unavailable");
    if (m_request == Start) return QStringLiteral("launching");
    if (m_cancel) return QStringLiteral("cancelling");
    if (m_authenticated) return QStringLiteral("authenticated");
    if (m_active) return QStringLiteral("authenticating");
    return QStringLiteral("idle");
}

void GreetdClient::begin(const QString &user) {
    static const QRegularExpression valid(QStringLiteral("^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}$"));
    if (!m_connected || m_launched || m_request == Start || !valid.match(user).hasMatch()
            || user == "root" || user == "greeter") return;
    m_nextUser = user;
    m_cancel = m_active || m_request != None;
    m_authenticated = false;
    m_response = false;
    emit changed();
    advance();
}

void GreetdClient::cancel() {
    if (m_launched || m_request == Start) return;
    m_nextUser.clear();
    m_cancel = m_active || m_request != None;
    m_authenticated = false;
    m_response = false;
    emit changed();
    advance();
}

void GreetdClient::advance() {
    if (!m_connected || m_request != None || m_launched) return;
    if (m_cancel) {
        send(Cancel, {{"type", "cancel_session"}});
    } else if (!m_nextUser.isEmpty()) {
        m_user = m_nextUser;
        m_nextUser.clear();
        m_active = true;
        send(Create, {{"type", "create_session"}, {"username", m_user}});
    }
}

void GreetdClient::respond(const QString &response) {
    if (!m_connected || m_request != None || !responseRequired() || response.size() > 4096) return;
    m_response = false;
    send(Respond, {{"type", "post_auth_message_response"}, {"response", response}});
}

void GreetdClient::launch() {
    if (!m_connected || !m_authenticated || m_cancel || m_request != None || !m_nextUser.isEmpty()) return;
    // Deliberate allowlist: no command or environment comes from a login field.
    send(Start, {{"type", "start_session"},
        {"cmd", QJsonArray{"/usr/bin/uwsm", "start", "-e", "-D", "Hyprland", "hyprland.desktop"}},
        {"env", QJsonArray{"XDG_SESSION_TYPE=wayland", "XDG_CURRENT_DESKTOP=Hyprland", "XDG_SESSION_DESKTOP=Hyprland"}}});
}

void GreetdClient::send(Request request, const QJsonObject &message) {
    if (!m_connected || m_request != None) { fail(); return; }
    auto data = QJsonDocument(message).toJson(QJsonDocument::Compact);
    const quint32 length = data.size();
    m_request = request;
    m_deadline.start();
    m_socket.write(reinterpret_cast<const char *>(&length), sizeof(length));
    m_socket.write(data);
    // No request or response is logged. Clear the temporary serialized secret.
    data.fill('\0');
    emit changed();
}

void GreetdClient::read() {
    m_input.append(m_socket.readAll());
    if (m_input.size() > maxFrame + qsizetype(sizeof(quint32))) { fail(); return; }
    while (m_input.size() >= qsizetype(sizeof(quint32))) {
        quint32 length;
        std::memcpy(&length, m_input.constData(), sizeof(length));
        if (length == 0 || length > maxFrame) { fail(); return; }
        if (m_input.size() < qsizetype(sizeof(length) + length)) return;
        const auto payload = m_input.mid(sizeof(length), length);
        m_input.remove(0, sizeof(length) + length);
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(payload, &error);
        if (error.error != QJsonParseError::NoError || !document.isObject() || m_request == None) {
            fail(); return;
        }
        reply(document.object());
        if (!m_connected) return;
    }
}

void GreetdClient::reply(const QJsonObject &message) {
    m_deadline.stop();
    const auto request = m_request;
    m_request = None;
    const auto type = message.value("type").toString();
    if (request == Cancel) {
        if (type != "success") { fail(); return; }
        m_active = m_cancel = m_authenticated = m_response = false;
        emit changed();
        advance();
        return;
    }
    // A user switch invalidates every in-flight result, including a late success.
    if (m_cancel) { advance(); return; }
    if (type == "error") {
        m_authenticated = m_response = false;
        const auto kind = message.value("error_type").toString();
        if (kind != "auth_error" && kind != "error") { fail(); return; }
        // End the old PAM worker and wait for its ACK before permitting retry.
        m_cancel = true;
        emit authFailure();
        advance();
    } else if (type == "success") {
        if (request == Start) {
            m_launched = true;
            emit changed();
            emit launched();
        } else if (request == Create || request == Respond) {
            m_authenticated = true;
            m_response = false;
            emit changed();
            emit readyToLaunch();
        } else fail();
    } else if (type == "auth_message" && (request == Create || request == Respond)) {
        const auto style = message.value("auth_message_type").toString();
        const auto text = message.value("auth_message");
        if (!text.isString() || (style != "info" && style != "error" && style != "secret" && style != "visible")) {
            fail(); return;
        }
        m_response = style == "secret" || style == "visible";
        m_echo = style == "visible";
        emit changed();
        emit authMessage(text.toString().left(1024), style == "error", m_response, m_echo);
        if (!m_response && !m_cancel && m_request == None)
            send(Respond, {{"type", "post_auth_message_response"}});
    } else fail();
}

void GreetdClient::fail() {
    const bool wasUsable = m_connected || m_deadline.isActive();
    m_deadline.stop();
    m_connected = m_active = m_response = m_authenticated = m_cancel = false;
    m_nextUser.clear();
    m_input.fill('\0');
    m_input.clear();
    m_request = None;
    m_socket.abort();
    emit changed();
    if (wasUsable) emit transportError();
}
