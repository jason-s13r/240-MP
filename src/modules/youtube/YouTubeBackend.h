#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QHash>
#include <QSet>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QNetworkAccessManager>

// Backend for the YouTube module (V1 "feed" approach — no auth).
//
// The user lists channel IDs (one per line) in <dataRoot>/youtube_subscriptions.txt.
// Video lists come from each channel's official RSS feed (titles, exact publish
// dates, channel name — ~15 newest videos), fetched unauthenticated. Results are
// cached per channel with a kCacheTtlMs TTL, so the first entry into
// Subscriptions or Channels fills the cache for every other view — and written
// to disk, so a restart inside that window costs no requests at all.
//
// Everything goes to one host, which throttles a busy address and expresses the
// refusal as a 404 on every feed — its own channel's included, so it cannot be
// read as the channel being gone. Three defences: feeds go out a few at a time,
// a failed channel is left alone for a while, and a pass that mostly fails
// pauses the module for kThrottlePauseMs (remembered across restarts, since
// restarting is otherwise the fastest way to send another burst). A channel with
// nothing cached is filled in from its yt-dlp probe instead.
//
// Playlists come from <dataRoot>/youtube_playlists.txt (one playlist URL or ID
// per line, optional "My Name | <url>" display-name prefix). RSS feeds for
// playlists stop at 15 entries, so playlist contents are fetched by spawning
// yt-dlp --flat-playlist instead (async QProcess).
//
// That fetch is the most expensive thing the module does, while a hand-kept list
// changes on human time. So playlists are cached harder than feeds: kept on disk
// between runs, held for kPlaylistCacheTtlMs, and handed to a view the moment it
// asks while the refresh runs behind it.
//
// Seven files besides subscriptions/playlists:
//   youtube_history.json     — watch history + resume positions, keyed by videoId
//   youtube_watch_later.json — ordered saved-video list (newest first)
//   youtube_channel_art.json — channel ID → avatar URL, filled in by this backend
//   youtube_video_meta.json  — video ID → duration + publish date, likewise
//   youtube_feed_cache.json  — last run's feeds, so a restart is not a refetch
//   youtube_playlist_cache.json — the same for playlists, which cost far more
//   youtube_video_detail.json — descriptions + counts, for the info screen
class YouTubeBackend : public QObject {
    Q_OBJECT
public:
    explicit YouTubeBackend(const QString &appRoot, const QString &dataRoot,
                            QObject *parent = nullptr);

    // Synchronous subscriptions-file check for the menu view:
    // { ok: bool, error: QString, fileExists: bool, channelCount: int }
    Q_INVOKABLE QVariantMap check_subscriptions();

    Q_INVOKABLE void load_subscriptions_feed(bool forceRefresh = false);
    Q_INVOKABLE void load_channels(bool forceRefresh = false);
    Q_INVOKABLE void load_channel_videos(const QString &channelId, bool forceRefresh = false);

    // Channel avatar (profile picture) for the poster grid, sized to the cell it
    // is drawn in. The RSS feed carries no artwork, so it is scraped from the
    // channel page once and kept in youtube_channel_art.json; "" until a
    // channel's is known, with channelArtLoaded announcing each one that lands.
    Q_INVOKABLE QString channel_art_url(const QString &channelId, int size = 0) const;

    // The same avatar for something that knows only the channel's *name* —
    // Watch Later, History and playlist entries carry no ID, so a lookup by ID
    // alone leaves the three lists a video is most often played from with no
    // avatar. Matched against the subscribed channels; anything else has none.
    Q_INVOKABLE QString channel_art_for(const QString &channelId,
                                        const QString &channelName, int size = 0);

    // A video's own thumbnail. Deterministic from the ID — no request to make
    // and nothing to cache — so it needs none of the machinery an avatar does.
    Q_INVOKABLE QString video_thumb_url(const QString &videoId) const;

    // How long a video runs and how old it is — "25:28", "3 DAYS AGO". Worded
    // here because more than one view draws them. Empty until known: an RSS feed
    // has no duration, so those fill in behind the list (videoMetaLoaded says
    // when); dates come the other way, off the feed itself.
    Q_INVOKABLE QString video_duration_text(const QString &videoId) const;
    Q_INVOKABLE QString video_age_text(const QString &videoId) const;

    // A video's own page, for the info screen a list opens before playback.
    //
    // Two sources, arriving at very different speeds: channel RSS carries the
    // description in full and is fetched for the lists anyway, so a video from
    // Subscriptions has its text at once; everything else is one yt-dlp run over
    // the watch page, which also answers the counts and the channel ID those
    // lists are missing.
    //
    // video_detail() is what is held right now; load_video_detail() serves that
    // back at once, then fetches and announces with videoDetailLoaded.
    //   { videoId, description, channelId, channelName, viewCount, likeCount,
    //     viewText, likeText, complete }
    // `complete` is false while the map is the feed's description alone.
    Q_INVOKABLE QVariantMap video_detail(const QString &videoId) const;
    Q_INVOKABLE void        load_video_detail(const QString &videoId);

    // The same wording off a bare timestamp, for the things that are dated
    // without being videos — a playlist's last update. Empty for a date that
    // is not known (0), so a caller states nothing rather than "56 YEARS AGO".
    Q_INVOKABLE QString age_text(qint64 ms) const;

    // Synchronous playlists-file check, mirroring check_subscriptions():
    // { ok: bool, error: QString, fileExists: bool, playlistCount: int }
    Q_INVOKABLE QVariantMap check_playlists();

    Q_INVOKABLE void load_playlists(bool forceRefresh = false);
    Q_INVOKABLE void load_playlist_videos(const QString &playlistId, bool forceRefresh = false);

    // One playlist's videos as they already sit in the cache — no request of its
    // own, because load_playlists() fetches every playlist's contents anyway.
    // That is what lets the poster view draw a shelf per playlist off the one
    // load the list view was already doing. limit > 0 takes the front of the
    // list, which is all a shelf shows before it hands over to the full list.
    Q_INVOKABLE QVariantList playlist_videos(const QString &playlistId, int limit = 0) const;

    // The playlist's own cover, read off the same yt-dlp run as the videos and
    // falling back to the first video's thumbnail. Unsized: the thumbnail host
    // serves fixed sizes rather than taking a crop instruction.
    Q_INVOKABLE QString playlist_thumb_url(const QString &playlistId) const;

    // Maps the playback_resolution setting ("480p"/"720p"/"1080p", unknown → 480p)
    // to a yt-dlp format string. H.264 is preferred first for RPi hardware decode.
    Q_INVOKABLE QString ytdlFormatForResolution(const QString &resolution) const;

    // Watch history (youtube_history.json). A finished video stays in history
    // with pos 0 (so it lists under History but never prompts to resume);
    // entries are pruned to the kMaxHistoryItems most recently played.
    Q_INVOKABLE QVariantMap  getSavedPosition(const QString &videoId);
    Q_INVOKABLE void         savePosition(const QString &videoId, int positionMs,
                                          const QString &title, const QString &channelName);
    Q_INVOKABLE QVariantList getHistory() const;   // displayable entries, newest first
    Q_INVOKABLE void         delete_history();     // settings action slot

    // Watch later (youtube_watch_later.json), newest-saved first, manual removal only
    Q_INVOKABLE QVariantList getWatchLater() const;
    Q_INVOKABLE bool         isInWatchLater(const QString &videoId) const;
    Q_INVOKABLE void         addToWatchLater(const QString &videoId, const QString &title,
                                             const QString &channelName);
    Q_INVOKABLE void         removeFromWatchLater(const QString &videoId);
    Q_INVOKABLE void         delete_watch_later(); // settings action slot

signals:
    void subscriptionsFeedLoaded(const QVariant &videos);
    void channelsLoaded(const QVariant &channels);
    void channelVideosLoaded(const QString &channelId, const QVariant &videos);
    // One channel's avatar has been resolved; views re-read channel_art_url().
    void channelArtLoaded(const QString &channelId, const QString &artUrl);
    // More durations have landed; views re-read video_duration_text().
    void videoMetaLoaded();
    // A video's description/counts have landed; see load_video_detail().
    void videoDetailLoaded(const QString &videoId, const QVariant &detail);
    void playlistsLoaded(const QVariant &playlists);
    void playlistVideosLoaded(const QString &playlistId, const QVariant &videos);
    void errorOccurred(const QString &message);

private:
    struct ChannelEntry {
        QString      channelId;
        QString      channelName;      // from the RSS feed <title>, else a probe
        QVariantList videos;           // newest first
        qint64       fetchedMs = 0;    // 0 = never fetched successfully
        bool         feedOk    = false;
        // What a failing feed leaves behind: how many times in a row it has
        // failed, and the moment it is worth asking again. Neither is written to
        // disk — a fresh run is reason enough to try a channel once more.
        int          failures     = 0;
        qint64       retryAfterMs = 0;
        // Set when `videos` came from a yt-dlp probe rather than the feed —
        // enough to list a channel and play from it, but with no publish dates
        // in it, so the feed is still worth asking for.
        bool         fromProbe    = false;

        // Anything to show, from either source. Not the same question as
        // feedOk: a channel served from last run's cache has never had a
        // successful fetch *this* run and still has everything to draw.
        bool hasVideos() const { return !videos.isEmpty(); }
    };

    struct PlaylistEntry {
        QString      playlistId;
        QString      fileName;         // optional "Name |" override from the file
        QString      fetchedTitle;     // playlist_title reported by yt-dlp
        QString      thumbUrl;         // the list's own cover, as yt-dlp reports it
        qint64       modifiedMs = 0;   // YouTube's "last updated on", where it says
        QVariantList videos;           // playlist order
        qint64       fetchedMs = 0;
        // How many attempts in a row have failed, and until when the list is
        // left alone for it. A playlist that has been deleted or made private
        // fails every time it is asked for, and without this it costs a
        // subprocess and its timeout on every entry into the module, for ever.
        int          failures     = 0;
        qint64       retryAfterMs = 0;

        // Anything to draw, from this run's fetch or from the last one's cache
        // — which is the question every view actually asks. Whether a fetch has
        // succeeded *this* run is a different one, and nothing needs it: the
        // age of fetchedMs is what decides if the list is asked for again.
        bool hasVideos() const { return !videos.isEmpty(); }
    };

    struct PlaylistFileRef {
        QString id;
        QString name;                  // empty when the line had no "Name |" prefix
    };

    QString      historyFilePath() const;
    QVariantMap  loadHistory() const;
    void         saveHistory(const QVariantMap &history);
    QString      watchLaterFilePath() const;
    QVariantList loadWatchLater() const;
    void         saveWatchLater(const QVariantList &list);

    QStringList  readSubscriptionIds(QString *error = nullptr) const;
    void         ensureFresh(bool forceRefresh);
    void         dispatchFeedFetches();
    void         refreshChannel(const QString &channelId);
    void         noteFeedFailure(ChannelEntry &entry);

    // Last run's feeds, so entering the module does not mean thirteen requests
    // to the one host every time the app starts. See the comment on the loader.
    QString      feedCacheFilePath() const;
    void         loadFeedCache();
    void         saveFeedCache() const;
    void         finishAggregate();
    QVariantList buildFeed() const;
    QVariantList buildChannelList() const;
    QNetworkRequest makeRequest(const QUrl &url) const;

    struct VideoMeta {
        int    duration    = 0;  // seconds, 0 = none known
        qint64 publishedMs = 0;  // 0 = none known
        bool   asked       = false; // an uploads fetch has covered this video
    };

    QString      videoMetaFilePath() const;
    void         loadVideoMetaCache();
    void         saveVideoMetaCache() const;
    void         noteVideoMeta(const QString &videoId, int duration, qint64 publishedMs);

    // What a video's own page says, beyond the line a list shows. Kept apart
    // from VideoMeta because it is written by a different pass, is an order of
    // magnitude larger per video, and is only ever read one video at a time —
    // so the file the lists depend on stays small and is loaded up front, while
    // this one is loaded on the first info screen and never before.
    struct VideoDetail {
        QString description;
        QString channelId;      // what Watch Later / History / playlists lack
        QString channelName;
        qint64  viewCount = 0;
        qint64  likeCount = 0;  // 0 also means "hidden by the uploader"
        qint64  fetchedMs = 0;  // 0 = feed text only, never fetched in full
    };

    QString      videoDetailFilePath() const;
    void         loadVideoDetailCache();
    void         saveVideoDetailCache();
    void         noteVideoDescription(const QString &videoId, const QString &description);
    void         spawnVideoDetailFetch(const QString &videoId);
    QVariantMap  buildVideoDetail(const QString &videoId) const;

    QString      channelArtFilePath() const;
    void         loadChannelArtCache();
    void         saveChannelArtCache() const;

    // One yt-dlp run per channel, over its /videos tab, answering both of the
    // things a feed cannot: the durations of the videos on it and the channel's
    // own artwork. Queued when either is missing.
    bool         channelNeedsProbe(const QString &channelId) const;
    void         ensureChannelProbes(const QStringList &channelIds);
    void         spawnNextChannelProbe();

    QList<PlaylistFileRef> readPlaylistEntries(QString *error = nullptr) const;
    void         ensurePlaylistsFresh(bool forceRefresh);
    void         spawnNextPlaylistFetch();
    void         notePlaylistFailure(PlaylistEntry &entry);
    // Answers a waiting view out of what is already held, without taking the
    // request off the refresh running behind it. See the comment on it.
    void         servePlaylistsFromCache();
    void         finishPlaylistAggregate();
    QVariantList buildPlaylistList() const;

    // Last run's playlists, so entering the module is not a subprocess per list.
    QString      playlistCacheFilePath() const;
    void         loadPlaylistCache();
    void         savePlaylistCache() const;

    QString m_appRoot;
    QString m_dataRoot;
    QNetworkAccessManager m_nam;

    QHash<QString, ChannelEntry> m_channels;  // session cache, seeded from disk
    QStringList m_channelOrder;               // channel IDs in file order (deduped)
    QStringList m_feedQueue;                  // stale IDs waiting for a request slot
    int m_pendingChannels    = 0;
    int m_activeFeedFetches  = 0;
    bool m_feedCacheLoaded   = false;
    bool m_feedCacheDirty    = false;

    // How the current refresh pass is going, and how long the host has been told
    // to be left alone for. See noteFeedFailure() and ensureFresh().
    int    m_passSize             = 0;
    int    m_passFailures         = 0;
    qint64 m_networkPausedUntilMs = 0;

    // Emit-when-done flags: while one refresh is in flight, additional load
    // calls just queue their result signal on it instead of re-requesting.
    bool    m_emitFeedWhenDone     = false;
    bool    m_emitChannelsWhenDone = false;
    QString m_emitChannelVideosWhenDone;      // channelId, or empty

    // Playlist mirror of the channel cache/refresh state, fed by yt-dlp
    // subprocesses instead of RSS requests.
    QHash<QString, PlaylistEntry> m_playlists;
    QStringList m_playlistOrder;              // playlist IDs in file order (deduped)
    QStringList m_playlistFetchQueue;         // stale IDs waiting for a process slot
    int m_pendingPlaylists       = 0;
    int m_activePlaylistFetches  = 0;

    bool m_playlistCacheLoaded = false;
    bool m_playlistCacheDirty  = false;

    bool    m_emitPlaylistsWhenDone = false;
    QString m_emitPlaylistVideosWhenDone;     // playlistId, or empty

    // Channel avatars: base (unsized) URL per channel ID. An empty URL is a
    // channel whose page gave nothing — remembered for the session so it is not
    // retried on every entry, never written to disk, so the next run tries.
    // Duration and publish date per video ID, written once and kept — the reason
    // a list drawn from cache still has its runtimes. `asked` stops a video
    // yt-dlp gave no duration for (a live stream) re-queueing its channel.
    QHash<QString, VideoMeta> m_videoMeta;
    bool m_videoMetaDirty = false;

    // Descriptions and counts per video ID, and which videos a fetch is out
    // for — one screen is open at a time, so this stands in for a queue.
    QHash<QString, VideoDetail> m_videoDetail;
    QSet<QString> m_activeDetailIds;
    bool m_detailCacheLoaded = false;
    bool m_videoDetailDirty  = false;

    // Channels waiting for a probe, and the ones a probe is running for.
    QStringList   m_probeQueue;
    QSet<QString> m_activeProbeIds;

    QHash<QString, QString> m_channelArt;
    QHash<QString, qint64>  m_channelArtMs;   // when each was resolved
    bool m_artCacheLoaded   = false;
    bool m_artCacheDirty    = false;

    static constexpr qint64 kCacheTtlMs      = 15 * 60 * 1000;
    // Feeds go out a few at a time rather than all at once: thirteen requests
    // arriving together read as a burst to the host, and the list is drawn from
    // whichever arrive first anyway.
    static constexpr int    kMaxConcurrentFeedFetches = 3;
    // A channel whose feed just failed is left alone for a while, and longer
    // each time it fails again, to a ceiling.
    static constexpr qint64 kFeedRetryBackoffMs    = 5 * 60 * 1000;
    static constexpr qint64 kMaxFeedRetryBackoffMs = 30 * 60 * 1000;
    // When most of a pass fails at once it is not the channels — it is the host
    // refusing this address — so the whole module stops asking for a while.
    static constexpr int    kThrottleFailureCount = 3;
    static constexpr qint64 kThrottlePauseMs      = 15 * 60 * 1000;
    static constexpr int    kMaxFeedItems    = 100;
    // Per channel, on disk. A feed serves about 15, so this is headroom rather
    // than a limit anything reaches.
    static constexpr int    kMaxCachedFeedItems = 30;
    static constexpr int    kMaxHistoryItems = 100;
    static constexpr int    kMaxPlaylistItems = 500;             // caps infinite Mix/Radio lists
    static constexpr int    kMaxConcurrentPlaylistFetches = 2;   // yt-dlp is heavy on the Pi
    static constexpr int    kPlaylistFetchTimeoutMs = 60000;
    // Held far longer than a feed, for the reasons at the top of this file. The
    // number is what it is because the refresh is invisible now — a view is
    // answered from the cache first — so the only thing a longer window costs
    // is seeing a video added elsewhere a little later, and what it saves is a
    // subprocess per list every time somebody walks past the module.
    static constexpr qint64 kPlaylistCacheTtlMs = 2 * 60 * 60 * 1000;
    // A list that keeps failing is left alone for longer each time, to a
    // ceiling of one cache window — the same shape as the feed backoff.
    static constexpr qint64 kPlaylistRetryBackoffMs    = 10 * 60 * 1000;
    static constexpr qint64 kMaxPlaylistRetryBackoffMs = kPlaylistCacheTtlMs;
    // An avatar changes far less often than a feed does, and a stale one is a
    // recognisable face rather than a wrong one — so it is cached for a month.
    static constexpr qint64 kChannelArtTtlMs = 30LL * 24 * 60 * 60 * 1000;
    // A feed holds ~15 videos per channel, so 30 covers it with room for the
    // two lists disagreeing about shorts.
    static constexpr int    kMaxProbeItems = 30;
    // One at a time, a few per visit. Everything this backend asks for comes
    // from one host, which throttles an IP that wants a feed and a tab listing
    // for every channel at once — and the feeds are the part a view is actually
    // waiting on. Whatever is not probed this visit is probed on the next.
    static constexpr int    kMaxConcurrentProbes = 1;  // yt-dlp is heavy on the Pi
    static constexpr int    kMaxProbesPerPass    = 3;
    static constexpr int    kMaxVideoMetaItems   = 2000;
    // A description does not change, but a view count does — and the count is
    // the only part of the screen anyone would notice going stale. A day is
    // long enough that walking back into a video costs nothing and short
    // enough that the number is never wrong by much.
    static constexpr qint64 kVideoDetailTtlMs     = 24LL * 60 * 60 * 1000;
    // Descriptions are the largest thing this module keeps per video, so far
    // fewer are held than the one-line meta — enough for a browsing session.
    static constexpr int    kMaxVideoDetailItems  = 300;
    // Longest a description stays worth storing. Some are a wall of chapter
    // timestamps and affiliate links; the screen scrolls, but the file should
    // not carry ten kilobytes for one video.
    static constexpr int    kMaxDescriptionChars  = 4000;
    static constexpr int    kVideoDetailTimeoutMs = 30000;
};
