// Public Qt APIs only. Capture ownership stays with ScreenshotService.
#include <QQmlExtensionPlugin>
#include <QQuickItemGrabResult>
#include <QImageWriter>
#include <QFile>
#include <QFutureWatcher>
#include <QtConcurrent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUuid>
#include <QDeadlineTimer>
#include <QStandardPaths>
#include <atomic>
#include <memory>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
struct Fd {
    int value = -1;
    explicit Fd(int fd = -1) : value(fd) {}
    ~Fd() { if (value >= 0) ::close(value); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};
using Cancellation = std::shared_ptr<std::atomic_bool>;

int openDirectory(const QString &path) {
    if (!path.startsWith('/') || path.contains(QChar::Null)) return -1;
    int fd = ::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (const auto &part : path.split('/', Qt::SkipEmptyParts)) {
        if (part == "." || part == "..") { ::close(fd); return -1; }
        const int next = ::openat(fd, QFile::encodeName(part).constData(),
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        ::close(fd);
        fd = next;
        if (fd < 0) break;
    }
    return fd;
}

class OutputFile : public QFile {
public:
    explicit OutputFile(Cancellation stop) : stopped(std::move(stop)), deadline(10000) {}
protected:
    qint64 writeData(const char *data, qint64 length) override {
        if (stopped->load() || deadline.hasExpired()) return -1;
        return QFile::writeData(data, length);
    }
private:
    Cancellation stopped;
    QDeadlineTimer deadline;
};

bool encode(QImage image, QRect crop, const QString &directory, const Cancellation &stopped) {
    if (stopped->load()) return false;
    const auto name = directory.section('/', -1);
    static const QRegularExpression sessionName("^capture-[0-9a-f]{32}$");
    if (!sessionName.match(name).hasMatch()) return false;
    Fd dir(openDirectory(directory));
    struct stat info {};
    if (dir.value < 0 || fstat(dir.value, &info) || info.st_uid != geteuid()
            || (info.st_mode & 0777) != 0700) return false;
    Fd marker(openat(dir.value, ".session", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK));
    if (marker.value < 0 || fstat(marker.value, &info) || !S_ISREG(info.st_mode)
            || info.st_uid != geteuid() || info.st_nlink != 1 || (info.st_mode & 0777) != 0600
            || flock(marker.value, LOCK_EX | LOCK_NB)) return false;
    char data[4097];
    const auto length = ::read(marker.value, data, sizeof(data));
    const auto metadata = QJsonDocument::fromJson(QByteArray(data, qMax<ssize_t>(0, length))).object();
    if (metadata.value("version").toInt() != 1 || metadata.value("name").toString() != name
            || metadata.value("ownerPid").toInt() != getpid() || stopped->load()) return false;
    // No GUI work, no DPR rounding and no intermediate full-screen PNG.
    image = image.copy(crop);
    image.setDevicePixelRatio(1);
    if (image.isNull() || stopped->load()) return false;
    const auto temporary = QByteArray(".encode-") + QUuid::createUuid().toByteArray(QUuid::Id128) + ".png";
    Fd output(openat(dir.value, temporary.constData(),
                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (output.value < 0) return false;
    bool saved = false;
    {
        OutputFile file(stopped);
        if (file.open(output.value, QIODevice::WriteOnly, QFileDevice::DontCloseHandle)) {
            QImageWriter writer(&file, "png");
            writer.setCompression(1);
            saved = writer.write(image) && file.flush();
        }
    }
    saved = saved && !stopped->load()
        && renameat(dir.value, temporary.constData(), dir.value, "result.png") == 0;
    if (!saved) unlinkat(dir.value, temporary.constData(), 0);
    return saved;
}
}

class ImageExporter : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
public:
    explicit ImageExporter(QObject *parent = nullptr) : QObject(parent) {}
    ~ImageExporter() override { cancel(); }
    bool busy() const { return bool(cancellation); }
    Q_INVOKABLE bool hasEditor() const { return !QStandardPaths::findExecutable("satty").isEmpty(); }
    Q_INVOKABLE void cancel() { if (cancellation) cancellation->store(true); }
    Q_INVOKABLE bool write(QObject *result, const QString &directory, int x, int y, int width, int height, int token) {
        const auto grab = qobject_cast<QQuickItemGrabResult *>(result);
        if (busy() || !grab) return false;
        const auto image = grab->image();
        const QRect rect(x, y, width, height);
        if (image.isNull() || width < 1 || height < 1 || x < 0 || y < 0
                || qint64(x) + width > image.width() || qint64(y) + height > image.height()) return false;
        cancellation = std::make_shared<std::atomic_bool>(false);
        const auto stop = cancellation;
        auto watcher = new QFutureWatcher<bool>(this);
        connect(watcher, &QFutureWatcher<bool>::finished, this, [this, watcher, token, stop] {
            const bool ok = watcher->result();
            cancellation.reset();
            watcher->deleteLater();
            emit busyChanged();
            emit finished(token, ok, stop->load());
        });
        watcher->setFuture(QtConcurrent::run([image, rect, directory, stop] {
            return encode(image, rect, directory, stop);
        }));
        emit busyChanged();
        return true;
    }
signals:
    void busyChanged();
    void finished(int token, bool ok, bool cancelled);
private:
    Cancellation cancellation;
};

class ScreenshotPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override { qmlRegisterType<ImageExporter>(uri, 1, 0, "ImageExporter"); }
};
#include "exporter.moc"
