import QtQuick

// Live TV player. A slimmed sibling of Player.qml — live channels have no
// resume/duration/seek/autoplay-next semantics, so this drops all of that. It
// tunes the selected channel, hands the HLS stream to mpv, and keeps the tuner
// alive with a timeline ping. To watch a different channel the user exits back to
// the channel list and picks another (in-player channel switching is not wired up
// yet — pending a maintainer discussion on how to route keys past mpv).
FocusScope {
    id: livePlayerRoot

    property var navParams: ({})

    signal navigateTo(string path, var params)
    signal goBack()

    // The channel to watch: { channelId, number, title }.
    property var    channel:   navParams.channel || ({})

    // What the guide says is on this channel now: {title, showTitle,
    // contentRating, endsAt}. Empty until the tune answers, and again whenever
    // the guide has nothing for the channel — the OSD names the channel then.
    property var    programme: ({})
    // When to ask the guide again, in epoch seconds. See the refresh Timer.
    property real   nextGuideCheck: 0

    property string sessionId:     ""
    property string streamUrl:     ""
    property string plexToken:     ""
    property bool   playbackStarted: false
    property bool   exiting:        false

    focus: true

    // The OSD's top line: what is on, falling back to the channel's own name
    // when the guide has nothing. An episode is named by its show first — a
    // programme title alone ("DEATH HAS A SHADOW") names nothing recognisable.
    function osdTitle() {
        var p = livePlayerRoot.programme
        if (p && p.title)
            return p.showTitle ? (p.showTitle + ": " + p.title) : p.title
        return livePlayerRoot.channel.title || ""
    }

    // The line beneath it: the channel the programme is on, written the way the
    // channel list writes it.
    function osdChannel() {
        var ch = livePlayerRoot.channel
        return (ch.number ? ch.number + "  " : "") + (ch.title || "")
    }

    // Everything the OSD's title block shows, pushed to a player that is already
    // up. Two things need it and neither is the launch: a guide answer that lands
    // mid-programme, and playback starting on an answer that arrived while mpv was
    // still coming up, with the launch file already written and no IPC socket yet
    // to hear it.
    function pushNowPlaying() {
        var p = livePlayerRoot.programme
        mpvController.updateNowPlaying(livePlayerRoot.osdTitle(),
                                       livePlayerRoot.osdChannel(),
                                       (p && p.contentRating) || "",
                                       Number((p && p.beginsAt) || 0),
                                       Number((p && p.endsAt) || 0))
    }

    function newSessionId() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var id = ""
        for (var i = 0; i < 12; i++) id += chars[Math.floor(Math.random() * chars.length)]
        return id
    }

    // Tune the channel. tune_channel resolves asynchronously through
    // onStreamUrlReady, which loads the resulting HLS stream into mpv.
    function tune() {
        if (!channel.channelId) { goBack(); return }
        playbackStarted = false
        programme = ({})
        sessionId = newSessionId()
        plexBackend.tune_channel(channel.channelId, sessionId)
    }

    function teardown() {
        if (exiting) return
        exiting = true
        plexBackend.stop_live_session(sessionId)
        mpvController.stop()
    }

    // Forward keys to mpv (the same set Player.qml forwards) so its OSC works on
    // the Pi, where the Qt app owns the keyboard and relays via sendKey. On desktop
    // mpv has focus and handles these directly. Up/Down drive the OSC here, not
    // channel changes — to switch channels the user exits back to the channel list.
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            // Quit mpv; onPlaybackEnded drives the teardown + goBack.
            mpvController.sendKey("ESC")
            event.accepted = true
        } else if (event.key === Qt.Key_Backspace) {
            mpvController.sendKey("BS")
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            mpvController.sendKey("UP")
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            mpvController.sendKey("DOWN")
            event.accepted = true
        } else if (event.key === Qt.Key_Left) {
            mpvController.sendKey("LEFT")
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            mpvController.sendKey("RIGHT")
            event.accepted = true
        } else if (event.key === Qt.Key_Space) {
            mpvController.sendKey("SPACE")
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            mpvController.sendKey("ENTER")
            event.accepted = true
        }
    }

    Connections {
        target: plexBackend

        function onStreamUrlReady(url, plexToken) {
            livePlayerRoot.streamUrl = url
            livePlayerRoot.plexToken = plexToken
            // Live always transcodes (HLS): no separate audio/sub tracks to pick.
            // The programme and channel name the OSD; the stream URL never would.
            // The station logo goes beside them, square and shown whole — the
            // shape and the fitting the browse screen's logo shelf uses, since it
            // is the same artwork. The guide's window is what the bar, the two
            // times and the "ENDS" line measure, which a live stream's own
            // length never could — it has none. Blank at this point (the tune
            // does not carry one); the guide asked for below fills it in.
            var ch = livePlayerRoot.channel
            var p  = livePlayerRoot.programme
            mpvController.setNowPlaying(livePlayerRoot.osdTitle(),
                                        livePlayerRoot.osdChannel(),
                                        plexBackend.live_channel_logo_url(ch),
                                        (p && p.contentRating) || "",
                                        "", 1.0, true,
                                        Number((p && p.beginsAt) || 0),
                                        Number((p && p.endsAt) || 0))
            mpvController.setNowPlayingSource(plexBackend.get_active_server_name(),
                                              plexBackend.get_active_user_name())
            mpvController.loadAndPlay(url, 0, 0, -1, [], [], false, -1, 0.0, plexToken)
            // The tune named the programme but could not say when it ends, so the
            // guide is asked now rather than on the refresh Timer's first tick —
            // that is the difference between "ENDS 22:30" appearing with the OSD
            // and appearing a minute into the programme.
            plexBackend.load_live_programme(livePlayerRoot.channel)
        }

        // The tune answers first, with the airing it grabbed; the guide answers
        // next, with the window that airing actually runs to; the refresh Timer
        // asks for each programme after that.
        function onLiveProgrammeLoaded(programme) {
            var p = programme || ({})
            // An empty answer means the guide does not know, not that nothing is
            // on. The tune has already named this programme, and replacing that
            // name with the bare channel would lose information rather than
            // correct it — so an answer with nothing in it only reschedules.
            if (p.title) livePlayerRoot.programme = p

            var now  = Date.now() / 1000
            var ends = Number(livePlayerRoot.programme.endsAt || 0)
            // A guide with nothing on this channel is asked again in ten minutes,
            // not in one: an EPG missing a listing now rarely gains one in a hurry.
            livePlayerRoot.nextGuideCheck = (ends > now) ? ends : (now + 600)
            // Before playback starts the launch's own setNowPlaying carries this,
            // and onPositionChanged pushes anything that landed in between.
            if (livePlayerRoot.playbackStarted) pushNowPlaying()
        }

        function onErrorOccurred(msg) {
            console.log("[LivePlayer] Backend error: " + msg)
            // A tune/stream failure leaves nothing playing — bail back to the list.
            if (!playbackStarted) { teardown(); goBack() }
        }
    }

    Connections {
        target: mpvController

        function onPositionChanged(ms) {
            if (ms <= 0 || livePlayerRoot.playbackStarted) return
            livePlayerRoot.playbackStarted = true
            // The guide is asked as soon as the stream is handed over, so its
            // answer often beats mpv's first frame — at which point there was no
            // socket to push it down. There is now.
            pushNowPlaying()
        }

        function onPlaybackEnded(finalPositionMs, finalDurationMs, reason) {
            // Any end (user quit, stream failure, or rare eof) tears down the tuner
            // and returns to the channel list.
            teardown()
            goBack()
        }
    }

    // Keep-alive: Plex reaps the DVR grab (and then 404s the stream) if the client
    // stops reporting the timeline. Ping from the moment we're tuned — not gated on
    // playbackStarted — since the grab is rolling before mpv reports its first frame.
    // update_live_timeline no-ops until a channel is tuned.
    Timer {
        interval: 8000
        repeat:   true
        running:  true
        onTriggered: plexBackend.update_live_timeline("playing")
    }

    // The guide moves on while the channel stays put. Checked once a minute
    // against the airing's own end time rather than scheduled to it: a programme
    // that runs over — live sport, a rolling news bulletin — would leave a
    // one-shot timer waiting on a listing that had not started yet.
    Timer {
        interval: 60000
        repeat:   true
        running:  livePlayerRoot.playbackStarted
        onTriggered: {
            if (Date.now() / 1000 < livePlayerRoot.nextGuideCheck) return
            // Held off for a minute so a slow guide is not asked twice; the
            // answer sets the real next check.
            livePlayerRoot.nextGuideCheck = Date.now() / 1000 + 60
            plexBackend.load_live_programme(livePlayerRoot.channel)
        }
    }

    Component.onCompleted: tune()

    // Black backdrop + loading text, shown until mpv's window takes over (mirrors
    // Player.qml).
    Rectangle {
        anchors.fill: parent
        color: "black"

        Text {
            text: "TUNING " + ((livePlayerRoot.channel.number
                                 ? livePlayerRoot.channel.number + "  " : "")
                               + (livePlayerRoot.channel.title || "")) + "..."
            color: "white"
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.centerIn: parent
            font.pixelSize: root.sh * 0.05 //24
            visible: !livePlayerRoot.playbackStarted
        }
    }
}
