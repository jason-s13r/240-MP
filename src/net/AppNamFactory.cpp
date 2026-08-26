#include "AppNamFactory.h"

#include <QDir>
#include <QNetworkAccessManager>
#include <QNetworkDiskCache>
#include <QNetworkReply>
#include <QSet>
#include <QSslError>

namespace {
// Holds a large library's posters several times over, and is small enough to
// leave alone on an SD card.
constexpr qint64 kMaxCacheBytes = 64LL * 1024 * 1024;
}

AppNamFactory::AppNamFactory(const QString &dataRoot)
    : m_cacheDir(QDir(dataRoot).filePath(QStringLiteral("cache/images"))) {}

QNetworkAccessManager *AppNamFactory::create(QObject *parent) {
    // Called on whichever thread wants a manager, so this only constructs.
    auto *nam = new QNetworkAccessManager(parent);

    auto *cache = new QNetworkDiskCache(nam);
    cache->setCacheDirectory(m_cacheDir);
    cache->setMaximumCacheSize(kMaxCacheBytes);
    nam->setCache(cache);

    QObject::connect(nam, &QNetworkAccessManager::sslErrors, nam,
                     [](QNetworkReply *reply, const QList<QSslError> &errors) {
        // Plex LAN direct addresses only: the *.plex.direct cert is Let's
        // Encrypt-signed but fails on systems with an incomplete CA bundle.
        // Kept deliberately identical to PlexBackend::ignoreSslErrors.
        if (!reply->url().host().endsWith(QStringLiteral(".plex.direct")))
            return;
        static const QSet<QSslError::SslError> kExpected = {
            QSslError::UnableToGetLocalIssuerCertificate,
            QSslError::UnableToVerifyFirstCertificate,
            QSslError::SelfSignedCertificateInChain,
        };
        QList<QSslError> allowed;
        for (const QSslError &e : errors)
            if (kExpected.contains(e.error())) allowed.append(e);
        if (!allowed.isEmpty())
            reply->ignoreSslErrors(allowed);
    });

    return nam;
}
