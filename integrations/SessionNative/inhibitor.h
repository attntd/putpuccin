#pragma once

#include <QObject>

class InhibitorState;

// Each QML generation has a facade; the application owns the shared lease.
class CaffeinateController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString mode READ mode NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool failed READ failed NOTIFY changed)
public:
    explicit CaffeinateController(QObject *parent = nullptr);
    ~CaffeinateController() override;
    QString mode() const;
    bool busy() const;
    bool failed() const;
    Q_INVOKABLE void setMode(const QString &mode, const QString &reason);
signals:
    void changed();
private:
    InhibitorState *m_state;
};
