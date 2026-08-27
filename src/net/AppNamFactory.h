#pragma once
#include <QQmlNetworkAccessManagerFactory>
#include <QString>

// The QML engine builds its own QNetworkAccessManager for whatever an Image or
// XMLHttpRequest fetches, so no module backend's network setup applies to it.
// This gives that manager the two things poster art needs: a disk cache, and the
// same narrow *.plex.direct certificate leniency PlexBackend grants its replies.
class AppNamFactory : public QQmlNetworkAccessManagerFactory {
public:
    explicit AppNamFactory(const QString &dataRoot);
    QNetworkAccessManager *create(QObject *parent) override;

private:
    QString m_cacheDir;
};
