#pragma once
#include <QObject>
#include <QProcess>
#include <QLocalSocket>
#include <QTimer>
#include <QJsonArray>
#include <QStringList>

class QNetworkAccessManager;

class AppCore;
class DisplayHandoff;

class MpvController : public QObject {
    Q_OBJECT
    Q_PROPERTY(int position    READ position    NOTIFY positionChanged)
    Q_PROPERTY(int duration    READ duration    NOTIFY durationChanged)
    Q_PROPERTY(int playlistPos READ playlistPos NOTIFY playlistPosChanged)

public:
    explicit MpvController(const QString &appRoot, const QString &dataRoot,
                           AppCore *appCore = nullptr,
                           DisplayHandoff *handoff = nullptr,
                           QObject *parent = nullptr);
    ~MpvController() override;

    int position()    const { return m_position;    }
    int duration()    const { return m_duration;    }
    int playlistPos() const { return m_playlistPos; }

    Q_INVOKABLE void loadAndPlay(const QString &url, float startSeconds,
                                  int audioTrack, int subTrack,
                                  const QStringList &subFiles = {},
                                  const QStringList &subLangs = {},
                                  bool loop = false,
                                  int playlistStart = -1,
                                  float transcodeOffsetSec = 0.0f,
                                  const QString &plexToken = {},
                                  bool muteAudio = false,
                                  const QString &oscMode = {},
                                  bool shuffle = false,
                                  const QStringList &subTitles = {},
                                  float imageDurationSec = 0.0f,
                                  bool imageContent = false,
                                  const QStringList &extraArgs = {},
                                  const QString &jellyfinToken = {},
                                  const QStringList &extraUrls = {});
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seekTo(int positionMs);
    Q_INVOKABLE void sendKey(const QString &key);
    // What is about to play, as the OSC's top-left block names it: the item's own
    // title, the show or channel it belongs to underneath (empty for a movie),
    // and cover art beside them (empty when the module has none).
    //
    // Call it immediately before loadAndPlay(): a stream URL tells mpv nothing
    // (Plex and Jellyfin hand out master.m3u8). Consumed and cleared by the next
    // launch, so a caller that sets nothing gets mpv's own media-title rather
    // than the last item's. Not for playlists — the title it forces would pin
    // one name over every entry.
    //
    // Right-aligned on that second line is one of two things, never both: a
    // certificate, boxed the way a rating card is, or a plain label for a module
    // with no certificate (YouTube names the playlist there). A rating wins if
    // both are set.
    //
    // The art is shown only while the app-level "Poster Grid" setting is on —
    // with it off nothing in the app draws cover art, the OSD included — so a
    // caller hands over whatever it has and the controller decides.
    //
    // posterAspect is the shape the art is drawn in, width over height: 0 keeps
    // the 2:3 of cover art; a module handing over something else says so (1 for
    // an avatar, 16/9 for a thumbnail) so the OSC reserves a box of that shape.
    //
    // fitPoster draws the art whole inside that box instead of cropping it to
    // fill: cover art of any shape may lose its edges, but a station logo cannot
    // — cropping a wide one to a square cuts the name out of it. The same rule
    // the browse screen's logo cells follow.
    //
    // airingBeginsAt/airingEndsAt are when the programme runs from and to, as
    // epoch seconds — the guide's window, which for a live channel is the only
    // length there is. A file needs neither: mpv knows how long it is, and the
    // OSC measures the seek bar, the two times and "ENDS 21:45" against that.
    // A live stream has no length at all, so a channel hands over the window
    // instead and the OSC measures the programme. Both 0 (the default) leaves
    // the OSC reading mpv.
    Q_INVOKABLE void setNowPlaying(const QString &title,
                                   const QString &showTitle = {},
                                   const QString &posterUrl = {},
                                   const QString &contentRating = {},
                                   const QString &label = {},
                                   double posterAspect = 0.0,
                                   bool fitPoster = false,
                                   qint64 airingBeginsAt = 0,
                                   qint64 airingEndsAt = 0);

    // A title block that changes while one stream keeps playing: a live channel
    // rolls from one programme to the next without mpv ever loading a file. The
    // fields that can change with it, pushed to the OSC of the running player —
    // the name, the mark, and the window it runs across. The art is not among
    // them, because what it shows (the channel) has not changed. A no-op when
    // nothing is playing.
    //
    // Also re-anchors where the stream sits inside the programme, which only
    // this side can work out: it takes the wall clock and how far mpv has
    // actually played, and mpv's clock is the one that stops when the viewer
    // pauses. See the "join offset" note in the .cpp.
    Q_INVOKABLE void updateNowPlaying(const QString &title,
                                      const QString &showTitle = {},
                                      const QString &contentRating = {},
                                      qint64 airingBeginsAt = 0,
                                      qint64 airingEndsAt = 0);

    // The server and profile the app's own corner shows on every browse screen.
    // Separate from setNowPlaying because it says nothing about the item — it is
    // the session. Same one-launch lifetime, so a module that does not set it
    // gets a corner with only the clock rather than the last one's.
    Q_INVOKABLE void setNowPlayingSource(const QString &server,
                                         const QString &profile);
    Q_INVOKABLE void showOsdSkipPrompt();
    Q_INVOKABLE void clearOsdPrompt();

    // True only on devices whose smooth-playback decode path can't crop/zoom (the
    // Pi 3 DRM-overlay path). Settings uses this to show the "Smooth Playback"
    // toggle only where the smoothness-vs-crop trade-off actually exists.
    Q_INVOKABLE bool hasSmoothPlaybackTradeoff() const;

    // Which display fullscreen playback should open on, matching the UI's
    // app-level "display_index" (index into QGuiApplication::screens(), plus
    // that screen's QScreen::name()). main.cpp calls this once at startup;
    // index 0 (the default) adds no mpv args at all. Desktop launches only —
    // the headless VT-handoff path is unaffected.
    void setTargetDisplay(int index, const QString &screenName);

signals:
    void positionChanged(int ms);
    void durationChanged(int ms);
    void playlistPosChanged(int pos);
    // Emitted exactly once when mpv exits, with the reason it ended:
    //   "eof"     — file played to its natural end. (What a module does with this
    //               is its own concern.  as an example: Plex may autoplay the next episode)
    //   "stopped" — user quit/stopped before the end (also the safe default for a
    //               crash/kill with no end-file event).
    //   "failed"  — mpv exited with an error (code 2 — file could not be played;
    //               Up to the module as to when/how to use; for example Plex retries when transcoding).
    // A single signal (rather than one per reason) is deliberate: a Player view
    // connects one handler and branches on `reason`, so it can never silently drop
    // a case the way an unhandled per-reason signal would.
    void playbackEnded(int finalPositionMs, int finalDurationMs, const QString &reason);

    void skipRequested();
    // The OSC's SUBTITLE button when the sub is burned into the stream and mpv
    // has nothing to cycle (see `sub-cycle` in scripts/mpv-osc.lua). The module
    // owns the change — typically stop, re-request the stream, relaunch.
    void subtitleCycleRequested();
    // The OSC's AUDIO button when the track is baked into the stream and mpv has
    // nothing to cycle (see `audio-cycle` in scripts/mpv-osc.lua). As above, the
    // module owns the change.
    void audioCycleRequested();

private slots:
    // The OSC asking for the poster at the pixel size it has room for — only it
    // knows the window's OSD resolution, and mpv's overlay-add cannot scale. See
    // the "240mp-poster-request" client-message in onIpcReadyRead.
    void requestPoster(int width, int height);
    void onProcessFinished();
    void tryConnectIpc();
    void onIpcReadyRead();

private:
    // Hardware video-decode profile, detected once from /proc/device-tree/model.
    enum class VideoProfile { Pi3, Pi4, PiFullKms, Generic };

    void sendCommand(const QJsonArray &args);
    VideoProfile detectVideoProfile() const;
    // Appends the profile-specific --vo/--gpu-context/--hwdec flags (honouring the
    // app-level "mpv_video_args" override) to a forming mpv argument list.
    void appendVideoArgs(QStringList &args) const;
    // App-level "smooth_playback" setting (default ON). On the Pi 3 this selects the
    // smooth zero-copy overlay path; turning it OFF restores the crop-capable scaler path.
    bool smoothPlaybackEnabled() const;
    // App-level "auto_crop" setting (default OFF). When ON, playback starts with
    // panscan=1 so video fills a CRT/4:3 screen by default (still toggleable live).
    bool autoCropEnabled() const;
    // App-level "poster_grid" setting (default OFF). When OFF the app browses as
    // text with no cover art, and the OSD's title block drops its art to match.
    bool posterGridEnabled() const;
    // True when the active decode path can't crop (Pi 3 overlay path with smooth
    // playback ON): --panscan blanks the video there. Gates auto-crop and tells
    // the OSC scripts to hide their CROP button.
    bool cropUnavailable() const;
    // App-level "video_output_levels" setting (default "Auto"). Returns the mpv
    // value for --video-output-levels ("limited"/"full"), or empty on Auto/unset.
    QString videoOutputLevels() const;

    // Owner token handed to DisplayHandoff, so the app can tell who has the screen.
    static constexpr const char *kHandoffOwner = "mpv";

    AppCore        *m_appCore      = nullptr;
    DisplayHandoff *m_handoff      = nullptr;
    VideoProfile  m_videoProfile  = VideoProfile::Generic;
    QProcess     *m_process        = nullptr;
    QLocalSocket *m_ipc            = nullptr;
    QTimer       *m_connectTimer   = nullptr;
    QTimer       *m_watchdogTimer  = nullptr;
    qint64        m_lastIpcEventMs = 0;
    bool          m_paused         = false;  // mirrors mpv's pause property (watchdog exemption)
    QString       m_appRoot;
    QString       m_dataRoot;
    QString       m_socketPath;
    QString       m_inputConfPath;
    QString       m_logFilePath;
    QString       m_subInfoPath;       // JSON map: external sub URL -> friendly name (for the OSC)
    QString       m_nowPlayingPath;    // JSON {show, title, poster} the OSC reads for its title block
    QString       m_posterDataPath;    // raw premultiplied BGRA the OSC hands to overlay-add
    // see setNowPlaying(); the first two are cleared by each launch, the URL is
    // kept for as long as the session lasts because the OSC asks for it later
    QString       m_pendingTitle;
    QString       m_pendingShowTitle;
    QString       m_pendingServer;
    QString       m_pendingProfile;
    QString       m_pendingPosterUrl;
    QString       m_pendingRating;
    QString       m_pendingLabel;
    double        m_pendingPosterAspect = 0.0;
    bool          m_pendingPosterFit    = false;
    qint64        m_pendingAiringBegins = 0;
    qint64        m_pendingAiringEndsAt = 0;
    QString       m_posterUrl;
    // see setNowPlaying(); kept alongside m_posterUrl because the OSC asks for
    // the art long after the launch that chose how to draw it
    bool          m_posterFit  = false;
    // Bumped on every launch. A poster fetch that finishes after the next file
    // has started belongs to the file before it — autoplay swaps episodes
    // without restarting the app — so its reply is dropped rather than putting
    // the previous episode's art on screen.
    quint64       m_playSession = 0;
    QNetworkAccessManager *m_nam = nullptr;  // lazily built, only if a poster is asked for
    QString       m_lastEndFileReason;  // mpv end-file "reason" for the current session
    // Set when this session passed --start; cleared once mpv has applied it. See
    // onIpcReadyRead's playback-restart handling for why the option can't just stay set.
    bool          m_pendingStartClear = false;
    int           m_position     = 0;
    int           m_duration     = 0;
    int           m_playlistPos  = -1;
    bool          m_headlessMode = false;
    int           m_displayIndex = 0;   // see setTargetDisplay()
    QString       m_displayScreenName;
    int           m_previousVt   = -1;
    bool          m_hasMpvOscScript     = false;
    bool          m_hasAmbientOscScript = false;
    bool          m_hasMediaKeysScript  = false;
};
