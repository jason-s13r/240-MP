import QtQuick
import Components

// Video list — serves the aggregated Subscriptions feed (mode "feed"), a single
// channel's videos (mode "channel"), a user playlist ("playlist"), the saved
// Watch Later list ("watchlater") and the recently-watched History list
// ("history"). Right on any row opens the save/remove watch-later overlay.
//
// With poster art on, every row carries the video's own thumbnail, and the
// channel and playlist modes take the shape of a Plex season
// (modules/plex/views/ItemSeason.qml): the channel's avatar, or the playlist's
// own cover, heads the screen with its name beside it and the list alongside.
FocusScope {
    id: itemsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property string mode: navParams.mode || "feed"
    property string channelId: navParams.channelId || ""
    property string channelName: navParams.channelName || ""
    property string playlistId: navParams.playlistId || ""
    property string playlistName: navParams.playlistName || ""

    property var items: []
    property bool isLoading: false
    property string errorMessage: ""

    // A thumbnail beside every row, in every mode — the rows are already two
    // lines tall, so the art costs no height and the titles stay where they are.
    // Slot width is reserved whether or not the image arrives, so they line up.
    readonly property bool rowArt: root.posterGrid
    readonly property real rowArtW: root.sw * 0.09375    //60 — a 16:9 thumb at rowArtH
    readonly property real rowArtH: root.sh * 0.0666667  //32
    // Where a row's text starts: past the art slot, plus the inset the rows
    // have always had — and what is left for it after both insets.
    readonly property real rowTextX: (rowArt ? rowArtW : 0) + root.sw * 0.0109375 //7
    readonly property real rowTextW: listW - rowTextX - root.sw * 0.0109375 //7
    function rowArtFor(m) {
        // The youtubeBackend guard is teardown safety: it reads back null while
        // the view's Loader unloads and every binding runs one last time.
        if (!rowArt || !m || !youtubeBackend) return ""
        return youtubeBackend.video_thumb_url(m.videoId || "")
    }
    // How much of a row's video has been watched, for the rule along the foot of
    // its thumbnail — the same reading the shelves draw, at row size. Reads
    // metaRev because a runtime landing is what turns a saved position into a
    // fraction (see YouTubeBackend::video_progress).
    function rowProgressFor(m) {
        var rev = metaRev // dependency: re-runs when a duration probe lands
        if (!rowArt || !m || rev < 0 || !youtubeBackend) return 0
        return youtubeBackend.video_progress(m.videoId || "")
    }
    // Two pixels, as on a shelf cell: the bar is the same mark whatever it is
    // drawn on, and at this size anything thicker is a band across the picture.
    readonly property real rowProgressH: root.sh * 0.0041667 //2

    // Runtime and age, under every row's title. A feed knows neither, so both
    // land late and metaLine() reads metaRev to re-run. Worded by the backend,
    // which is where the menu shelf reads them too.
    property int metaRev: 0

    // The left end of a row's under-title line: which channel it came from.
    // Dropped only where the header above is already saying it, which is
    // channel mode — a playlist mixes channels, so there the name is the whole
    // reason the line is there.
    function channelLine(m) {
        if (!m || (mode === "channel" && showPoster))
            return ""
        return m.channelName || ""
    }

    // The right end of that line: how old it is, then how long it runs — the
    // runtime last, hard against the row's right edge, so it is the column that
    // reads straight down the list. Either is left out when it is not known.
    function metaLine(m) {
        var rev = metaRev // dependency: re-runs when a duration probe lands
        if (!m || rev < 0 || !youtubeBackend)
            return ""
        var id = m.videoId || ""
        var parts = []
        var age = youtubeBackend.video_age_text(id)
        if (age)
            parts.push(age)
        var dur = youtubeBackend.video_duration_text(id)
        if (dur)
            parts.push(dur)
        return parts.join(" - ")
    }

    // One picture heads the screen: a channel's avatar or a playlist's cover.
    // Only those two modes have one — the rest are a mix of channels.
    //
    // Each arrives late in its own way, and a binding only re-runs on what it
    // reads: an avatar is announced by channelArtLoaded (counted in artRev), a
    // playlist's cover comes back with its videos, so that arrival is read.
    property int artRev: 0
    readonly property string headerArtUrl: {
        if (!root.posterGrid || !youtubeBackend)
            return ""
        if (mode === "channel")
            return (artRev >= 0)
                ? youtubeBackend.channel_art_url(channelId, Math.round(itemsRoot.posterW))
                : ""
        if (mode === "playlist")
            return (items.length >= 0) ? youtubeBackend.playlist_thumb_url(playlistId) : ""
        return ""
    }
    // The name that picture is headed by.
    readonly property string headerTitle:
        (mode === "playlist") ? playlistName : channelName
    // Only once the image is actually decoded, so a channel or playlist whose
    // art never resolved keeps the original full-width list rather than leaving
    // a hole.
    readonly property bool showPoster: posterImage.status === Image.Ready

    // Content-box geometry, matching ItemSeason.qml: the avatar takes the left
    // column and the list runs to the right of it, under the channel's name —
    // beneath the header it would not fit. Both branches are today's values.
    readonly property real contentTop:  root.sh * 0.2166667 //104
    readonly property real contentLeft: root.sw * 0.115625  //74
    readonly property real posterW:  root.sw * 0.1875    //120
    readonly property real sectionX: root.sw * 0.209375  //144 — poster column + gap
    readonly property real sectionW: root.sw * 0.54375   //348
    // The list is the width of that section under a header, and the width of
    // the screen without one.
    readonly property real listW: showPoster ? sectionW : root.sw * 0.76875 //492

    // What this list is called, for its own bar and for the bar of the video
    // screen it opens — which has no other way of knowing where it was reached
    // from.
    readonly property string sourceLabel:
          mode === "feed"       ? "Subscriptions"
        : mode === "watchlater" ? "Watch Later"
        : mode === "history"    ? "History"
        : mode === "playlist"   ? playlistName
                                : channelName

    // Watch-later overlay state
    property bool wlOverlayVisible: false
    property bool wlRemoveMode: false
    property int wlChoiceIndex: 0   // 0 = yes, 1 = no

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    // `at` is where to land: the saved position when the screen is opened, and
    // for a list that can arrive more than once — a cached playlist, then the
    // refresh behind it — wherever the user actually is, captured before the
    // new array resets the view to the top.
    function restoreListIndex(at) {
        if (items.length === 0)
            return
        var restore = (at !== undefined)                       ? at
                    : (navListState.currentIndex !== undefined) ? navListState.currentIndex
                                                                : 0
        itemList.currentIndex = Math.min(restore, items.length - 1)
        itemList.positionViewAtIndex(itemList.currentIndex, ListView.Contain)
    }

    // What the row carries: the video, the list it is read out of, and — for a
    // playlist — its name, which rides all the way to mpv's OSD, since nothing
    // else there would say which list the video is playing out of.
    function selectedParams() {
        var selected = itemsRoot.items[itemList.currentIndex]
        if (!selected)
            return null
        return {
            item: selected,
            sourceLabel: itemsRoot.sourceLabel,
            playlistName: (itemsRoot.mode === "playlist") ? itemsRoot.playlistName : ""
        }
    }

    // Return opens the video's own screen — its description and what can be
    // done with it — and the Player is one press further on from there.
    function openSelected() {
        var params = selectedParams()
        if (params)
            navigateTo("Video.qml", params, { currentIndex: itemList.currentIndex })
    }

    // Space skips it and plays. The info screen is the right thing for Return
    // to do, but a feed is also something people flick down and start, and that
    // should not have cost a second press.
    function playSelected() {
        var params = selectedParams()
        if (params)
            navigateTo("Player.qml", params, { currentIndex: itemList.currentIndex })
    }

    function openWatchLaterOverlay() {
        var it = items[itemList.currentIndex]
        if (!it)
            return
        wlRemoveMode = (mode === "watchlater") || youtubeBackend.isInWatchLater(it.videoId)
        wlChoiceIndex = 0
        wlOverlayVisible = true
    }

    function applyWatchLaterChoice() {
        if (wlChoiceIndex === 0) {
            var it = items[itemList.currentIndex]
            if (it && wlRemoveMode) {
                youtubeBackend.removeFromWatchLater(it.videoId)
                if (mode === "watchlater") {
                    var idx = itemList.currentIndex
                    items = youtubeBackend.getWatchLater()
                    itemList.currentIndex = Math.min(idx, Math.max(0, items.length - 1))
                }
            } else if (it) {
                youtubeBackend.addToWatchLater(it.videoId, it.title || "", it.channelName || "")
            }
        }
        wlOverlayVisible = false
    }

    // Hide Shorts from feed/channel lists when the "Display Shorts" toggle is off.
    // Unset/true/"ON" => show shorts (default); explicit false => hide.
    function filterShorts(videos) {
        var raw = appCore.get_setting(moduleRoot.moduleId, "display_shorts")
        var showShorts = (raw === undefined || raw === null) ? true
                         : (raw === true || raw === "ON")
        if (showShorts)
            return videos
        return videos.filter(function(v) { return !v.isShort })
    }

    Component.onCompleted: {
        if (mode === "watchlater") {
            items = youtubeBackend.getWatchLater()
            restoreListIndex()
        } else if (mode === "history") {
            items = youtubeBackend.getHistory()
            restoreListIndex()
        } else {
            isLoading = true
            errorMessage = ""
            if (mode === "feed")
                youtubeBackend.load_subscriptions_feed()
            else if (mode === "playlist")
                youtubeBackend.load_playlist_videos(playlistId)
            else
                youtubeBackend.load_channel_videos(channelId)
        }
    }

    Connections {
        target: youtubeBackend

        function onSubscriptionsFeedLoaded(videos) {
            if (itemsRoot.mode !== "feed")
                return
            itemsRoot.isLoading = false
            itemsRoot.errorMessage = ""
            itemsRoot.items = itemsRoot.filterShorts(videos)
            itemsRoot.restoreListIndex()
        }

        function onChannelVideosLoaded(loadedChannelId, videos) {
            if (itemsRoot.mode !== "channel" || loadedChannelId !== itemsRoot.channelId)
                return
            itemsRoot.isLoading = false
            itemsRoot.errorMessage = ""
            itemsRoot.items = itemsRoot.filterShorts(videos)
            itemsRoot.restoreListIndex()
        }

        function onPlaylistVideosLoaded(loadedPlaylistId, videos) {
            if (itemsRoot.mode !== "playlist" || loadedPlaylistId !== itemsRoot.playlistId)
                return
            // Twice for one request: the cached list, then the refreshed one.
            var live = itemsRoot.items.length > 0 ? itemList.currentIndex : undefined
            itemsRoot.isLoading = false
            itemsRoot.errorMessage = ""
            itemsRoot.items = itemsRoot.filterShorts(videos)
            itemsRoot.restoreListIndex(live)
        }

        function onChannelArtLoaded(loadedChannelId, artUrl) {
            if (loadedChannelId === itemsRoot.channelId)
                itemsRoot.artRev++
        }

        function onVideoMetaLoaded() {
            itemsRoot.metaRev++
        }

        function onErrorOccurred(msg) {
            if (itemsRoot.mode !== "feed" && itemsRoot.mode !== "channel" && itemsRoot.mode !== "playlist")
                return
            itemsRoot.isLoading = false
            itemsRoot.errorMessage = msg
        }
    }

    // ---
    // UI
    // ---

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        // A header carrying the name says it already, so the bar says where the
        // screen sits instead of repeating it.
        subtitle: itemsRoot.mode === "playlist" && itemsRoot.showPoster ? "Playlists"
                : itemsRoot.mode === "channel"  && itemsRoot.showPoster ? "Channels"
                : itemsRoot.sourceLabel
    }

    // Loading / empty / error states
    Text {
        visible: isLoading
        text: "LOADING..."
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }
    Text {
        visible: !isLoading && errorMessage !== ""
        text: errorMessage
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        width: root.sw * 0.76875 //492 — long guidance lines wrap instead of clipping offscreen
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: root.sh * 0.05 //24
    }
    Text {
        visible: !isLoading && errorMessage === "" && items.length === 0
        text: "NO VIDEOS FOUND"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    // Header — the artwork in the left column with the name beside it, exactly
    // the shape a Plex season puts its poster and title in. Hidden as a whole
    // when there is no picture to draw: nothing else in it says anything the
    // AppBar does not already say.
    Row {
        id: posterHeader
        visible: itemsRoot.showPoster
        opacity: wlOverlayVisible ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: itemsRoot.contentTop
        anchors.leftMargin: itemsRoot.contentLeft
        spacing: root.sw * 0.0375 //24

        // Fixed-width column, so the name beside it and the list below start at
        // the same x whatever shape the avatar turns out to be.
        Item {
            width: itemsRoot.posterW
            height: posterImage.height

            Image {
                id: posterImage
                // Loads whenever the URL resolves, even with the Row hidden —
                // its status is what decides whether the Row is shown at all.
                source: itemsRoot.headerArtUrl
                asynchronous: true
                cache: true
                // Fitted, not cropped, and sized from what came back: an avatar
                // is square and a playlist's cover is 16:9, and nothing here
                // depends on which of them it is holding.
                fillMode: Image.PreserveAspectFit
                sourceSize.width: itemsRoot.posterW
                sourceSize.height: itemsRoot.posterW
                width: Math.min(implicitWidth, parent.width)
                height: implicitWidth > 0 ? width * implicitHeight / implicitWidth : 0
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        Column {
            id: headerText
            topPadding: root.sh * 0.0083333 //4
            width: itemsRoot.sectionW
            spacing: root.sh * 0.0166667 //8

            Text {
                text: itemsRoot.headerTitle
                color: root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                elide: Text.ElideRight
                width: parent.width
                font.pixelSize: root.sh * 0.05 //24
            }

            Text {
                text: itemsRoot.items.length
                      + (itemsRoot.items.length === 1 ? " VIDEO" : " VIDEOS")
                color: root.secondaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                elide: Text.ElideRight
                width: parent.width
                font.pixelSize: root.sh * 0.0333333 //16
            }
        }
    }

    // List. Beside the artwork and under the name when there is a header — the
    // same move the Plex detail views make — and the full width of the screen
    // in every other mode.
    ListView {
        id: itemList
        model: itemsRoot.items
        opacity: wlOverlayVisible ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: itemsRoot.showPoster
                           ? itemsRoot.contentTop + headerText.height + root.sh * 0.05625 //27
                           : root.sh * 0.25
        anchors.leftMargin: itemsRoot.contentLeft
                            + (itemsRoot.showPoster ? itemsRoot.sectionX : 0)
        width: itemsRoot.listW
        height: itemsRoot.showPoster ? root.sh * 0.375  //180 — 5 rows of 36
                                     : root.sh * 0.525  //252 — 7 rows of 36
        clip: true
        focus: true

        delegate: Item {
            width: itemList.width
            height: root.sh * 0.075 //36

            // Full-width background highlight for the active row
            Rectangle {
                color: root.accentColor
                anchors.fill: parent
                visible: itemList.currentIndex === index
            }

            // The video's own thumbnail, in a slot reserved on every row so the
            // titles line up whether or not one arrives. Fitted rather than
            // cropped, so a frame of any shape is shown whole.
            Image {
                id: rowThumb
                visible: itemsRoot.rowArt && status === Image.Ready
                source: itemsRoot.rowArtFor(modelData)
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                width: itemsRoot.rowArtW
                height: itemsRoot.rowArtH
                sourceSize.width: itemsRoot.rowArtW
                sourceSize.height: itemsRoot.rowArtH
                anchors.verticalCenter: parent.verticalCenter
            }

            // Along the foot of that thumbnail, as far as the picture itself
            // runs: the slot is a fixed box and the frame is fitted inside it,
            // so the bar is measured off what was painted rather than off the
            // slot, which would leave it hanging past the picture's edges.
            Item {
                readonly property real fraction: itemsRoot.rowProgressFor(modelData)
                visible: rowThumb.visible && fraction > 0
                width: rowThumb.paintedWidth
                height: itemsRoot.rowProgressH
                x: rowThumb.x + (rowThumb.width - rowThumb.paintedWidth) / 2
                y: rowThumb.y + (rowThumb.height + rowThumb.paintedHeight) / 2 - height

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

            // Vertical stack for Subtitle and Title
            Column {
                id: textColumn
                anchors.left: parent.left
                anchors.leftMargin: itemsRoot.rowTextX
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.sh * 0.0041667 //2

                // One line read from both ends: the channel at the left, the
                // age and then the runtime at the right. Right-aligned rather
                // than run on after the name, so the numbers stack in a column
                // down the list and a long name cannot shove them out of line.
                Item {
                    id: subtitleRow
                    width: itemsRoot.rowTextW
                    height: subtitleLabel.implicitHeight
                    visible: subtitleLabel.text !== "" || metaLabel.text !== ""

                    Text {
                        id: subtitleLabel
                        // Every row in a channel list is that channel, so the
                        // name drops out once the header above carries it.
                        text: itemsRoot.channelLine(modelData)
                        color: itemList.currentIndex === index ? root.surfaceColor : root.secondaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        font.pixelSize: root.sh * 0.0208333 //10
                        anchors.left: parent.left
                        // Yields to the numbers rather than colliding with them.
                        width: Math.max(0, parent.width
                                        - (metaLabel.text !== ""
                                           ? metaLabel.width + root.sw * 0.0125 //8
                                           : 0))
                        elide: Text.ElideRight
                    }

                    Text {
                        id: metaLabel
                        text: itemsRoot.metaLine(modelData)
                        color: itemList.currentIndex === index ? root.surfaceColor : root.secondaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        font.pixelSize: root.sh * 0.0208333 //10
                        anchors.right: parent.right
                    }
                }

                // Clipped title with marquee scroll when it overflows the row
                Item {
                    id: titleClip
                    width: Math.min(titleLabel.implicitWidth, itemsRoot.rowTextW)
                    height: titleLabel.implicitHeight
                    clip: true

                    Text {
                        id: titleLabel
                        text: modelData.title || ""
                        color: itemList.currentIndex === index ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        font.pixelSize: root.sh * 0.0333333 //16
                        x: 0
                    }

                    SequentialAnimation {
                        running: (itemList.currentIndex === index) &&
                                 (titleLabel.implicitWidth > titleClip.width)
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) titleLabel.x = 0
                        PauseAnimation { duration: 1500 }
                        NumberAnimation {
                            target: titleLabel; property: "x"
                            to: titleClip.width - titleLabel.implicitWidth
                            duration: Math.abs(to) * 20
                        }
                        PauseAnimation { duration: 2000 }
                        PropertyAction { target: titleLabel; property: "x"; value: 0 }
                    }
                }
            }
        }

        Keys.onReturnPressed: {
            if (wlOverlayVisible) {
                applyWatchLaterChoice()
                return
            }
            itemsRoot.openSelected()
        }
        Keys.onUpPressed: {
            if (wlOverlayVisible) {
                if(wlChoiceIndex === 0) wlChoiceIndex = 1
                else wlChoiceIndex = 0
                event.accepted = true
                return
            }
            if (count === 0) return
            if (currentIndex > 0) currentIndex--
            else currentIndex = count - 1
            itemList.positionViewAtIndex(itemList.currentIndex, ListView.Contain)
        }
        Keys.onDownPressed: {
            if (wlOverlayVisible) {
                if(wlChoiceIndex === 0) wlChoiceIndex = 1
                else wlChoiceIndex = 0
                event.accepted = true
                return
            }
            if (count === 0) return
            if (currentIndex < count - 1) currentIndex++
            else currentIndex = 0
            itemList.positionViewAtIndex(itemList.currentIndex, ListView.Contain)
        }
        Keys.onPressed: function(event) {
            if (wlOverlayVisible) {
                if (event.key === Qt.Key_Up) {
                    if(wlChoiceIndex === 0) wlChoiceIndex = 1
                    else wlChoiceIndex = 0
                    event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                    if(wlChoiceIndex === 0) wlChoiceIndex = 1
                    else wlChoiceIndex = 0
                    event.accepted = true
                } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                    wlOverlayVisible = false
                    event.accepted = true
                }
                return
            }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                itemsRoot.goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Space) {
                itemsRoot.playSelected()
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                openWatchLaterOverlay()
                event.accepted = true
            }
        }
    }

    // Watch-later save/remove overlay
    Rectangle {
        anchors.fill: parent
        color: root.surfaceColor
        visible: wlOverlayVisible

        Rectangle {
            color: root.surfaceColor
            anchors.centerIn: parent
            width: root.sw * 0.76875
            height: root.sh * 0.2833333

            Column {
                id: wlDialogColumn
                anchors.fill: parent
                spacing: root.sh * 0.05

                Text {
                    text: wlRemoveMode ? "REMOVE FROM WATCH LATER?" : "SAVE TO WATCH LATER?"
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    Repeater {
                        model: ["Yes", "No"]
                        delegate: Item {
                            width: wlDialogColumn.width
                            height: root.sh * 0.0583333

                            Rectangle {
                                anchors.fill: wlDelegateText
                                color: root.accentColor
                                visible: index === wlChoiceIndex
                            }

                            Text {
                                id: wlDelegateText
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: modelData
                                color: index === wlChoiceIndex ? root.surfaceColor : root.primaryColor
                                font.family: root.globalFont
                                font.capitalization: Font.AllUppercase
                                topPadding: root.sh * 0.0041667
                                leftPadding: root.sw * 0.009375
                                rightPadding: root.sw * 0.009375
                                bottomPadding: root.sh * 0.00625
                                font.pixelSize: root.sh * 0.0416667
                            }
                        }
                    }
                }

                Text {
                    text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
                    color: root.tertiaryColor
                    font.family: root.globalFont
                    font.pixelSize: root.sh * 0.0333333
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // Footer
    Text {
        id: footer
        visible: !wlOverlayVisible
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
              + root.hints.browse + (itemsRoot.mode === "watchlater" ? ":REMOVE " : ":SAVE ")
              + root.hints.play_pause + ":PLAY "
              // Not SELECT any more: Return opens the video's screen and Space
              // plays it, so the two have to be told apart here.
              + root.hints.select + ":INFO"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        // Five hints is the most any footer carries, and at 480p the longest
        // wording (Watch Later's REMOVE) runs a dozen pixels past the edge.
        // Rather than drop one, the line gives up a pixel of type — which also
        // keeps it whole when a gamepad names buttons at more length.
        width: root.sw - x
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: root.sh * 0.0270833 //13
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
