import QtQuick
import Components

// The screen a video gets before it plays: its description, the facts a list row
// has no room for, and what can be done with it. Laid out like
// modules/plex/views/Item.qml — art and buttons left, text beside them.
//
// Every list in the module lands here rather than in the Player, so the params
// are whatever that list held: a video map, plus the playlist name when it came
// out of one (which rides on to mpv's OSD).
FocusScope {
    id: videoRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var    item:         navParams.item || ({})
    property string playlistName: navParams.playlistName || ""
    // Which list this was opened out of, for the bar. The screen cannot work it
    // out for itself — every list reaches the same view — and without it the bar
    // would either repeat the channel the meta line already names or say nothing.
    property string sourceLabel:  navParams.sourceLabel || ""

    readonly property string videoId: item.videoId || ""
    readonly property string title:   item.title || ""

    // What the video's own page says. Served synchronously from whatever the
    // backend already holds — a channel feed carries the description, so a
    // video reached from Subscriptions has its text before the screen paints —
    // and replaced when the fuller answer lands. See load_video_detail().
    property var detail: youtubeBackend ? youtubeBackend.video_detail(videoId) : ({})
    readonly property string description: detail ? (detail.description || "") : ""
    // Only the fetch knows the counts, so their line is absent until it lands
    // rather than showing a zero.
    readonly property string viewText: detail ? (detail.viewText || "") : ""
    // True while the description is still the feed's and a fetch is out for the
    // rest. Nothing waits on it — it is what stops an empty screen claiming the
    // video simply has no description.
    property bool fetching: false

    // The channel this came from. Watch Later, History and playlists carry only
    // the name, so the ID — which is what an avatar and the channel screen are
    // reached by — is often the detail fetch's answer rather than the list's.
    readonly property string channelId:
        item.channelId || (detail ? (detail.channelId || "") : "")
    readonly property string channelName:
        item.channelName || (detail ? (detail.channelName || "") : "")

    // Runtime and age, worded by the backend so this screen states them the one
    // way the lists do. metaRev re-reads them when a duration probe lands.
    property int metaRev: 0
    readonly property string durationText:
        (metaRev >= 0 && youtubeBackend) ? youtubeBackend.video_duration_text(videoId) : ""
    readonly property string ageText:
        (metaRev >= 0 && youtubeBackend) ? youtubeBackend.video_age_text(videoId) : ""

    // The line under the title: who, how old, how long, how watched. Each part
    // is left out when it is not known, so nothing ever reads " -  - ".
    readonly property string metaText: {
        var parts = []
        if (channelName) parts.push(channelName)
        if (ageText)     parts.push(ageText)
        if (durationText) parts.push(durationText)
        if (viewText)    parts.push(viewText)
        return parts.join("  -  ")
    }

    // Where playback would pick up, for the button's wording. Read once: the
    // Player is what changes it, and coming back re-creates this screen.
    property int savedPositionMs: 0

    // Whether this video is saved, and the counter that makes the button
    // re-read it after it has been pressed.
    property int wlRev: 0
    readonly property bool inWatchLater:
        (wlRev >= 0 && youtubeBackend) ? youtubeBackend.isInWatchLater(videoId) : false

    // Art: the video's own thumbnail, which is the picture the list beside it
    // was showing and the one that identifies *this* video rather than its
    // channel. Only once decoded, so a thumbnail that never arrives leaves the
    // text at full width instead of a hole — the same test Plex's poster makes.
    readonly property string thumbUrl:
        (root.posterGrid && youtubeBackend) ? youtubeBackend.video_thumb_url(videoId) : ""
    readonly property bool showThumb: thumbImage.status === Image.Ready

    // Focus rows: 0 = play, 1 = watch later, 2 = the channel's own screen.
    // activeRows() is what Up/Down walks, so a row that is not offered is
    // simply absent rather than skipped over.
    property int focusRow: 0
    readonly property bool canOpenChannel: channelId !== ""

    function activeRows() {
        var rows = [0, 1]
        if (canOpenChannel) rows.push(2)
        return rows
    }

    function stepFocus(dir) {
        var rows = activeRows()
        var i = rows.indexOf(focusRow)
        if (i === -1) { focusRow = 0; return }
        focusRow = rows[(i + dir + rows.length) % rows.length]
    }

    function toggleWatchLater() {
        if (!videoId) return
        if (inWatchLater) youtubeBackend.removeFromWatchLater(videoId)
        else              youtubeBackend.addToWatchLater(videoId, title, channelName)
        wlRev++
    }

    function openVideo() {
        // The playlist rides along for mpv's OSD, which names it in the box a
        // Plex certificate goes in — nothing else on that screen would say
        // which list the video is being played out of.
        navigateTo("Player.qml", {
            item: videoRoot.item,
            playlistName: videoRoot.playlistName
        }, { focusRow: videoRoot.focusRow })
    }

    function openChannel() {
        if (!canOpenChannel) return
        navigateTo("Subscriptions.qml", {
            mode: "channel",
            channelId: videoRoot.channelId,
            channelName: videoRoot.channelName
        }, { focusRow: videoRoot.focusRow })
    }

    // ── Description scrolling ────────────────────────────────────────
    // A YouTube description is not a Plex summary: it runs to chapter lists and
    // link dumps, far past anything a fixed box shows. So it does both — it
    // scrolls itself, the way every other overflowing block in the app does,
    // until the user takes it over with Left/Right, after which it stays where
    // they left it.
    property bool descTouched: false
    readonly property real descOverflow:
        Math.max(0, descText.implicitHeight - descClip.height)

    function scrollDesc(dir) {
        if (descOverflow <= 0) return
        descTouched = true
        var step = descClip.height * 0.8
        descText.y = Math.max(-descOverflow, Math.min(0, descText.y - dir * step))
    }

    focus: true

    Keys.onUpPressed:    stepFocus(-1)
    Keys.onDownPressed:  stepFocus(1)
    Keys.onLeftPressed:  scrollDesc(-1)
    Keys.onRightPressed: scrollDesc(1)
    Keys.onReturnPressed: {
        if (focusRow === 0)      openVideo()
        else if (focusRow === 1) toggleWatchLater()
        else if (focusRow === 2) openChannel()
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        } else if (event.key === Qt.Key_Space) {
            // The same gesture the lists answer to, and it means the same thing
            // here: play, wherever the selection happens to be sitting.
            openVideo()
            event.accepted = true
        }
    }

    Component.onCompleted: {
        if (!videoId) { goBack(); return }
        var saved = youtubeBackend.getSavedPosition(videoId)
        savedPositionMs = saved.pos || 0
        focusRow = (navListState.focusRow !== undefined) ? navListState.focusRow : 0
        // Answers straight back with what is held, then again if a fetch finds
        // more — so this is both the initial fill and the request.
        fetching = true
        youtubeBackend.load_video_detail(videoId)
    }

    Connections {
        target: youtubeBackend

        function onVideoDetailLoaded(loadedId, loadedDetail) {
            if (loadedId !== videoRoot.videoId) return
            videoRoot.detail = loadedDetail
            // The first answer is whatever was cached; only a complete one ends
            // the wait, so a video with no description yet says so honestly.
            if (loadedDetail && loadedDetail.complete) videoRoot.fetching = false
        }

        function onVideoMetaLoaded() { videoRoot.metaRev++ }
    }

    // ---
    // UI
    // ---

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125  //60
        anchors.leftMargin: root.sw * 0.125 //80
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: videoRoot.sourceLabel
    }

    Item {
        id: body
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.2166667 //104
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875  //492
        height: root.sh * 0.6104167 //293
        clip: true

        Row {
            anchors.fill: parent
            spacing: root.sw * 0.0375 //24

            Column {
                id: buttonColumn
                width: root.sw * 0.1875 //120
                spacing: root.sh * 0.0125 //6

                // Thumbnail, above the buttons. The wrapper carries the gap and
                // collapses to nothing when there is no picture — a Column skips
                // invisible children, so the buttons sit at the top without one.
                Item {
                    visible: videoRoot.showThumb
                    width: parent.width
                    height: thumbImage.height + root.sh * 0.0104167 //5

                    Image {
                        id: thumbImage
                        source: videoRoot.thumbUrl
                        asynchronous: true
                        cache: true
                        // 16:9, fitted rather than cropped — a video thumbnail is
                        // the one shape this module never has to guess at.
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: root.sw * 0.1875 //120
                        width: parent.width
                        height: implicitWidth > 0 ? width * implicitHeight / implicitWidth : 0
                        anchors.top: parent.top
                    }

                    // How much of it has been watched, along its foot — the same
                    // rule the lists draw under the same picture, and the thing
                    // the RESUME below is offering to act on. Measured from the
                    // saved position this screen already read rather than asked
                    // for again; the runtime is what has to come from the cache.
                    Item {
                        readonly property real fraction: {
                            var rev = videoRoot.metaRev // re-runs when a probe lands
                            if (videoRoot.savedPositionMs <= 0 || rev < 0 || !youtubeBackend)
                                return 0
                            return youtubeBackend.video_progress(videoRoot.videoId)
                        }
                        visible: fraction > 0
                        width: thumbImage.width
                        height: root.sh * 0.0041667 //2
                        anchors.left: thumbImage.left
                        anchors.bottom: thumbImage.bottom

                        Rectangle {
                            anchors.fill: parent
                            color: root.watchedInk
                            opacity: 0.35
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * Math.min(1, parent.fraction)
                            color: root.watchedInk
                        }
                    }
                }

                // PLAY / RESUME
                Rectangle {
                    width: parent.width
                    height: root.sh * 0.1 //48
                    color: videoRoot.focusRow === 0 ? root.accentColor : root.surfaceColor
                    border.color: videoRoot.focusRow === 0 ? root.accentColor : root.tertiaryColor
                    border.width: root.sh * 0.003125 //2

                    Text {
                        anchors.centerIn: parent
                        text: videoRoot.savedPositionMs > 0 ? "RESUME ►" : "PLAY ►"
                        color: videoRoot.focusRow === 0 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.0458333 //22
                    }
                }

                // Watch later, worded by what pressing it would do.
                Rectangle {
                    width: parent.width
                    height: wlLabel.implicitHeight + root.sh * 0.025 //12
                    color: videoRoot.focusRow === 1 ? root.accentColor
                                                    : Qt.rgba(root.primaryColor.r, root.primaryColor.g,
                                                              root.primaryColor.b, 0.1)

                    Text {
                        id: wlLabel
                        anchors.centerIn: parent
                        text: videoRoot.inWatchLater ? "REMOVE FROM WATCH LATER" : "SAVE TO WATCH LATER"
                        color: videoRoot.focusRow === 1 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.025 //12
                        width: parent.width - root.sw * 0.0125 //8
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }

                // The channel's own screen, where the ID for it is known — off a
                // feed row always, and off a Watch Later or History row once the
                // detail fetch has said which channel that video is from.
                Rectangle {
                    visible: videoRoot.canOpenChannel
                    width: parent.width
                    height: channelLabel.implicitHeight + root.sh * 0.025 //12
                    color: videoRoot.focusRow === 2 ? root.accentColor
                                                    : Qt.rgba(root.primaryColor.r, root.primaryColor.g,
                                                              root.primaryColor.b, 0.1)

                    Text {
                        id: channelLabel
                        anchors.centerIn: parent
                        text: "VIEW CHANNEL"
                        color: videoRoot.focusRow === 2 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.025 //12
                    }
                }
            }

            Column {
                id: textColumn
                width: root.sw * 0.54375 //348
                height: parent.height
                topPadding: root.sh * 0.0083333 //4
                spacing: root.sh * 0.0125 //6

                // Title. Two lines rather than the one Plex elides at: a video
                // title routinely runs past a show's name, and the title is the
                // whole reason this screen was opened.
                Text {
                    width: parent.width
                    text: videoRoot.title
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    font.pixelSize: root.sh * 0.0416667 //20
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    lineHeight: 1.1
                }

                Text {
                    width: parent.width
                    text: videoRoot.metaText
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    font.pixelSize: root.sh * 0.0291667 //14
                    elide: Text.ElideRight
                }

                Item {
                    id: descClip
                    width: parent.width
                    // Whatever the title and meta line left of the column.
                    height: textColumn.height - y - root.sh * 0.0166667 //8
                    clip: true

                    Text {
                        id: descText
                        width: parent.width
                        y: 0
                        text: videoRoot.description !== "" ? videoRoot.description
                              : (videoRoot.fetching ? "LOADING DESCRIPTION..."
                                                    : "NO DESCRIPTION")
                        color: videoRoot.description !== "" ? root.primaryColor
                                                            : root.tertiaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.0291667 //14
                        wrapMode: Text.WordWrap
                        lineHeight: 1.3
                    }

                    // Reads itself until somebody takes it over. Slower per
                    // pixel than a title marquee and faster than Plex's summary
                    // crawl: there is a great deal more of it to get through.
                    SequentialAnimation {
                        running: !videoRoot.descTouched && videoRoot.descOverflow > 0
                        loops: Animation.Infinite
                        onRunningChanged: if (!running && !videoRoot.descTouched) descText.y = 0
                        PauseAnimation { duration: 3000 }
                        NumberAnimation {
                            target: descText; property: "y"
                            to: -videoRoot.descOverflow
                            duration: videoRoot.descOverflow * 45
                        }
                        PauseAnimation { duration: 4000 }
                        PropertyAction { target: descText; property: "y"; value: 0 }
                    }

                    // There is more below — the only thing on the screen that
                    // says the box is not the whole description.
                    Text {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        visible: videoRoot.descOverflow > 0
                                 && descText.y > -videoRoot.descOverflow + 1
                        text: "▼"
                        color: root.tertiaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.025 //12
                    }
                }
            }
        }
    }

    Text {
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
              + root.hints.change + ":SCROLL " + root.hints.play_pause + ":PLAY "
              + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        // Five hints, past the right edge of the 480p box at full size — see
        // the same note on Subscriptions.qml's footer.
        width: root.sw - x
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: root.sh * 0.0270833 //13
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
