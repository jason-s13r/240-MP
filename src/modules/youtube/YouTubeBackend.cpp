#include "YouTubeBackend.h"
#include "../../util/YtDlpLocator.h"

#include <QDateTime>
#include <QTimeZone>
#include <QDebug>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QRegularExpression>
#include <QTimer>
#include <QUrl>
#include <QXmlStreamReader>

#include <algorithm>
#include <utility>

static const char *kSubscriptionsFileName = "youtube_subscriptions.txt";
static const char *kPlaylistsFileName     = "youtube_playlists.txt";

static QString watchUrlFor(const QString &videoId) {
    return QStringLiteral("https://www.youtube.com/watch?v=") + videoId;
}

YouTubeBackend::YouTubeBackend(const QString &appRoot, const QString &dataRoot, QObject *parent)
    : QObject(parent), m_appRoot(appRoot), m_dataRoot(dataRoot)
{
    // Read up front rather than on first use: video_duration_text() and
    // channel_art_url() are called from QML bindings, which are const, and both
    // files are a few tens of KB. Loading them here is also what lets a poster
    // grid drawn before any list has loaded still have its artwork.
    loadVideoMetaCache();
    loadChannelArtCache();
    m_history = readHistoryFile();
}

// ---------------------------------------------------------------------------
// Subscriptions file
// ---------------------------------------------------------------------------

QStringList YouTubeBackend::readSubscriptionIds(QString *error) const {
    const QString path = m_dataRoot + "/" + kSubscriptionsFileName;
    if (!QFile::exists(path)) {
        if (error)
            *error = QStringLiteral("NO SUBSCRIPTIONS FILE FOUND\n"
                                    "CREATE YOUTUBE_SUBSCRIPTIONS.TXT IN THE DATA DIRECTORY\n"
                                    "WITH ONE CHANNEL ID PER LINE");
        return {};
    }
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        if (error)
            *error = QStringLiteral("COULD NOT READ YOUTUBE_SUBSCRIPTIONS.TXT");
        return {};
    }
    QStringList ids;
    while (!f.atEnd()) {
        QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith('#'))
            continue;
        // Be lenient with pasted channel URLs: take the segment after "channel/".
        const int slash = line.indexOf(QLatin1String("channel/"));
        if (slash >= 0) {
            line = line.mid(slash + 8);
            const int end = line.indexOf(QRegularExpression(QStringLiteral("[/?#]")));
            if (end >= 0)
                line = line.left(end);
        }
        if (!line.isEmpty() && !ids.contains(line))
            ids << line;
    }
    if (ids.isEmpty() && error)
        *error = QStringLiteral("NO CHANNELS FOUND IN YOUTUBE_SUBSCRIPTIONS.TXT");
    return ids;
}

QVariantMap YouTubeBackend::check_subscriptions() {
    QString error;
    const QStringList ids = readSubscriptionIds(&error);
    QVariantMap result;
    result["ok"]           = error.isEmpty();
    result["error"]        = error;
    result["fileExists"]   = QFile::exists(m_dataRoot + "/" + kSubscriptionsFileName);
    result["channelCount"] = ids.size();
    return result;
}

// ---------------------------------------------------------------------------
// Loaders — all route through one cache-fill path so a single in-flight
// refresh can serve every waiting view.
// ---------------------------------------------------------------------------

void YouTubeBackend::load_subscriptions_feed(bool forceRefresh) {
    m_emitFeedWhenDone = true;
    ensureFresh(forceRefresh);
}

void YouTubeBackend::load_channels(bool forceRefresh) {
    m_emitChannelsWhenDone = true;
    ensureFresh(forceRefresh);
}

void YouTubeBackend::load_channel_videos(const QString &channelId, bool forceRefresh) {
    m_emitChannelVideosWhenDone = channelId;
    ensureFresh(forceRefresh);
}

void YouTubeBackend::ensureFresh(bool forceRefresh) {
    if (m_pendingChannels > 0)
        return; // refresh already in flight — the emit flags queue on it

    loadFeedCache();

    QString error;
    const QStringList ids = readSubscriptionIds(&error);
    if (ids.isEmpty()) {
        m_emitFeedWhenDone     = false;
        m_emitChannelsWhenDone = false;
        m_emitChannelVideosWhenDone.clear();
        emit errorOccurred(error);
        return;
    }
    m_channelOrder = ids;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    // An explicit refresh is the user overruling both kinds of backoff: they
    // are looking at the screen and have asked for it now.
    if (forceRefresh) {
        m_networkPausedUntilMs = 0;
        for (const QString &id : ids)
            m_channels[id].retryAfterMs = 0;
    }

    // Told to leave the host alone: serve whatever is cached and ask for
    // nothing. Without this every entry into the module during a throttle
    // window is another burst, which is what extends the window.
    if (now < m_networkPausedUntilMs) {
        for (const QString &id : ids)
            m_channels[id].channelId = id;
        finishAggregate();
        return;
    }

    QStringList stale;
    for (const QString &id : ids) {
        ChannelEntry &entry = m_channels[id];
        entry.channelId = id;
        if (now < entry.retryAfterMs)
            continue; // failed recently — its turn comes round again later
        if (forceRefresh || !entry.hasVideos() || now - entry.fetchedMs > kCacheTtlMs)
            stale << id;
    }

    if (stale.isEmpty()) {
        finishAggregate(); // everything fresh — serve from cache
        return;
    }
    m_pendingChannels = stale.size();
    m_passSize        = stale.size();
    m_passFailures    = 0;
    m_feedQueue       = stale;
    dispatchFeedFetches();
}

void YouTubeBackend::dispatchFeedFetches() {
    while (m_activeFeedFetches < kMaxConcurrentFeedFetches && !m_feedQueue.isEmpty()) {
        ++m_activeFeedFetches;
        refreshChannel(m_feedQueue.takeFirst());
    }
}

// A feed that did not answer. The channel is left alone for longer each time,
// and a pass that mostly fails is read as the host refusing this address rather
// than thirteen channels going wrong at once — everything stops asking then,
// because continuing to ask is what keeps the refusal in place.
void YouTubeBackend::noteFeedFailure(ChannelEntry &entry) {
    ++entry.failures;
    entry.retryAfterMs = QDateTime::currentMSecsSinceEpoch()
                       + std::min(qint64(entry.failures) * kFeedRetryBackoffMs,
                                  kMaxFeedRetryBackoffMs);
    ++m_passFailures;
}

// ---------------------------------------------------------------------------
// Per-channel fetch: the official RSS feed
// ---------------------------------------------------------------------------

QNetworkRequest YouTubeBackend::makeRequest(const QUrl &url) const {
    QNetworkRequest req(url);
    req.setTransferTimeout(10000);
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QStringLiteral("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                                 "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    return req;
}

// Atom feed → channel name + video maps (newest first, as served).
// Partial parses are kept: only a parse error with zero entries counts as failure.
static bool parseRssFeed(const QByteArray &data, const QString &channelId,
                         QString *channelName, QVariantList *videos,
                         QHash<QString, QString> *descriptions) {
    static const QLatin1String kAtomNs("http://www.w3.org/2005/Atom");
    static const QLatin1String kMediaNs("http://search.yahoo.com/mrss/");
    QXmlStreamReader xml(data);
    bool inEntry = false;
    QString videoId, title, altLink, description;
    QDateTime published;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const auto name = xml.name();
            if (name == QLatin1String("entry")) {
                inEntry = true;
                videoId.clear();
                title.clear();
                altLink.clear();
                description.clear();
                published = QDateTime();
            } else if (!inEntry && name == QLatin1String("title") && channelName->isEmpty()) {
                *channelName = xml.readElementText();
            } else if (inEntry && name == QLatin1String("videoId")) {
                videoId = xml.readElementText();
            } else if (inEntry && title.isEmpty() && name == QLatin1String("title")
                       && xml.namespaceUri() == kAtomNs) {
                // namespace check keeps <media:title> (inside media:group) out
                title = xml.readElementText();
            } else if (inEntry && name == QLatin1String("description")
                       && xml.namespaceUri() == kMediaNs) {
                // <media:description>, inside <media:group> â the video's own
                // description, in full. Free with a list every channel view
                // already fetches, so the info screen opens with its text
                // already in hand rather than waiting on a yt-dlp run.
                description = xml.readElementText();
            } else if (inEntry && name == QLatin1String("published")) {
                published = QDateTime::fromString(xml.readElementText(), Qt::ISODate);
            } else if (inEntry && name == QLatin1String("link")
                       && xml.attributes().value(QLatin1String("rel")) == QLatin1String("alternate")) {
                // Shorts expose a /shorts/<id> alternate href; normal uploads use /watch?v=<id>
                altLink = xml.attributes().value(QLatin1String("href")).toString();
            }
        } else if (xml.isEndElement() && xml.name() == QLatin1String("entry")) {
            inEntry = false;
            if (videoId.isEmpty())
                continue;
            QVariantMap v;
            v["videoId"]     = videoId;
            v["title"]       = title;
            v["channelId"]   = channelId;
            v["channelName"] = QString(); // filled in once the feed title is known
            v["publishedAt"] = published.isValid() ? published.toUTC().toString(Qt::ISODate)
                                                   : QString();
            v["publishedMs"] = published.isValid() ? published.toMSecsSinceEpoch() : qint64(0);
            v["url"]         = watchUrlFor(videoId);
            v["isShort"]     = altLink.contains(QLatin1String("/shorts/"));
            videos->append(v);
            // Kept out of the video map deliberately: these are written to the
            // feed cache, and a description per entry would multiply that file
            // for a fact only one screen ever reads. It goes to the detail
            // cache instead, which is capped and loaded on demand.
            if (!description.isEmpty())
                descriptions->insert(videoId, description);
        }
    }
    return !(xml.hasError() && videos->isEmpty());
}

void YouTubeBackend::refreshChannel(const QString &channelId) {
    QUrl rssUrl(QStringLiteral("https://www.youtube.com/feeds/videos.xml"));
    rssUrl.setQuery(QStringLiteral("channel_id=") + channelId);
    QNetworkReply *reply = m_nam.get(makeRequest(rssUrl));
    connect(reply, &QNetworkReply::finished, this, [this, reply, channelId]() {
        reply->deleteLater();
        ChannelEntry &e = m_channels[channelId];
        bool ok = false;
        if (reply->error() == QNetworkReply::NoError) {
            QString name;
            QVariantList videos;
            QHash<QString, QString> descriptions;
            if (parseRssFeed(reply->readAll(), channelId, &name, &videos, &descriptions)) {
                for (QVariant &v : videos) {
                    QVariantMap m = v.toMap();
                    m["channelName"] = name;
                    v = m;
                }
                ok            = true;
                e.channelName = name;
                e.videos      = videos;
                e.feedOk      = true;
                e.fromProbe   = false;
                e.failures    = 0;
                e.retryAfterMs = 0;
                e.fetchedMs   = QDateTime::currentMSecsSinceEpoch();
                m_feedCacheDirty = true;
                // The feed is where publish dates come from, and the only place
                // — noting them here is what lets Watch Later and History, which
                // store neither, still say how old a video is.
                for (const QVariant &v : std::as_const(videos)) {
                    const QVariantMap m = v.toMap();
                    noteVideoMeta(m.value(QStringLiteral("videoId")).toString(), 0,
                                  m.value(QStringLiteral("publishedMs")).toLongLong());
                }
                // Held whether or not an info screen was ever opened — the
                // point is that the first one opens with its text there. Memory
                // only: the disk cache is read on demand and merges around
                // these (see loadVideoDetailCache).
                for (auto it = descriptions.cbegin(); it != descriptions.cend(); ++it)
                    noteVideoDescription(it.key(), it.value());
            }
        }
        // On failure: keep any previously cached videos (stale beats empty) and
        // stand back from this channel for a while rather than asking again on
        // the next entry into the module.
        if (!ok)
            noteFeedFailure(e);

        --m_activeFeedFetches;
        dispatchFeedFetches();
        if (--m_pendingChannels <= 0) {
            m_pendingChannels = 0;
            finishAggregate();
        }
    });
}

void YouTubeBackend::finishAggregate() {
    const bool    feedWanted     = m_emitFeedWhenDone;
    const bool    channelsWanted = m_emitChannelsWhenDone;
    const QString videosWanted   = m_emitChannelVideosWhenDone;
    m_emitFeedWhenDone     = false;
    m_emitChannelsWhenDone = false;
    m_emitChannelVideosWhenDone.clear();

    const qint64 now = QDateTime::currentMSecsSinceEpoch();

    // Most of a pass failing at once is not thirteen channels going wrong
    // together — it is the one host they all come from refusing this address,
    // which it does by 404ing every feed, its own channel included. Asking
    // again is what keeps that in place, so the module stops for a while.
    if (m_passFailures > 0)
        qWarning("[YouTube] %d of %d feeds failed", m_passFailures, m_passSize);
    bool pauseJustSet = false;
    if (m_passFailures >= kThrottleFailureCount && m_passFailures * 2 >= m_passSize) {
        m_networkPausedUntilMs = now + kThrottlePauseMs;
        pauseJustSet = true;
        qWarning("[YouTube] host is refusing this address — no feed requests for %lld min",
                 kThrottlePauseMs / 60000);
    }
    const bool paused = now < m_networkPausedUntilMs;
    m_passSize     = 0;
    m_passFailures = 0;

    // The pause goes in the same file, so it is written whether or not any feed
    // came back with something new to keep.
    if (m_feedCacheDirty || pauseJustSet) {
        saveFeedCache();
        m_feedCacheDirty = false;
    }

    // Anything to draw, from either source and from any run: last run's cached
    // feeds count, and so does a channel a probe filled in.
    bool anyData = false;
    for (const QString &id : m_channelOrder)
        anyData = anyData || m_channels.value(id).hasVideos();
    if (!anyData) {
        // The request stays standing rather than being answered with nothing:
        // a probe may still fill these in, and it calls back here when it does.
        m_emitFeedWhenDone          = feedWanted;
        m_emitChannelsWhenDone      = channelsWanted;
        m_emitChannelVideosWhenDone = videosWanted;
        // A probe asks the same host by a different road (yt-dlp's own API
        // calls, which the feed refusal does not cover), and it is the only
        // chance of putting anything on screen when the feeds have given
        // nothing at all — so it runs even while the feeds are paused.
        ensureChannelProbes(m_channelOrder);
        emit errorOccurred(paused
            ? QStringLiteral("YOUTUBE IS REFUSING REQUESTS FROM THIS DEVICE\n"
                             "IT USUALLY CLEARS IN A FEW MINUTES")
            : QStringLiteral("COULD NOT LOAD SUBSCRIPTIONS\n"
                             "CHECK YOUR NETWORK CONNECTION"));
        return;
    }

    // Enrichment hits the same host, so it is queued after the signals below:
    // the list a view waits on is never held behind a yt-dlp run. One queue for
    // both facts, because one process answers both.
    if (!paused) {
        if (feedWanted || channelsWanted)
            ensureChannelProbes(m_channelOrder);
        else if (!videosWanted.isEmpty())
            ensureChannelProbes({ videosWanted });
    }

    if (feedWanted)
        emit subscriptionsFeedLoaded(buildFeed());
    if (channelsWanted)
        emit channelsLoaded(buildChannelList());
    if (!videosWanted.isEmpty()) {
        const ChannelEntry entry = m_channels.value(videosWanted);
        if (entry.hasVideos())
            emit channelVideosLoaded(videosWanted, entry.videos);
        else
            emit errorOccurred(QStringLiteral("COULD NOT LOAD CHANNEL FEED"));
    }
}

QVariantList YouTubeBackend::buildFeed() const {
    QVariantList all;
    for (const QString &id : m_channelOrder)
        all += m_channels.value(id).videos;
    std::sort(all.begin(), all.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("publishedMs").toLongLong()
             > b.toMap().value("publishedMs").toLongLong();
    });
    return all.mid(0, kMaxFeedItems);
}

QVariantList YouTubeBackend::buildChannelList() const {
    QVariantList channels;
    for (const QString &id : m_channelOrder) {
        const ChannelEntry entry = m_channels.value(id);
        QVariantMap c;
        // Fall back to the raw ID so a channel whose feed failed is still visible
        c["channelId"]  = id;
        c["title"]      = entry.channelName.isEmpty() ? id : entry.channelName;
        c["videoCount"] = entry.videos.size();
        channels << c;
    }
    std::sort(channels.begin(), channels.end(), [](const QVariant &a, const QVariant &b) {
        return QString::compare(a.toMap().value("title").toString(),
                                b.toMap().value("title").toString(),
                                Qt::CaseInsensitive) < 0;
    });
    return channels;
}

// ---------------------------------------------------------------------------
// Video duration and publish date
//
// An RSS feed carries no duration, so it comes from the channel's uploads
// playlist (UU<id>) with one yt-dlp --flat-playlist per channel, covering that
// channel's whole feed at once. It runs behind a list already on screen, and
// videoMetaLoaded fills the runtimes in as they land; a duration never changes,
// so a channel is probed once per new upload rather than once per session.
//
// Publish dates come the other way, off the feed, and share the file: Watch
// Later and History store neither.
// ---------------------------------------------------------------------------

// mqdefault is the 320x180 frame: the only stock size that is 16:9 without the
// letterbox bars hqdefault pads a 4:3 frame with, and one YouTube generates for
// every upload — maxresdefault is not always there to fall back from.
QString YouTubeBackend::video_thumb_url(const QString &videoId) const {
    if (videoId.isEmpty())
        return {};
    return QStringLiteral("https://i.ytimg.com/vi/%1/mqdefault.jpg").arg(videoId);
}

QString YouTubeBackend::video_duration_text(const QString &videoId) const {
    const int secs = m_videoMeta.value(videoId).duration;
    if (secs <= 0)
        return {};
    const int h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60;
    return h > 0 ? QStringLiteral("%1:%2:%3").arg(h)
                       .arg(m, 2, 10, QLatin1Char('0')).arg(s, 2, 10, QLatin1Char('0'))
                 : QStringLiteral("%1:%2").arg(m).arg(s, 2, 10, QLatin1Char('0'));
}

// Where the bar under a thumbnail stops. A position with no runtime behind it
// is not a fraction of anything, so it draws nothing rather than guessing;
// durations land behind the lists, and videoMetaLoaded re-runs the binding.
qreal YouTubeBackend::video_progress(const QString &videoId) const {
    const int posMs = m_history.value(videoId).toMap().value("pos").toInt();
    if (posMs <= 0)
        return 0.0;
    const int secs = m_videoMeta.value(videoId).duration;
    if (secs <= 0)
        return 0.0;
    return qMin(1.0, posMs / 1000.0 / secs);
}

// Coarsest unit that fits, the shape YouTube itself states an age in. Worked
// out on the spot: a list is read in a sitting, and nothing on screen is worth
// a per-minute repaint.
QString YouTubeBackend::video_age_text(const QString &videoId) const {
    return age_text(m_videoMeta.value(videoId).publishedMs);
}

QString YouTubeBackend::age_text(qint64 ms) const {
    if (ms <= 0)
        return {};
    const qint64 secs = (QDateTime::currentMSecsSinceEpoch() - ms) / 1000;
    if (secs < 60)
        return QStringLiteral("JUST NOW");
    struct Unit { qint64 limit; qint64 div; const char *name; };
    static const Unit kUnits[] = {
        {     3600,      60, "MINUTE" },
        {    86400,    3600, "HOUR"   },
        {   604800,   86400, "DAY"    },
        {  2629800,  604800, "WEEK"   },
        { 31557600, 2629800, "MONTH"  },
    };
    const auto stated = [](qint64 n, const char *name) {
        return QString::number(n) + QLatin1Char(' ') + QLatin1String(name)
             + (n == 1 ? QString() : QStringLiteral("S")) + QStringLiteral(" AGO");
    };
    for (const Unit &u : kUnits) {
        if (secs < u.limit)
            return stated(secs / u.div, u.name);
    }
    return stated(secs / 31557600, "YEAR");
}

QString YouTubeBackend::videoMetaFilePath() const {
    return m_dataRoot + "/youtube_video_meta.json";
}

void YouTubeBackend::loadVideoMetaCache() {
    QFile file(videoMetaFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return;
    const QJsonObject obj = QJsonDocument::fromJson(file.readAll()).object();
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        const QJsonObject entry = it.value().toObject();
        VideoMeta meta;
        meta.duration    = entry.value("d").toInt();
        meta.publishedMs = qint64(entry.value("p").toDouble());
        meta.asked       = entry.value("a").toBool();
        m_videoMeta.insert(it.key(), meta);
    }
}

void YouTubeBackend::saveVideoMetaCache() const {
    // Over the cap, the oldest-published go first: they are the ones furthest
    // down a feed nobody is going to scroll back to.
    QStringList ids = m_videoMeta.keys();
    if (ids.size() > kMaxVideoMetaItems) {
        std::sort(ids.begin(), ids.end(), [this](const QString &a, const QString &b) {
            return m_videoMeta.value(a).publishedMs > m_videoMeta.value(b).publishedMs;
        });
        ids = ids.mid(0, kMaxVideoMetaItems);
    }
    QJsonObject obj;
    for (const QString &id : std::as_const(ids)) {
        const VideoMeta meta = m_videoMeta.value(id);
        QJsonObject entry;
        if (meta.duration > 0)    entry["d"] = meta.duration;
        if (meta.publishedMs > 0) entry["p"] = double(meta.publishedMs);
        if (meta.asked)           entry["a"] = true;
        if (!entry.isEmpty())
            obj[id] = entry;
    }
    QFile file(videoMetaFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

// Merges rather than replaces: the duration comes from yt-dlp and the date from
// RSS, so whichever arrives second must not blank what the first one left.
void YouTubeBackend::noteVideoMeta(const QString &videoId, int duration, qint64 publishedMs) {
    if (videoId.isEmpty())
        return;
    VideoMeta &meta = m_videoMeta[videoId];
    if (duration > 0 && meta.duration != duration) {
        meta.duration    = duration;
        m_videoMetaDirty = true;
    }
    if (publishedMs > 0 && meta.publishedMs != publishedMs) {
        meta.publishedMs = publishedMs;
        m_videoMetaDirty = true;
    }
}

// ---------------------------------------------------------------------------
// Video detail (youtube_video_detail.json)
//
// What the info screen shows that a list row cannot: the description, the view
// count, and — for the lists carrying no channel ID — which channel it is from.
//
// Channel feeds carry descriptions in full and are fetched for the lists anyway;
// anything else is one yt-dlp run over the watch page, which is also the only
// source for the counts. The screen is served what is held either way and then
// updated, so it is never blank while a subprocess runs.
// ---------------------------------------------------------------------------

// "1.2M", "27K", "834" — how the site itself states a count, so the line reads
// the way the number is remembered rather than as seven digits.
static QString countText(qint64 n) {
    struct Unit { qint64 div; const char *suffix; };
    static const Unit kUnits[] = {
        { 1000000000, "B" },
        {    1000000, "M" },
        {       1000, "K" },
    };
    for (const Unit &u : kUnits) {
        if (n < u.div)
            continue;
        // One decimal, and not a trailing ".0" — "1.2M", but "3M".
        const qint64 tenths = (n * 10 + u.div / 2) / u.div;
        const QString whole = QString::number(tenths / 10);
        return (tenths % 10 == 0 ? whole : whole + QLatin1Char('.') + QString::number(tenths % 10))
             + QLatin1String(u.suffix);
    }
    return QString::number(n);
}

QString YouTubeBackend::videoDetailFilePath() const {
    return m_dataRoot + "/youtube_video_detail.json";
}

// Merges into what is already held rather than replacing it: feed descriptions
// are noted from the moment the module loads, and this file is not read until
// the first info screen — so the disk copy fills gaps, and never overwrites a
// description that came off a feed this run.
void YouTubeBackend::loadVideoDetailCache() {
    if (m_detailCacheLoaded)
        return;
    m_detailCacheLoaded = true;
    QFile file(videoDetailFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return;
    const QJsonObject obj = QJsonDocument::fromJson(file.readAll()).object();
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        const QJsonObject entry = it.value().toObject();
        VideoDetail &detail = m_videoDetail[it.key()];
        if (detail.description.isEmpty())
            detail.description = entry.value("desc").toString();
        if (detail.channelId.isEmpty())
            detail.channelId = entry.value("cid").toString();
        if (detail.channelName.isEmpty())
            detail.channelName = entry.value("ch").toString();
        if (detail.viewCount == 0) detail.viewCount = qint64(entry.value("v").toDouble());
        if (detail.likeCount == 0) detail.likeCount = qint64(entry.value("l").toDouble());
        if (detail.fetchedMs == 0) detail.fetchedMs = qint64(entry.value("ms").toDouble());
    }
}

void YouTubeBackend::saveVideoDetailCache() {
    // Over the cap, the least recently fetched go first. A video whose text came
    // off a feed and was never opened has no fetch time at all, and is the first
    // thing to drop: its description is free to have again on the next refresh.
    QStringList ids = m_videoDetail.keys();
    if (ids.size() > kMaxVideoDetailItems) {
        std::sort(ids.begin(), ids.end(), [this](const QString &a, const QString &b) {
            return m_videoDetail.value(a).fetchedMs > m_videoDetail.value(b).fetchedMs;
        });
        for (const QString &id : ids.mid(kMaxVideoDetailItems))
            m_videoDetail.remove(id);
        ids = ids.mid(0, kMaxVideoDetailItems);
    }
    QJsonObject obj;
    for (const QString &id : std::as_const(ids)) {
        const VideoDetail detail = m_videoDetail.value(id);
        QJsonObject entry;
        if (!detail.description.isEmpty()) entry["desc"] = detail.description;
        if (!detail.channelId.isEmpty())   entry["cid"]  = detail.channelId;
        if (!detail.channelName.isEmpty()) entry["ch"]   = detail.channelName;
        if (detail.viewCount > 0)          entry["v"]    = double(detail.viewCount);
        if (detail.likeCount > 0)          entry["l"]    = double(detail.likeCount);
        if (detail.fetchedMs > 0)          entry["ms"]   = double(detail.fetchedMs);
        if (!entry.isEmpty())
            obj[id] = entry;
    }
    QFile file(videoDetailFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

void YouTubeBackend::noteVideoDescription(const QString &videoId, const QString &description) {
    if (videoId.isEmpty() || description.isEmpty())
        return;
    VideoDetail &detail = m_videoDetail[videoId];
    const QString text = description.left(kMaxDescriptionChars);
    if (detail.description == text)
        return;
    detail.description  = text;
    m_videoDetailDirty  = true;
}

QVariantMap YouTubeBackend::buildVideoDetail(const QString &videoId) const {
    const VideoDetail detail = m_videoDetail.value(videoId);
    QVariantMap m;
    m["videoId"]     = videoId;
    m["description"] = detail.description;
    m["channelId"]   = detail.channelId;
    m["channelName"] = detail.channelName;
    m["viewCount"]   = detail.viewCount;
    m["likeCount"]   = detail.likeCount;
    m["viewText"]    = detail.viewCount > 0
                       ? countText(detail.viewCount) + QStringLiteral(" VIEWS") : QString();
    m["likeText"]    = detail.likeCount > 0 ? countText(detail.likeCount) : QString();
    m["complete"]    = detail.fetchedMs > 0;
    return m;
}

QVariantMap YouTubeBackend::video_detail(const QString &videoId) const {
    return buildVideoDetail(videoId);
}

void YouTubeBackend::load_video_detail(const QString &videoId) {
    if (videoId.isEmpty())
        return;
    loadVideoDetailCache();

    // Whatever is held goes out first, always — a feed description, or the last
    // fetch's — so the screen has something to draw while this decides whether
    // to ask for more.
    emit videoDetailLoaded(videoId, buildVideoDetail(videoId));

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const VideoDetail held = m_videoDetail.value(videoId);
    if (held.fetchedMs > 0 && now - held.fetchedMs < kVideoDetailTtlMs)
        return;                                   // fresh enough; nothing to ask
    if (m_activeDetailIds.contains(videoId))
        return;                                   // already out for this one
    spawnVideoDetailFetch(videoId);
}

// One yt-dlp run over a single watch page. Unlike the channel probe this is not
// queued or capped: it happens because somebody opened a screen and is waiting
// on it, one screen at a time.
void YouTubeBackend::spawnVideoDetailFetch(const QString &videoId) {
    const QString bin = ytdlp::locate(m_dataRoot);
    if (bin.isEmpty())
        return;
    m_activeDetailIds.insert(videoId);

    auto *proc = new QProcess(this);
    const QStringList args{
        QStringLiteral("--no-warnings"),
        QStringLiteral("--no-playlist"),
        QStringLiteral("--print"),
        QStringLiteral("%(.{description,view_count,like_count,duration,upload_date,"
                       "channel,channel_id})j"),
        QStringLiteral("--"),
        watchUrlFor(videoId),
    };

    auto finish = [this, proc, videoId]() {
        proc->deleteLater();
        m_activeDetailIds.remove(videoId);
        const QJsonObject obj =
            QJsonDocument::fromJson(proc->readAllStandardOutput().trimmed()).object();
        if (obj.isEmpty()) {
            // Nothing came back — a private video, no network, no yt-dlp. The
            // screen keeps whatever it was already showing; saying so again
            // would only redraw the same thing.
            return;
        }

        VideoDetail &detail = m_videoDetail[videoId];
        const QString description = obj.value(QLatin1String("description")).toString();
        if (!description.isEmpty())
            detail.description = description.left(kMaxDescriptionChars);
        detail.viewCount   = qint64(obj.value(QLatin1String("view_count")).toDouble());
        detail.likeCount   = qint64(obj.value(QLatin1String("like_count")).toDouble());
        detail.channelId   = obj.value(QLatin1String("channel_id")).toString();
        detail.channelName = obj.value(QLatin1String("channel")).toString();
        detail.fetchedMs   = QDateTime::currentMSecsSinceEpoch();
        m_videoDetailDirty = true;

        // The same run answers the two facts the lists want, for a video whose
        // channel has never been probed — which is every video Watch Later,
        // History and playlists hold. The date is a plain YYYYMMDD.
        const QDate day = QDate::fromString(obj.value(QLatin1String("upload_date")).toString(),
                                            QStringLiteral("yyyyMMdd"));
        const qint64 publishedMs =
            day.isValid() ? QDateTime(day, QTime(0, 0), QTimeZone::utc()).toMSecsSinceEpoch() : 0;
        noteVideoMeta(videoId, obj.value(QLatin1String("duration")).toInt(), publishedMs);
        if (m_videoMetaDirty) {
            saveVideoMetaCache();
            m_videoMetaDirty = false;
            emit videoMetaLoaded();
        }

        saveVideoDetailCache();
        m_videoDetailDirty = false;
        emit videoDetailLoaded(videoId, buildVideoDetail(videoId));
    };
    connect(proc, &QProcess::finished, this, finish);
    // finished() is never emitted when the binary fails to launch
    connect(proc, &QProcess::errorOccurred, this,
            [finish](QProcess::ProcessError processError) {
                if (processError == QProcess::FailedToStart)
                    finish();
            });
    QTimer::singleShot(kVideoDetailTimeoutMs, proc, [proc]() { proc->kill(); });
    proc->start(bin, args);
}

// A channel is worth a probe when it is missing either fact: a video whose
// duration has never been asked for, or an avatar that is absent or a month old.
// `asked` is what stops a video yt-dlp has no duration for (a live stream, a
// premiere) from re-queueing its channel for ever.
bool YouTubeBackend::channelNeedsProbe(const QString &channelId) const {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!m_channelArtMs.contains(channelId)
        || now - m_channelArtMs.value(channelId) > kChannelArtTtlMs)
        return true;
    const ChannelEntry entry = m_channels.value(channelId);
    for (const QVariant &v : entry.videos) {
        const QString videoId = v.toMap().value(QStringLiteral("videoId")).toString();
        if (!m_videoMeta.value(videoId).asked)
            return true;
    }
    return false;
}

void YouTubeBackend::ensureChannelProbes(const QStringList &channelIds) {
    loadChannelArtCache();
    // Capped per pass. A cold cache wants one probe per channel, and a dozen of
    // those on top of a dozen feeds is what gets an IP throttled by the host all
    // of it comes from; the rest are picked up the next time a list is opened,
    // by which point these have answered.
    for (const QString &id : channelIds) {
        if (m_probeQueue.size() >= kMaxProbesPerPass)
            break;
        if (!id.startsWith(QLatin1String("UC")))
            continue; // not a channel ID — nothing to ask about
        if (m_probeQueue.contains(id) || m_activeProbeIds.contains(id))
            continue;
        if (channelNeedsProbe(id))
            m_probeQueue << id;
    }
    spawnNextChannelProbe();
}

// The avatar out of a channel tab's thumbnail list. yt-dlp labels it, and the
// label is the only reliable handle: the rest of that list is the banner at six
// widths, and the square copy of the avatar is only distinguishable by shape.
static QString avatarFromThumbnails(const QJsonArray &thumbs) {
    QString square;
    for (const QJsonValue &v : thumbs) {
        const QJsonObject t = v.toObject();
        const QString url = t.value(QLatin1String("url")).toString();
        if (url.isEmpty())
            continue;
        if (t.value(QLatin1String("id")).toString() == QLatin1String("avatar_uncropped"))
            return url;
        const int w = t.value(QLatin1String("width")).toInt();
        const int h = t.value(QLatin1String("height")).toInt();
        if (w > 0 && w == h)
            square = url;
    }
    return square;
}

// One yt-dlp run per channel over its /videos tab: the entries carry the
// durations the feed cannot, and the tab itself carries the channel's artwork.
// Both are cached to disk, so a channel is probed about once per new upload
// rather than once per session.
void YouTubeBackend::spawnNextChannelProbe() {
    const QString bin = ytdlp::locate(m_dataRoot);
    while (m_activeProbeIds.size() < kMaxConcurrentProbes && !m_probeQueue.isEmpty()) {
        const QString channelId = m_probeQueue.takeFirst();
        m_activeProbeIds.insert(channelId);

        auto *proc = new QProcess(this);
        const QStringList args{
            QStringLiteral("--flat-playlist"),
            QStringLiteral("-I"), QStringLiteral("1:%1").arg(kMaxProbeItems),
            QStringLiteral("--no-warnings"),
            // One line per entry, then one for the tab itself. Both are JSON
            // objects, told apart by what they carry.
            QStringLiteral("--print"), QStringLiteral("%(.{id,title,duration})j"),
            QStringLiteral("--print"), QStringLiteral("playlist:%(.{channel,thumbnails})j"),
            QStringLiteral("--"),
            QStringLiteral("https://www.youtube.com/channel/") + channelId
                + QStringLiteral("/videos"),
        };

        auto finish = [this, proc, channelId]() {
            proc->deleteLater();
            int          found = 0;
            QString      art;
            QString      channelName;
            QVariantList probed;
            const QList<QByteArray> lines = proc->readAllStandardOutput().split('\n');
            for (const QByteArray &line : lines) {
                const QJsonObject obj = QJsonDocument::fromJson(line.trimmed()).object();
                if (obj.isEmpty())
                    continue;
                if (obj.contains(QLatin1String("thumbnails"))
                    || obj.contains(QLatin1String("channel"))) {
                    art = avatarFromThumbnails(obj.value(QLatin1String("thumbnails")).toArray());
                    channelName = obj.value(QLatin1String("channel")).toString();
                    continue;
                }
                const QString videoId = obj.value(QLatin1String("id")).toString();
                if (videoId.isEmpty())
                    continue;
                ++found;
                noteVideoMeta(videoId, obj.value(QLatin1String("duration")).toInt(), 0);
                // Kept in feed shape in case this channel has no feed to show —
                // see below. A tab listing is in upload order, so the order is
                // right even though no entry on it carries a date.
                QVariantMap v;
                v["videoId"]     = videoId;
                v["title"]       = obj.value(QLatin1String("title")).toString();
                v["channelId"]   = channelId;
                v["publishedAt"] = QString();
                v["publishedMs"] = qint64(0);
                v["url"]         = watchUrlFor(videoId);
                v["isShort"]     = false;
                probed << v;
            }

            // The probe is for durations and artwork — the feed is the better
            // list, and the only one with dates. But a channel the feed never
            // answered for has nothing to show, so this stands in until one
            // arrives; finishAggregate() then reports to the waiting view.
            ChannelEntry &entry = m_channels[channelId];
            if (!entry.hasVideos() && !probed.isEmpty()) {
                if (entry.channelName.isEmpty())
                    entry.channelName = channelName.isEmpty() ? channelId : channelName;
                for (QVariant &v : probed) {
                    QVariantMap m = v.toMap();
                    m["channelName"] = entry.channelName;
                    v = m;
                }
                entry.channelId = channelId;
                entry.videos    = probed;
                entry.fromProbe = true;
                if (m_pendingChannels == 0) {
                    // Other probes may still be running, and each one that
                    // fills a channel adds to the same waiting list — so the
                    // request is put back afterwards rather than being spent on
                    // whichever probe happened to answer first.
                    const bool    feedStood = m_emitFeedWhenDone;
                    const bool    chStood   = m_emitChannelsWhenDone;
                    const QString vidStood  = m_emitChannelVideosWhenDone;
                    finishAggregate();
                    if (!m_probeQueue.isEmpty() || m_activeProbeIds.size() > 1) {
                        m_emitFeedWhenDone          = feedStood;
                        m_emitChannelsWhenDone      = chStood;
                        m_emitChannelVideosWhenDone = vidStood;
                    }
                }
            } else if (entry.channelName.isEmpty() && !channelName.isEmpty()) {
                entry.channelName = channelName;
            }

            if (!art.isEmpty() && m_channelArt.value(channelId) != art) {
                m_channelArt[channelId]   = art;
                m_channelArtMs[channelId] = QDateTime::currentMSecsSinceEpoch();
                m_artCacheDirty = true;
                emit channelArtLoaded(channelId, art);
            } else if (!art.isEmpty()) {
                m_channelArtMs[channelId] = QDateTime::currentMSecsSinceEpoch();
                m_artCacheDirty = true;
            }

            // Only a run that answered marks this channel's videos asked. A
            // failed one has to leave them alone, or one throttled minute would
            // cost the channel its durations for good; a video the answer did
            // not mention (a live stream, a premiere) is marked all the same,
            // since asking again would get the same nothing back.
            if (found > 0) {
                const ChannelEntry entry = m_channels.value(channelId);
                for (const QVariant &v : entry.videos) {
                    const QString videoId = v.toMap().value(QStringLiteral("videoId")).toString();
                    if (!videoId.isEmpty())
                        m_videoMeta[videoId].asked = true;
                }
                m_videoMetaDirty = true;
                emit videoMetaLoaded();
            }

            m_activeProbeIds.remove(channelId);
            spawnNextChannelProbe();
        };
        connect(proc, &QProcess::finished, this, finish);
        // finished() is never emitted when the binary fails to launch
        connect(proc, &QProcess::errorOccurred, this,
                [finish](QProcess::ProcessError processError) {
                    if (processError == QProcess::FailedToStart)
                        finish();
                });
        QTimer::singleShot(kPlaylistFetchTimeoutMs, proc, [proc]() { proc->kill(); });
        proc->start(bin, args);
    }
    // One write when the batch drains, rather than one per channel.
    if (m_activeProbeIds.isEmpty() && m_probeQueue.isEmpty()) {
        if (m_videoMetaDirty) { saveVideoMetaCache();  m_videoMetaDirty = false; }
        if (m_artCacheDirty)  { saveChannelArtCache(); m_artCacheDirty  = false; }
    }
}

// ---------------------------------------------------------------------------
// Feed cache (youtube_feed_cache.json)
//
// The feeds a run fetched, kept so the next run starts with a list in hand — the
// cheapest request is the one not made, and without this every start of the app
// was thirteen feeds however recently the last start fetched the same thirteen.
//
// Only real feed entries are written: a channel standing in with what a probe
// found has no publish dates, and writing it would look like a fetched feed on
// the next run and stop the real one being asked for.
// ---------------------------------------------------------------------------

QString YouTubeBackend::feedCacheFilePath() const {
    return m_dataRoot + "/youtube_feed_cache.json";
}

void YouTubeBackend::loadFeedCache() {
    if (m_feedCacheLoaded)
        return;
    m_feedCacheLoaded = true;
    QFile file(feedCacheFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return;
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    const QJsonObject obj  = root.value(QLatin1String("channels")).toObject();

    // A refusal outlives the run that met it: restarting the app is the most
    // likely thing to happen next, and thirteen fresh requests into a host that
    // is already saying no is what turns a short refusal into a long one. Never
    // honoured for longer than one full window, so a clock change cannot leave
    // the module silent.
    const qint64 now    = QDateTime::currentMSecsSinceEpoch();
    const qint64 paused = qint64(root.value(QLatin1String("pausedUntil")).toDouble());
    if (paused > now)
        m_networkPausedUntilMs = std::min(paused, now + kThrottlePauseMs);

    for (auto it = obj.begin(); it != obj.end(); ++it) {
        const QJsonObject o    = it.value().toObject();
        const QJsonArray  vids = o.value(QLatin1String("videos")).toArray();
        if (vids.isEmpty())
            continue;
        ChannelEntry &e = m_channels[it.key()];
        e.channelId   = it.key();
        e.channelName = o.value(QLatin1String("name")).toString();
        e.fetchedMs   = qint64(o.value(QLatin1String("ms")).toDouble());
        e.videos      = vids.toVariantList();
        // feedOk stays false — nothing has been fetched *this* run, which is a
        // different question from whether there is anything to draw. The age of
        // fetchedMs is what decides whether it is asked for again.
    }
}

void YouTubeBackend::saveFeedCache() const {
    QJsonObject channels;
    for (const QString &id : m_channelOrder) {
        const ChannelEntry e = m_channels.value(id);
        if (e.fromProbe || e.videos.isEmpty())
            continue;
        QJsonObject entry;
        entry["name"]   = e.channelName;
        entry["ms"]     = double(e.fetchedMs);
        entry["videos"] = QJsonArray::fromVariantList(e.videos.mid(0, kMaxCachedFeedItems));
        channels[id] = entry;
    }
    QJsonObject root;
    root["channels"]    = channels;
    root["pausedUntil"] = double(m_networkPausedUntilMs);

    QFile file(feedCacheFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

// ---------------------------------------------------------------------------
// Channel avatars
//
// An RSS feed carries no artwork at all, so the avatar comes out of the same
// yt-dlp run that fetches durations (see the channel probe below) — one process
// per channel for both, rather than a feed, a page scrape and a playlist query
// each. Only the URL is kept here; the image bytes behind it are already cached
// on disk for every QML Image by AppNamFactory (src/net/).
// ---------------------------------------------------------------------------

// Google's image host takes its crop instructions after the '=' in the last
// path segment: s<N> is the longest edge and -c-k-c0x00ffffff-no-rj the square
// crop YouTube itself asks for, so the host does the resizing and a Pi never
// pulls a 900px avatar for a 96px cell. Sizes are rounded up to a multiple of
// 32 so a few cell widths do not become a few separately cached images.
QString YouTubeBackend::channel_art_url(const QString &channelId, int size) const {
    const QString base = m_channelArt.value(channelId);
    if (base.isEmpty() || size <= 0)
        return base;
    const int px = qMax(32, ((size + 31) / 32) * 32);
    const int slash = base.lastIndexOf(QLatin1Char('/'));
    const int eq    = base.indexOf(QLatin1Char('='), slash < 0 ? 0 : slash);
    const QString stem = (eq < 0) ? base : base.left(eq);
    return stem + QStringLiteral("=s%1-c-k-c0x00ffffff-no-rj").arg(px);
}

QString YouTubeBackend::channel_art_for(const QString &channelId,
                                       const QString &channelName, int size) {
    if (!channelId.isEmpty()) {
        const QString byId = channel_art_url(channelId, size);
        if (!byId.isEmpty())
            return byId;
    }
    if (channelName.isEmpty())
        return {};
    // Names come from the feeds, which may only exist on disk at this point —
    // nothing in this module has to have loaded a list before something is
    // played (a card, or the app resuming where it left off).
    loadFeedCache();
    for (auto it = m_channels.constBegin(); it != m_channels.constEnd(); ++it) {
        if (it.value().channelName.compare(channelName, Qt::CaseInsensitive) == 0)
            return channel_art_url(it.key(), size);
    }
    return {};
}

QString YouTubeBackend::channelArtFilePath() const {
    return m_dataRoot + "/youtube_channel_art.json";
}

void YouTubeBackend::loadChannelArtCache() {
    if (m_artCacheLoaded)
        return;
    m_artCacheLoaded = true;
    QFile file(channelArtFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return;
    const QJsonObject obj = QJsonDocument::fromJson(file.readAll()).object();
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        const QString url = it.value().toObject().value("url").toString();
        if (url.isEmpty())
            continue;
        m_channelArt[it.key()]   = url;
        m_channelArtMs[it.key()] = qint64(it.value().toObject().value("ms").toDouble());
    }
}

void YouTubeBackend::saveChannelArtCache() const {
    QJsonObject obj;
    for (auto it = m_channelArt.constBegin(); it != m_channelArt.constEnd(); ++it) {
        if (it.value().isEmpty())
            continue; // a miss is a session-only fact, so the next run retries it
        QJsonObject entry;
        entry["url"] = it.value();
        entry["ms"]  = double(m_channelArtMs.value(it.key()));
        obj[it.key()] = entry;
    }
    QFile file(channelArtFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

// ---------------------------------------------------------------------------
// Playlists file (youtube_playlists.txt)
// Line format: [My Display Name | ] <playlist URL or bare playlist ID>
// ---------------------------------------------------------------------------

// "list=" query param when present, bare token otherwise. A URL without a
// list= param isn't a playlist link — rejected so it can't be fed to yt-dlp
// as something else entirely.
static QString playlistIdFromToken(QString token) {
    const int listPos = token.indexOf(QLatin1String("list="));
    if (listPos >= 0) {
        token = token.mid(listPos + 5);
        const int end = token.indexOf(QRegularExpression(QStringLiteral("[&#?/]")));
        if (end >= 0)
            token = token.left(end);
        return token;
    }
    if (token.contains(QLatin1String("://")))
        return {};
    return token;
}

QList<YouTubeBackend::PlaylistFileRef> YouTubeBackend::readPlaylistEntries(QString *error) const {
    const QString path = m_dataRoot + "/" + kPlaylistsFileName;
    if (!QFile::exists(path)) {
        if (error)
            *error = QStringLiteral("NO PLAYLISTS FILE FOUND\n"
                                    "CREATE YOUTUBE_PLAYLISTS.TXT IN THE DATA DIRECTORY\n"
                                    "WITH ONE PLAYLIST URL PER LINE");
        return {};
    }
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        if (error)
            *error = QStringLiteral("COULD NOT READ YOUTUBE_PLAYLISTS.TXT");
        return {};
    }
    QList<PlaylistFileRef> refs;
    QStringList seen;
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith('#'))
            continue;
        // Split the optional display-name prefix at the last '|' (URLs never
        // contain one, display names conceivably could).
        QString name, token = line;
        const int bar = line.lastIndexOf('|');
        if (bar >= 0) {
            name  = line.left(bar).trimmed();
            token = line.mid(bar + 1).trimmed();
        }
        const QString id = playlistIdFromToken(token);
        if (id.isEmpty() || seen.contains(id))
            continue;
        seen << id;
        refs.append({id, name});
    }
    if (refs.isEmpty() && error)
        *error = QStringLiteral("NO PLAYLISTS FOUND IN YOUTUBE_PLAYLISTS.TXT");
    return refs;
}

QVariantMap YouTubeBackend::check_playlists() {
    QString error;
    const QList<PlaylistFileRef> refs = readPlaylistEntries(&error);
    QVariantMap result;
    result["ok"]            = error.isEmpty();
    result["error"]         = error;
    result["fileExists"]    = QFile::exists(m_dataRoot + "/" + kPlaylistsFileName);
    result["playlistCount"] = refs.size();
    return result;
}

// ---------------------------------------------------------------------------
// Playlist loaders — yt-dlp --flat-playlist subprocesses feeding the same
// cache/queue shape as the RSS channel path. yt-dlp is used (rather than the
// playlist RSS feed) because the feed stops at 15 entries.
// ---------------------------------------------------------------------------

void YouTubeBackend::load_playlists(bool forceRefresh) {
    m_emitPlaylistsWhenDone = true;
    ensurePlaylistsFresh(forceRefresh);
}

void YouTubeBackend::load_playlist_videos(const QString &playlistId, bool forceRefresh) {
    m_emitPlaylistVideosWhenDone = playlistId;
    ensurePlaylistsFresh(forceRefresh);
}

void YouTubeBackend::ensurePlaylistsFresh(bool forceRefresh) {
    if (m_pendingPlaylists > 0) {
        // A refresh is already in flight and this caller's emit flag has queued
        // on it — but the caller has a screen to fill now, and the cache is
        // very likely holding what it asked for.
        servePlaylistsFromCache();
        return;
    }

    loadPlaylistCache();

    QString error;
    const QList<PlaylistFileRef> refs = readPlaylistEntries(&error);
    if (refs.isEmpty()) {
        m_emitPlaylistsWhenDone = false;
        m_emitPlaylistVideosWhenDone.clear();
        emit errorOccurred(error);
        return;
    }
    m_playlistOrder.clear();
    for (const PlaylistFileRef &ref : refs) {
        m_playlistOrder << ref.id;
        PlaylistEntry &entry = m_playlists[ref.id];
        entry.playlistId = ref.id;
        entry.fileName   = ref.name; // re-read every refresh so file edits apply
    }

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    QStringList stale;
    for (const QString &id : m_playlistOrder) {
        const PlaylistEntry &entry = m_playlists.value(id);
        // A list that has been failing is stood back from, however old what is
        // held for it is. An explicit refresh overrules that: the user is
        // looking at the screen and has asked for it now.
        if (!forceRefresh && now < entry.retryAfterMs)
            continue;
        // Having nothing to draw is what makes a list urgent, not having
        // fetched nothing this run — last run's contents are still contents.
        if (forceRefresh || !entry.hasVideos()
            || now - entry.fetchedMs > kPlaylistCacheTtlMs)
            stale << id;
    }

    if (stale.isEmpty()) {
        finishPlaylistAggregate(); // everything fresh — serve from cache
        return;
    }
    // Resolve the same user-updatable yt-dlp mpv's ytdl_hook will use at
    // playback time (data-dir drop-in → sibling → PATH), so app and mpv agree.
    if (ytdlp::locate(m_dataRoot).isEmpty()) {
        // Nothing can be fetched; report against whatever the cache holds.
        finishPlaylistAggregate();
        return;
    }
    // Something is going to be fetched, which on a Pi is a subprocess per list
    // and a wait the user watches. Whatever is already held goes to the screen
    // first, and the fetch answers the same request again when it lands.
    servePlaylistsFromCache();
    m_pendingPlaylists   = stale.size();
    m_playlistFetchQueue = stale;
    spawnNextPlaylistFetch();
}

// The cover yt-dlp reports for a playlist, out of the several sizes it lists.
// The smallest that still fills the header cell is the one worth pulling — a Pi
// drawing a 120px poster has no use for a 1280px frame — so this takes the
// narrowest at or above 320 (the width of the mqdefault thumbnails the lists
// already draw), and the largest on offer when none of them reaches it.
static QString playlistThumbFromThumbnails(const QJsonArray &thumbs) {
    QString best, largest;
    int bestW = 0, largestW = -1;
    for (const QJsonValue &v : thumbs) {
        const QJsonObject t = v.toObject();
        const QString url = t.value(QLatin1String("url")).toString();
        if (url.isEmpty())
            continue;
        const int w = t.value(QLatin1String("width")).toInt();
        if (w > largestW) {
            largestW = w;
            largest  = url;
        }
        if (w >= 320 && (bestW == 0 || w < bestW)) {
            bestW = w;
            best  = url;
        }
    }
    return best.isEmpty() ? largest : best;
}

// When YouTube last says the list changed. Two spellings reach us: the epoch
// seconds yt-dlp works out where it can, and otherwise the plain YYYYMMDD it
// reads off the "Last updated on" line under the list — which is a day, with no
// time in it, so it is taken as that day's start. A list YouTube dates in neither
// way (a Mix, a channel's uploads) comes back 0 and is simply not dated.
static qint64 playlistModifiedMs(const QJsonObject &obj) {
    const qint64 stamp = qint64(obj.value(QLatin1String("modified_timestamp")).toDouble());
    if (stamp > 0)
        return stamp * 1000;
    const QString day = obj.value(QLatin1String("modified_date")).toString();
    const QDate   date = QDate::fromString(day, QStringLiteral("yyyyMMdd"));
    if (!date.isValid())
        return 0;
    return QDateTime(date, QTime(0, 0), QTimeZone::utc()).toMSecsSinceEpoch();
}

// One entry of a playlist, as both the fetch and the disk cache build it — one
// statement of the shape, so what is read back is what was written. Only three
// of the eight fields carry anything, which is what the cache stores: the URL
// follows from the ID and the rest are constant for a flat listing.
static QVariantMap playlistVideo(const QString &videoId, const QString &title,
                                 const QString &channelName) {
    QVariantMap v;
    v["videoId"]     = videoId;
    v["title"]       = title;
    v["channelId"]   = QString();
    v["channelName"] = channelName;
    // Flat entries carry no publish date; playlist order stands in
    v["publishedAt"] = QString();
    v["publishedMs"] = qint64(0);
    v["url"]         = watchUrlFor(videoId);
    v["isShort"]     = false; // not detectable from flat entries
    return v;
}

void YouTubeBackend::notePlaylistFailure(PlaylistEntry &entry) {
    ++entry.failures;
    entry.retryAfterMs = QDateTime::currentMSecsSinceEpoch()
                       + std::min(qint64(entry.failures) * kPlaylistRetryBackoffMs,
                                  kMaxPlaylistRetryBackoffMs);
}

void YouTubeBackend::spawnNextPlaylistFetch() {
    const QString bin = ytdlp::locate(m_dataRoot);
    while (m_activePlaylistFetches < kMaxConcurrentPlaylistFetches
           && !m_playlistFetchQueue.isEmpty()) {
        const QString playlistId = m_playlistFetchQueue.takeFirst();
        ++m_activePlaylistFetches;

        auto *proc = new QProcess(this);
        const QStringList args{
            QStringLiteral("--flat-playlist"),
            QStringLiteral("-I"), QStringLiteral("1:%1").arg(kMaxPlaylistItems),
            QStringLiteral("--no-warnings"),
            // One JSON object per entry — robust against '|' etc. in titles
            QStringLiteral("--print"),
            QStringLiteral("%(.{id,title,channel,uploader,playlist_title,duration})j"),
            // One more line for the list itself, carrying its cover and the
            // date YouTube shows under it — the same shape the channel probe
            // reads its avatar from. Both fields are optional: %(.{...})j prints
            // only the keys the extractor actually filled in.
            QStringLiteral("--print"),
            QStringLiteral("playlist:%(.{thumbnails,modified_date,modified_timestamp})j"),
            QStringLiteral("--"),
            QStringLiteral("https://www.youtube.com/playlist?list=") + playlistId,
        };

        auto finish = [this, proc, playlistId]() {
            proc->deleteLater();
            QString      title;
            QString      thumb;
            qint64       modifiedMs = 0;
            QVariantList videos;
            const QList<QByteArray> lines = proc->readAllStandardOutput().split('\n');
            for (const QByteArray &line : lines) {
                const QJsonObject obj = QJsonDocument::fromJson(line.trimmed()).object();
                if (obj.isEmpty())
                    continue;
                // The list's own line rather than one of its entries, told
                // apart by what it carries (as the channel probe does) — any of
                // the list-only fields, since a list that reported none of the
                // others still gets here on the one it did.
                if (obj.contains(QLatin1String("thumbnails"))
                    || obj.contains(QLatin1String("modified_timestamp"))
                    || obj.contains(QLatin1String("modified_date"))) {
                    if (obj.contains(QLatin1String("thumbnails")))
                        thumb = playlistThumbFromThumbnails(
                            obj.value(QLatin1String("thumbnails")).toArray());
                    modifiedMs = playlistModifiedMs(obj);
                    continue;
                }
                if (title.isEmpty())
                    title = obj.value(QLatin1String("playlist_title")).toString();
                const QString videoId    = obj.value(QLatin1String("id")).toString();
                const QString videoTitle = obj.value(QLatin1String("title")).toString();
                if (videoId.isEmpty())
                    continue;
                // Tombstones YouTube leaves in place of removed entries
                if (videoTitle == QLatin1String("[Private video]")
                    || videoTitle == QLatin1String("[Deleted video]"))
                    continue;
                QString channel = obj.value(QLatin1String("channel")).toString();
                if (channel.isEmpty())
                    channel = obj.value(QLatin1String("uploader")).toString();
                videos.append(playlistVideo(videoId, videoTitle, channel));
                // Free duration: this list was fetched with yt-dlp anyway, so a
                // playlist's videos never need the uploads probe below.
                noteVideoMeta(videoId, obj.value(QLatin1String("duration")).toInt(), 0);
            }
            // Non-zero exit with parsed entries still counts (partial page
            // failures on huge lists) — same "partial parses kept" stance as RSS.
            const bool ok = proc->exitStatus() == QProcess::NormalExit
                            && (proc->exitCode() == 0 || !videos.isEmpty());
            if (ok) {
                PlaylistEntry &entry = m_playlists[playlistId];
                entry.fetchedTitle = title;
                // Kept when this run reported none, so a fetch that came back
                // without a cover does not take away the one already on screen.
                if (!thumb.isEmpty())
                    entry.thumbUrl = thumb;
                if (modifiedMs > 0)
                    entry.modifiedMs = modifiedMs;
                entry.videos       = videos;
                entry.fetchedMs    = QDateTime::currentMSecsSinceEpoch();
                entry.failures     = 0;
                entry.retryAfterMs = 0;
                m_playlistCacheDirty = true;
            } else {
                // Keep any previously cached videos (stale beats empty) and
                // stand back from this list rather than spawning another
                // process for it on the next entry into the module.
                notePlaylistFailure(m_playlists[playlistId]);
            }

            --m_activePlaylistFetches;
            if (--m_pendingPlaylists <= 0) {
                m_pendingPlaylists      = 0;
                m_activePlaylistFetches = 0;
                m_playlistFetchQueue.clear();
                finishPlaylistAggregate();
            } else {
                spawnNextPlaylistFetch();
            }
        };
        connect(proc, &QProcess::finished, this, finish);
        // finished() is never emitted when the binary fails to launch
        connect(proc, &QProcess::errorOccurred, this,
                [finish](QProcess::ProcessError processError) {
                    if (processError == QProcess::FailedToStart)
                        finish();
                });
        QTimer::singleShot(kPlaylistFetchTimeoutMs, proc, [proc]() { proc->kill(); });
        proc->start(bin, args);
    }
}

// The waiting view's answer out of what is held, before anything is fetched. The
// emit flags are deliberately left standing: the same view is answered a second
// time with the fetched list, and the views keep the user's place through it. A
// list with nothing cached is genuinely still waiting and is answered by the
// aggregate, so nothing is said about it here.
void YouTubeBackend::servePlaylistsFromCache() {
    if (m_emitPlaylistsWhenDone) {
        bool anyData = false;
        for (const QString &id : m_playlistOrder)
            anyData = anyData || m_playlists.value(id).hasVideos();
        if (anyData)
            emit playlistsLoaded(buildPlaylistList());
    }
    if (!m_emitPlaylistVideosWhenDone.isEmpty()) {
        const PlaylistEntry entry = m_playlists.value(m_emitPlaylistVideosWhenDone);
        if (entry.hasVideos())
            emit playlistVideosLoaded(m_emitPlaylistVideosWhenDone, entry.videos);
    }
}

void YouTubeBackend::finishPlaylistAggregate() {
    const bool    listWanted   = m_emitPlaylistsWhenDone;
    const QString videosWanted = m_emitPlaylistVideosWhenDone;
    m_emitPlaylistsWhenDone = false;
    m_emitPlaylistVideosWhenDone.clear();

    if (m_playlistCacheDirty) {
        savePlaylistCache();
        m_playlistCacheDirty = false;
    }

    // Playlist entries carried durations in with them; this is where that batch
    // reaches disk, since no channel probe is going to run to flush it.
    if (m_videoMetaDirty && m_activeProbeIds.isEmpty() && m_probeQueue.isEmpty()) {
        saveVideoMetaCache();
        m_videoMetaDirty = false;
    }

    // Anything to draw, from this run's fetch or from the last one's cache.
    bool anyData = false;
    for (const QString &id : m_playlistOrder)
        anyData = anyData || m_playlists.value(id).hasVideos();
    if (!anyData) {
        emit errorOccurred(QStringLiteral("COULD NOT LOAD PLAYLISTS\n"
                                          "CHECK YOUR NETWORK CONNECTION AND THAT\n"
                                          "YT-DLP IS INSTALLED AND UP TO DATE"));
        return;
    }

    if (listWanted)
        emit playlistsLoaded(buildPlaylistList());
    if (!videosWanted.isEmpty()) {
        const PlaylistEntry entry = m_playlists.value(videosWanted);
        if (entry.hasVideos())
            emit playlistVideosLoaded(videosWanted, entry.videos);
        else
            emit errorOccurred(QStringLiteral("COULD NOT LOAD PLAYLIST"));
    }
}

QVariantList YouTubeBackend::playlist_videos(const QString &playlistId, int limit) const {
    const QVariantList videos = m_playlists.value(playlistId).videos;
    if (limit <= 0 || videos.size() <= limit)
        return videos;
    return videos.mid(0, limit);
}

QString YouTubeBackend::playlist_thumb_url(const QString &playlistId) const {
    const PlaylistEntry entry = m_playlists.value(playlistId);
    if (!entry.thumbUrl.isEmpty())
        return entry.thumbUrl;
    // No cover reported: the first video's frame is what YouTube would have
    // picked for it anyway.
    if (entry.videos.isEmpty())
        return {};
    return video_thumb_url(entry.videos.first().toMap()
                               .value(QStringLiteral("videoId")).toString());
}

QVariantList YouTubeBackend::buildPlaylistList() const {
    QVariantList playlists;
    for (const QString &id : m_playlistOrder) {
        const PlaylistEntry entry = m_playlists.value(id);
        QVariantMap p;
        p["playlistId"] = id;
        // File-name override wins; fall back to the raw ID so a playlist whose
        // fetch failed is still visible (same choice as buildChannelList)
        p["title"]      = !entry.fileName.isEmpty()     ? entry.fileName
                        : !entry.fetchedTitle.isEmpty() ? entry.fetchedTitle
                                                        : id;
        p["videoCount"] = entry.videos.size();
        // 0 for a list YouTube does not date; the views state nothing for it.
        p["modifiedMs"] = entry.modifiedMs;
        playlists << p;
    }
    return playlists; // file order — the user's own curation is the sort
}

// ---------------------------------------------------------------------------
// Playlist cache (youtube_playlist_cache.json)
//
// The feed cache's bargain, for the lists that cost the most to fetch: a
// playlist is a yt-dlp run over as many as 500 entries, so a cold start spends a
// minute of a Pi's attention re-learning what the last run knew. With this the
// module draws at once and refreshes behind.
//
// Only what a fetch cannot cheaply re-derive is written: the three fields an
// entry carries (playlistVideo), the list's cover and date, and when it was
// fetched. Durations live in youtube_video_meta.json, keyed by video.
//
// Entries are written whole rather than trimmed to a preview: the file *is* the
// list until a refresh replaces it, and a truncated one would be wrong.
// ---------------------------------------------------------------------------

QString YouTubeBackend::playlistCacheFilePath() const {
    return m_dataRoot + "/youtube_playlist_cache.json";
}

void YouTubeBackend::loadPlaylistCache() {
    if (m_playlistCacheLoaded)
        return;
    m_playlistCacheLoaded = true;
    QFile file(playlistCacheFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return;
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    const QJsonObject obj  = root.value(QLatin1String("playlists")).toObject();

    for (auto it = obj.begin(); it != obj.end(); ++it) {
        const QJsonObject o    = it.value().toObject();
        const QJsonArray  vids = o.value(QLatin1String("videos")).toArray();
        QVariantList videos;
        for (const QJsonValue &v : vids) {
            const QJsonObject e       = v.toObject();
            const QString     videoId = e.value(QLatin1String("i")).toString();
            if (videoId.isEmpty())
                continue;
            videos.append(playlistVideo(videoId,
                                        e.value(QLatin1String("t")).toString(),
                                        e.value(QLatin1String("c")).toString()));
        }
        if (videos.isEmpty())
            continue;
        PlaylistEntry &entry = m_playlists[it.key()];
        entry.playlistId   = it.key();
        entry.fetchedTitle = o.value(QLatin1String("title")).toString();
        entry.thumbUrl     = o.value(QLatin1String("thumb")).toString();
        entry.modifiedMs   = qint64(o.value(QLatin1String("modified")).toDouble());
        entry.fetchedMs    = qint64(o.value(QLatin1String("ms")).toDouble());
        entry.videos       = videos;
    }
}

void YouTubeBackend::savePlaylistCache() const {
    QJsonObject lists;
    // File order, so a playlist the user has taken out of youtube_playlists.txt
    // leaves the cache with it rather than sitting in it for ever.
    for (const QString &id : m_playlistOrder) {
        const PlaylistEntry e = m_playlists.value(id);
        if (!e.hasVideos())
            continue;
        QJsonArray videos;
        for (const QVariant &v : std::as_const(e.videos)) {
            const QVariantMap m = v.toMap();
            // Short keys: five hundred entries a list, and nothing but this
            // code ever reads them.
            QJsonObject o;
            o["i"] = m.value(QStringLiteral("videoId")).toString();
            o["t"] = m.value(QStringLiteral("title")).toString();
            const QString channel = m.value(QStringLiteral("channelName")).toString();
            if (!channel.isEmpty())
                o["c"] = channel;
            videos.append(o);
        }
        QJsonObject entry;
        entry["title"]    = e.fetchedTitle;
        entry["thumb"]    = e.thumbUrl;
        entry["modified"] = double(e.modifiedMs);
        entry["ms"]       = double(e.fetchedMs);
        entry["videos"]   = videos;
        lists[id] = entry;
    }
    QJsonObject root;
    root["playlists"] = lists;

    QFile file(playlistCacheFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

// ---------------------------------------------------------------------------
// Playback resolution → yt-dlp format
// ---------------------------------------------------------------------------

QString YouTubeBackend::ytdlFormatForResolution(const QString &resolution) const {
    int height = 480;
    if (resolution == QLatin1String("720p"))
        height = 720;
    else if (resolution == QLatin1String("1080p"))
        height = 1080;
    // H.264 first (RPi hardware decode), then any codec at the cap, then best
    return QStringLiteral("bestvideo[height<=?%1][vcodec^=avc1]+bestaudio/"
                          "bestvideo[height<=?%1]+bestaudio/"
                          "best[height<=?%1]/best")
        .arg(height);
}

// ---------------------------------------------------------------------------
// Watch history (youtube_history.json, keyed by videoId)
// Entry: { pos: <ms>, title, channelName, lastPlayed: <epoch ms> }
// Legacy pos-only entries are tolerated: they resume fine but are skipped by
// the History list (nothing to display) and pruned first (lastPlayed 0).
// ---------------------------------------------------------------------------

QString YouTubeBackend::historyFilePath() const {
    return m_dataRoot + "/youtube_history.json";
}

QVariantMap YouTubeBackend::readHistoryFile() const {
    QFile file(historyFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(file.readAll()).object().toVariantMap();
}

void YouTubeBackend::saveHistory(const QVariantMap &history) {
    QFile file(historyFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(QJsonObject::fromVariantMap(history)).toJson(QJsonDocument::Compact));
}

QVariantMap YouTubeBackend::getSavedPosition(const QString &videoId) {
    const QVariant val = m_history.value(videoId);
    if (!val.isValid())
        return {};
    return val.toMap();
}

void YouTubeBackend::savePosition(const QString &videoId, int positionMs,
                                  const QString &title, const QString &channelName) {
    QVariantMap history = m_history;
    QVariantMap entry;
    entry["pos"]         = positionMs;
    entry["title"]       = title;
    entry["channelName"] = channelName;
    entry["lastPlayed"]  = QDateTime::currentMSecsSinceEpoch();
    history[videoId] = entry;

    if (history.size() > kMaxHistoryItems) {
        QStringList keys = history.keys();
        std::sort(keys.begin(), keys.end(), [&history](const QString &a, const QString &b) {
            return history.value(a).toMap().value("lastPlayed").toLongLong()
                 > history.value(b).toMap().value("lastPlayed").toLongLong();
        });
        for (int i = kMaxHistoryItems; i < keys.size(); ++i)
            history.remove(keys[i]);
    }
    m_history = history;
    saveHistory(history);
}

QVariantList YouTubeBackend::getHistory() const {
    const QVariantMap history = m_history;
    QVariantList items;
    for (auto it = history.begin(); it != history.end(); ++it) {
        const QVariantMap entry = it.value().toMap();
        const QString title = entry.value("title").toString();
        if (title.isEmpty())
            continue; // legacy resume-only entry — nothing to display
        QVariantMap v;
        v["videoId"]     = it.key();
        v["title"]       = title;
        v["channelName"] = entry.value("channelName").toString();
        v["lastPlayed"]  = entry.value("lastPlayed").toLongLong();
        v["url"]         = watchUrlFor(it.key());
        items << v;
    }
    std::sort(items.begin(), items.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("lastPlayed").toLongLong()
             > b.toMap().value("lastPlayed").toLongLong();
    });
    return items;
}

void YouTubeBackend::delete_history() {
    m_history.clear();
    QFile::remove(historyFilePath());
}

// ---------------------------------------------------------------------------
// Watch later (youtube_watch_later.json — JSON array, newest-saved first)
// Entry: { videoId, title, channelName, addedMs }
// ---------------------------------------------------------------------------

QString YouTubeBackend::watchLaterFilePath() const {
    return m_dataRoot + "/youtube_watch_later.json";
}

QVariantList YouTubeBackend::loadWatchLater() const {
    QFile file(watchLaterFilePath());
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(file.readAll()).array().toVariantList();
}

void YouTubeBackend::saveWatchLater(const QVariantList &list) {
    QFile file(watchLaterFilePath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(QJsonArray::fromVariantList(list)).toJson(QJsonDocument::Compact));
}

QVariantList YouTubeBackend::getWatchLater() const {
    QVariantList items = loadWatchLater();
    for (QVariant &v : items) {
        QVariantMap m = v.toMap();
        m["url"] = watchUrlFor(m.value("videoId").toString());
        v = m;
    }
    return items;
}

bool YouTubeBackend::isInWatchLater(const QString &videoId) const {
    const QVariantList list = loadWatchLater();
    for (const QVariant &v : list) {
        if (v.toMap().value("videoId").toString() == videoId)
            return true;
    }
    return false;
}

void YouTubeBackend::addToWatchLater(const QString &videoId, const QString &title,
                                     const QString &channelName) {
    if (videoId.isEmpty() || isInWatchLater(videoId))
        return;
    QVariantList list = loadWatchLater();
    QVariantMap entry;
    entry["videoId"]     = videoId;
    entry["title"]       = title;
    entry["channelName"] = channelName;
    entry["addedMs"]     = QDateTime::currentMSecsSinceEpoch();
    list.prepend(entry);
    saveWatchLater(list);
}

void YouTubeBackend::removeFromWatchLater(const QString &videoId) {
    QVariantList list = loadWatchLater();
    for (int i = list.size() - 1; i >= 0; --i) {
        if (list[i].toMap().value("videoId").toString() == videoId)
            list.removeAt(i);
    }
    if (list.isEmpty())
        QFile::remove(watchLaterFilePath());
    else
        saveWatchLater(list);
}

void YouTubeBackend::delete_watch_later() {
    QFile::remove(watchLaterFilePath());
}
