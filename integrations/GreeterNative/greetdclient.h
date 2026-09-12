#pragma once
#include <QObject>
#include <QLocalSocket>
#include <QJsonObject>
#include <QTimer>

// Transport only. greetd owns PAM, account policy and the authenticated session.
class GreetdClient : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool connected READ connected NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool responseRequired READ responseRequired NOTIFY changed)
    Q_PROPERTY(bool echoResponse READ echoResponse NOTIFY changed)
    Q_PROPERTY(QString user READ user NOTIFY changed)
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(bool testBuild READ testBuild CONSTANT)
public:
    explicit GreetdClient(QObject *parent = nullptr);
    bool connected() const { return m_connected; }
    bool busy() const { return m_request != None || m_cancel || m_authenticated; }
    bool responseRequired() const { return m_response && !m_cancel; }
    bool echoResponse() const { return m_echo; }
    QString user() const { return m_user; }
    QString state() const;
    bool testBuild() const;
    Q_INVOKABLE void begin(const QString &user);
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void respond(const QString &response);
    Q_INVOKABLE void launch();
signals:
    void changed();
    void authMessage(QString message, bool error, bool responseRequired, bool echoResponse);
    void authFailure();
    void readyToLaunch();
    void launched();
    void transportError();
private:
    enum Request { None, Create, Respond, Cancel, Start };
    QLocalSocket m_socket;
    QTimer m_deadline;
    QByteArray m_input;
    Request m_request = None;
    bool m_connected = false, m_active = false, m_cancel = false;
    bool m_response = false, m_echo = false, m_authenticated = false, m_launched = false;
    QString m_user, m_nextUser;
    void advance();
    void send(Request request, const QJsonObject &message);
    void read();
    void reply(const QJsonObject &message);
    void fail();
};
