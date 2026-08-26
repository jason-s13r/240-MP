#pragma once
#include <QObject>
#include <QVariant>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QTimer>
#include <QJsonObject>
#include <QJsonArray>
#include <QHash>
#include <functional>
#include <openssl/evp.h>

class PlexBackend : public QObject {
    Q_OBJECT
public:
    explicit PlexBackend(const QString &appRoot, const QString &dataRoot, QObject *parent = nullptr);

    // Sync — no HTTP
    Q_INVOKABLE QString  get_auth_state();
    Q_INVOKABLE QString  get_active_user_name();
    Q_INVOKABLE QString  get_active_server_name();
    Q_INVOKABLE QVariantList get_switchable_servers();
    Q_INVOKABLE void     build_stream_url(const QString &ratingKey,
                                          const QString &partKey,
                                          const QString &sessionId);
    // Poster art URL for an item map (formatItem/buildItemDetail shape), sized
    // by the server. Takes the whole item, not a thumb string, so the "which
    // artwork for this type" rule lives in one place. Empty when the item has
    // no art or no server is active — callers fall back to a text layout.
    //
    // context picks two independent things — which artwork an episode gets, and
    // whether it is cropped to fill the box or fitted whole inside it:
    //   "grid"   — its show's poster, cropped; a wall of cells reads as one shelf
    //   "shelf"  — most specific art (own still → season → show), cropped
    //   "detail" — the same most-specific art, fitted whole
    //   "badge"  — the cover art *around* an episode (season, else show), never
    //              its own still: the overlay that names the show
    Q_INVOKABLE QString  poster_url(const QVariantMap &item, int width, int height,
                                    const QString &context = QStringLiteral("grid")) const;

    // The shape of the art poster_url would return for this item and context:
    // 16:9 for an episode still, 2:3 for cover art. A shelf asks so it can cut
    // each cell to its own art and crop nothing — which is why this has to come
    // from here, where the fallback chain is, and not be guessed in QML.
    Q_INVOKABLE double   poster_aspect(const QVariantMap &item,
                                       const QString &context = QStringLiteral("grid")) const;

    // Auth flow
    Q_INVOKABLE void start_pin_auth();
    Q_INVOKABLE void load_users_from_cache();
    // pin is only supplied on a retry, after plex.tv has told us the profile
    // needs one (see userPinRequired). It is never stored.
    Q_INVOKABLE void select_user(const QString &userId, const QString &pin = QString());
    Q_INVOKABLE void reauth_select_user(const QString &userId, const QString &pin = QString());
    // Set when a switch was refused for want of a PIN on a path that has no UI to
    // prompt from (the current_user_id setting); Root.qml drains it on module entry.
    Q_INVOKABLE QString pending_pin_user() const { return m_pendingPinUserId; }
    Q_INVOKABLE void    cancel_pending_pin();
    Q_INVOKABLE void select_server(const QString &machineId);
    Q_INVOKABLE void logout();

    // Browse
    Q_INVOKABLE void load_libraries();
    Q_INVOKABLE void load_continue_watching();
    Q_INVOKABLE void load_section_hubs(const QString &sectionId);
    Q_INVOKABLE void load_items_for_hub(const QString &hubKey);
    Q_INVOKABLE void load_library_all(const QString &sectionId);
    Q_INVOKABLE void load_collections(const QString &sectionId);
    Q_INVOKABLE void load_collection_items(const QString &ratingKey);
    Q_INVOKABLE void load_playlists(const QString &sectionId);
    Q_INVOKABLE void load_playlist_items(const QString &ratingKey);
    Q_INVOKABLE void load_categories(const QString &sectionId);
    Q_INVOKABLE void load_category_items(const QString &sectionId, const QString &filterKey);
    Q_INVOKABLE void check_section_capabilities(const QString &sectionId);
    Q_INVOKABLE void load_children(const QString &ratingKey);
    // Loads the extras (trailers, deleted scenes, …) attached to an item and
    // emits extrasLoaded with a list of playable details (buildItemDetail shape
    // plus extraTypeLabel). Emits an empty list on failure — extras are an
    // enhancement, so errors must not disturb the detail views' main flows.
    Q_INVOKABLE void load_extras(const QString &ratingKey);
    Q_INVOKABLE void load_on_deck_for(const QString &ratingKey);
    // Resolves the next episode in the same season as currentRatingKey and emits
    // nextEpisodeReady with a full playable detail (same shape as load_item_detail),
    // or an empty map when there is no next episode / on any failure.
    Q_INVOKABLE void load_next_episode(const QString &currentRatingKey);

    // Looks up a show's year by its ratingKey, for naming an NFC card written
    // from an episode: an episode carries only its own air year and Plex sends no
    // grandparentYear, so the show must be fetched. Answers from cache when it
    // can, and emits showYearReady(showRatingKey, year) either way; year is 0
    // when the show has none. Callers should only ask when they will use it.
    Q_INVOKABLE void load_show_year(const QString &showRatingKey);

    // Playback
    Q_INVOKABLE void load_item_detail(const QString &ratingKey);
    // Resolves an NFC card's Plex guid to a playable item detail (same shape as
    // load_item_detail) and emits cardItemReady, or cardError with a message the
    // UI can show verbatim. mode is "shuffle" for a jukebox-style show/season card
    // and empty otherwise; it is ignored for movies and episodes. See the
    // implementation comment for why resolution is a single unscoped guid query.
    Q_INVOKABLE void resolve_card(const QString &guid, const QString &mode);
    // Next episode for a shuffle card, drawn from a shuffle bag over the card's
    // show/season. Emits nextEpisodeReady (the same signal autoplay already
    // consumes) or an empty map, so the Player advances identically either way.
    Q_INVOKABLE void load_random_episode(const QString &scopeRatingKey);
    Q_INVOKABLE void request_transcode(const QString &ratingKey, const QString &partKey,
                                       const QString &sessionId,
                                       const QString &audioId, const QString &subtitleId,
                                       int offsetMs);
    Q_INVOKABLE void update_timeline(const QString &ratingKey, const QString &partKey,
                                     const QString &state, int timeMs, int durationMs);
    Q_INVOKABLE void set_audio_stream(const QString &streamId, const QString &partId);
    Q_INVOKABLE void set_subtitle_stream(const QString &streamId, const QString &partId);

    // Live TV — minimal "watch live channels" support (no DVR/recording features).
    // load_live_channels lists the channel lineup of the first available DVR;
    // tune_channel allocates a tuner + HLS transcode session and emits streamUrlReady;
    // update_live_timeline keeps that tuner alive (state "playing") or releases it
    // (state "stopped"). The grabbed media key is remembered between calls.
    Q_INVOKABLE void load_live_channels();
    // Logo for one channel of that lineup, or empty when the EPG has none —
    // callers fall back to the channel's name. Takes the channel map rather
    // than a thumb string, matching poster_url.
    Q_INVOKABLE QString live_channel_logo_url(const QVariantMap &channel) const;
    Q_INVOKABLE void tune_channel(const QString &channelId, const QString &sessionId);
    // What is on that channel right now, per the DVR's guide. Answers with
    // liveProgrammeLoaded — an empty map when the guide lists nothing for the
    // channel, so a caller can fall back to the channel's own name. Takes the
    // channel map rather than an id, like live_channel_logo_url: which of the
    // channel's names the guide files its airings under varies by EPG provider,
    // so the match is tried against all of them.
    Q_INVOKABLE void load_live_programme(const QVariantMap &channel);
    Q_INVOKABLE void update_live_timeline(const QString &state);
    // Stops the live transcode for sessionId and forgets the tuned key, so the
    // server can release the tuner. Called on exit and before a channel change.
    Q_INVOKABLE void stop_live_session(const QString &sessionId);

    // Settings dynamic options
    Q_INVOKABLE void getUsers();
    Q_INVOKABLE void getServers();
    Q_INVOKABLE void getLibraries();
    Q_INVOKABLE void getVideoQualities();
    Q_INVOKABLE void get_resume_playback_options();
    Q_INVOKABLE void applyCurrentUserSetting();
    Q_INVOKABLE void applyCurrentServerSetting();
    Q_INVOKABLE void reset_device_check();

signals:
    void pinReady(const QString &code, const QString &pinId);
    void authSuccess();
    void usersLoaded(const QVariant &users);
    void serversLoaded(const QVariant &servers);
    void logoutComplete();
    void authStateChanged();
    void authRevoked();
    // plex.tv refused the user switch until we supply the profile's PIN.
    // wrongPin distinguishes "we haven't asked yet" from "that PIN was wrong".
    void userPinRequired(const QString &userId, bool wrongPin);

    void librariesLoaded(const QVariant &libraries);
    void continueWatchingLoaded(const QVariant &items);
    void hubsLoaded(const QVariant &hubs);
    void itemsLoaded(const QVariant &items);
    void collectionsLoaded(const QVariant &collections);
    void playlistsLoaded(const QVariant &playlists);
    void categoriesLoaded(const QVariant &categories);
    void capabilitiesLoaded(const QVariant &capabilities);

    void itemLoaded(const QVariant &detail);
    void showYearReady(const QString &showRatingKey, int year);
    void streamUrlReady(const QString &url, const QString &plexToken);
    void childrenLoaded(const QVariant &items);
    void extrasLoaded(const QVariant &items);
    void inProgressEpisodeLoaded(const QVariant &item);
    void nextEpisodeReady(const QVariant &detail);
    void cardItemReady(const QVariant &detail);
    void cardError(const QString &message);

    void liveChannelsLoaded(const QVariant &channels);
    // The airing on a live channel now: {title, showTitle, contentRating, endsAt},
    // endsAt being epoch seconds so the caller knows when to ask again. Empty when
    // the guide has nothing to say. Emitted by tune_channel for the airing it
    // grabbed, and by every load_live_programme.
    void liveProgrammeLoaded(const QVariant &programme);

    void dynamicOptionsReady(const QString &key, const QVariant &options);

    void errorOccurred(const QString &message);

private:
    // Auth file I/O
    QJsonObject loadAuth() const;
    void saveAuth(const QJsonObject &auth) const;

    // Config file helpers (shared with AppCore)
    QJsonObject loadConfig() const;
    void saveConfig(const QJsonObject &cfg) const;

    // Plex HTTP helpers
    QNetworkRequest plexRequest(const QUrl &url, const QString &token) const;
    QNetworkReply  *plexGet(const QUrl &url, const QString &token);
    QNetworkReply  *plexPost(const QUrl &url, const QString &token);
    QNetworkReply  *plexPut(const QUrl &url, const QString &token);
    QNetworkReply  *plexDelete(const QUrl &url, const QString &token);

    // Convenience SSL-ignore connect
    void ignoreSslErrors(QNetworkReply *reply);

    // Drops items belonging to a library the user has switched off in the
    // Libraries setting. Server-wide endpoints (continue watching) answer for
    // every section, so their results are filtered here.
    QVariantList enabledLibraryItems(const QVariantList &items) const;

    // Auth state accessors (read from in-memory / file)
    // Which of thumb / parentThumb / grandparentThumb poster_url would use.
    // Empty when the item carries none of them.
    QString artworkKey(const QVariantMap &item, const QString &context) const;

    QString serverUrl() const;
    QString serverToken() const;
    QString accountToken() const;
    QString userToken() const;
    QString videoQuality() const;
    QString clientId() const;   // UUID, stored in plex_auth.json

    // Live TV guide helpers. fetchLiveProgramme is load_live_programme once the
    // EPG provider is known; the other two read one guide airing.
    void fetchLiveProgramme(const QString &providerId, const QVariantMap &channel);
    // One EPG airing as liveProgrammeLoaded carries it. Empty when the object is
    // not an airing (a tune that produced no listing, a stray container entry).
    static QVariantMap airingProgramme(const QJsonObject &meta);
    // Whether an airing is on the given channel. The guide names the channel on
    // the airing's Media entries, under a field that differs between EPG
    // providers, so any of them matching any of the channel's names is a match.
    static bool airingIsOnChannel(const QJsonObject &meta, const QVariantMap &channel);

    // Item formatting helpers
    QVariantMap formatItem(const QJsonObject &m) const;
    // Builds the full playable detail map (streams, selections, transcode flag)
    // from a single /library/metadata Metadata object. Shared by load_item_detail
    // and load_next_episode.
    QVariantMap buildItemDetail(const QJsonObject &meta) const;
    // Returns the server-side file path of a metadata object's first media part,
    // or an empty string when unavailable. Used to detect stacked multi-episode
    // files (several episode entries backed by one physical file).
    static QString mediaFilePath(const QJsonObject &meta);
    static QString msToDisplay(int ms);

    // Expands any season-type items in rawItems into their child episodes, then calls callback.
    // Order is preserved. callback is called synchronously if no seasons are present.
    void flattenSeasons(const QVariantList &rawItems, std::function<void(const QVariantList &)> callback);

    // NFC card resolution helpers.
    void fetchChildren(const QString &ratingKey,
                       std::function<void(const QVariantList &)> callback);
    // Every episode under a show or season, in season/episode order. Works for
    // both: flattenSeasons is a no-op when the children are already episodes.
    void fetchEpisodePool(const QString &scopeRatingKey,
                          std::function<void(const QVariantList &)> callback);
    // Chooses the episode a show/season card plays in on-deck mode: first
    // in-progress, else first unwatched, else the first episode.
    static QVariantMap pickOnDeckEpisode(const QVariantList &pool);
    // Draws the next ratingKey from the shuffle bag for this scope, rebuilding
    // and reshuffling when the scope changes or the bag runs out.
    QString takeFromShuffleBag(const QString &scopeRatingKey, const QVariantList &pool);
    void emitCardDetail(const QString &ratingKey, bool trackProgress,
                        const QString &scopeRatingKey);
    void emitNextEpisode(const QString &ratingKey);

    // Shuffle-card state. A bag (a shuffled permutation played to exhaustion,
    // then reshuffled) rather than independent random draws: independent draws
    // clump badly over a long session, and shuffle cards report no timeline, so
    // there is no watched state to fall back on for variety. Caching the bag also
    // means a multi-season show costs one pool fetch per cycle, not per episode.
    QString     m_shuffleScope;
    QStringList m_shuffleBag;
    QString     m_lastShuffledKey;

    // showRatingKey -> year, so revisiting a show's episodes costs one lookup.
    // Cleared on a server switch, since ratingKeys are server-local.
    QHash<QString, int> m_showYears;

    // Connection probing
    void probeConnections(const QJsonArray &connections,
                          std::function<void(QString)> callback);
    void probeNext(const QList<QString> &uris, int index,
                   std::function<void(QString)> callback);

    // Browse implementation (separated so startup check can wrap it)
    void load_libraries_impl();

    // User activation — single path for all three switch callers
    bool isAccountOwner(const QString &userId) const;
    static QJsonObject homeUserEntry(const QJsonObject &rawUser);
    QJsonObject cachedUser(const QString &userId) const;
    // Checks the profile's PIN gate (live, not cached) and then switches.
    void activateUser(const QString &userId, const QString &pin,
                      std::function<void(const QVariantList &accessibleServers)> callback);
    void performUserSwitch(const QString &userId, const QString &pin,
                           std::function<void(const QVariantList &accessibleServers)> callback);

    // User the current_user_id setting selected but whose switch needs a PIN.
    QString m_pendingPinUserId;

    // PIN auth
    void pollPinTick();
    void fetchUsersAndServers(const QString &token);

    // Logout helpers
    void deleteDeviceThenAuth(const QString &token, std::function<void()> finish);

    // JWT key management
    QByteArray  generateAndSaveKeyPair(const QString &keyId);  // returns JWK JSON bytes
    EVP_PKEY*   loadPrivateKey() const;                        // caller must EVP_PKEY_free

    // JWT building + signing
    QString     buildDeviceJwt(EVP_PKEY *key, const QString &keyId,
                                const QString &nonce = {}) const;
    static qint64  jwtExpClaim(const QString &jwt);
    static QString jwtUserIdClaim(const QString &jwt);         // parse user.id from JWT payload

    // Auth lifecycle
    void checkAndRefreshOnStartup(std::function<void()> callback);
    void migrateLegacyToken(std::function<void()> callback);
    void refreshJwt(std::function<void(bool ok)> callback);

    // 498 retry
    void handle498(std::function<void()> retryOp);

    // HTTP helper — POST with JSON body
    QNetworkReply* plexPostJson(const QUrl &url, const QString &token, const QByteArray &body);

    QString m_appRoot;
    QString m_dataRoot;
    QNetworkAccessManager *m_nam;
    QTimer *m_pollTimer;
    QString m_pendingPinId;
    QString m_clientId;          // cached after first load
    bool    m_refreshInFlight  = false;
    bool    m_deviceVerified   = false; // set after first successful plex.tv check per session
    bool    m_serverAuthRetried = false; // guards the one-shot token re-fetch on a PMS 401

    // Live TV session state. m_liveDvrId is cached from the last load_live_channels.
    // The rest are set by tune_channel and drive the timeline keep-alive that stops
    // Plex from reaping the DVR grab (which would 404 the stream after a few
    // minutes): m_liveTimelineKey is the grabbed live-session key, m_liveRatingKey
    // and m_liveDurationMs identify the airing, m_liveSessionId ties the timeline to
    // the transcode session, and m_liveStartedMs gives the keep-alive an advancing
    // playback time.
    QString m_liveDvrId;
    // The EPG media provider that proxies the lineup and guide routes, cached
    // from whichever call last had to look it up.
    QString m_liveProviderId;
    QString m_liveTimelineKey;
    QString m_liveRatingKey;
    QString m_liveSessionId;
    int     m_liveDurationMs = 0;
    qint64  m_liveStartedMs  = 0;
};
