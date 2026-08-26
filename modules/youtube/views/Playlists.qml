import QtQuick
import Components

// Playlist list from youtube_playlists.txt, in file order (the user's own
// curation is the sort — no letter-nav panel, unlike Channels).
//
// With poster art on, each playlist is drawn as a shelf of its own videos
// instead of a title to drill into, built from ShelfList. It costs no extra
// network — load_playlists() fetches every playlist's contents anyway. Each
// shelf leads with a VIEW ALL card opening the full list, where the whole of it
// and the watch-later gesture still live.
FocusScope {
    id: playlistsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var items: []
    property bool isLoading: false
    property string errorMessage: ""

    readonly property bool useShelves: root.posterGrid && items.length > 0

    // How much of a playlist a shelf carries. A playlist holds up to 500 entries
    // (kMaxPlaylistItems) and the card at its head opens the rest, so handing
    // every video of every playlist to QML would pay for a wall nobody scrolls.
    readonly property int shelfPreview: 24

    // Avatars and durations resolve behind the shelves; reading these revisions
    // is what re-runs the cells' bindings when one lands (see Items.qml).
    property int artRev: 0
    property int metaRev: 0

    // A shelf per playlist, each led by its VIEW ALL card. A playlist whose
    // fetch failed still gets a shelf — the card alone — rather than dropping
    // off a screen that lists it in text mode.
    readonly property var shelfModel: {
        if (!root.posterGrid || !youtubeBackend)
            return []
        var out = []
        for (var i = 0; i < items.length; i++) {
            var p = items[i]
            var videos = youtubeBackend.playlist_videos(p.playlistId, shelfPreview)
            out.push({
                title: p.title || "",
                playlistId: p.playlistId,
                items: [{ nav: "all", title: "VIEW ALL" }].concat(videos)
            })
        }
        return out
    }

    Component.onCompleted: {
        isLoading = true
        errorMessage = ""
        youtubeBackend.load_playlists()
    }

    Connections {
        target: youtubeBackend

        function onPlaylistsLoaded(playlists) {
            // The list lands twice — cache first, then the refresh — and the
            // second arrives on a screen already being read, where a new array
            // resets the views to the top. So the live position is put back.
            var live = playlistsRoot.items.length > 0 ? playlistsRoot.livePosition() : null
            playlistsRoot.isLoading = false
            playlistsRoot.items = playlists
            playlistsRoot.restoreSelection(live)
        }

        function onChannelArtLoaded(channelId, artUrl) {
            playlistsRoot.artRev++
        }

        function onVideoMetaLoaded() {
            playlistsRoot.metaRev++
        }

        function onErrorOccurred(msg) {
            playlistsRoot.isLoading = false
            playlistsRoot.errorMessage = msg
        }
    }

    // Where the selection is now, in the shape restoreSelection reads it back.
    function livePosition() {
        if (useShelves)
            return { shelfIndex: shelfView.shelfIndex, itemIndex: shelfView.itemIndex }
        return { currentIndex: itemList.currentIndex }
    }

    // Seats the selection on a state — the saved one the screen was opened on,
    // or a live one captured a moment ago (see onPlaylistsLoaded).
    function restoreSelection(state) {
        if (items.length === 0)
            return
        var at = state || navListState
        if (useShelves) {
            shelfView.setPosition(at.shelfIndex || 0, at.itemIndex || 0)
            shelfView.forceActiveFocus()
            return
        }
        var restore = (at.currentIndex !== undefined) ? at.currentIndex : 0
        itemList.currentIndex = Math.min(restore, items.length - 1)
        itemList.positionViewAtIndex(itemList.currentIndex, ListView.Contain)
        itemList.forceActiveFocus()
    }

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        } else if (event.key === Qt.Key_Space) {
            // Caught here rather than on the shelf: the shelf is a shared
            // component with no notion of playing anything, and in text mode
            // the selection is a playlist, which canPlaySelected rules out.
            playShelfItem()
            event.accepted = true
        }
    }

    // ----------------------------------------------------------------
    // Shelf cell resolvers
    // ----------------------------------------------------------------

    // A VIEW ALL card rather than a video.
    function tileOf(item) { return item && item.nav !== undefined }

    function videoThumbFor(item, w, h) {
        if (!item || tileOf(item) || !youtubeBackend)
            return ""
        return youtubeBackend.video_thumb_url(item.videoId || "")
    }

    // A 16:9 frame says nothing about which channel it came from, so the
    // channel's avatar rides in the corner of it. Playlist entries carry only
    // the channel's name — channel_art_for matches that against the subscribed
    // channels, and a video from a channel that is not subscribed gets none.
    function videoBadgeFor(item, w, h) {
        var rev = artRev // dependency: re-runs when an avatar lands
        if (!item || tileOf(item) || rev < 0 || !youtubeBackend)
            return ""
        return youtubeBackend.channel_art_for("", item.channelName || "",
                                              Math.round(Math.max(w, h)))
    }

    // What the cell says over its art: the video's own name on top, the channel
    // it came from underneath, the runtime in the corner. A playlist mixes
    // channels, so the name is the context worth the line — and flat playlist
    // entries carry no publish date, so there is no age to state instead.
    function videoCaptionFor(item) {
        var rev = metaRev // dependency: re-runs when a duration probe lands
        if (!item || tileOf(item) || rev < 0 || !youtubeBackend)
            return null
        return {
            top:    item.title || "",
            bottom: item.channelName || "",
            corner: youtubeBackend.video_duration_text(item.videoId || "")
        }
    }

    // A card is never wider than the cells it stands in front of, so it takes
    // the 2:3 of cover art rather than the 16:9 of the thumbnails beside it —
    // the rule modules/plex/views/Libraries.qml states for its tiles.
    function cellAspect(item) { return tileOf(item) ? 2 / 3 : 16 / 9 }

    function cellTitle(item) { return item ? (item.title || "") : "" }

    function shelfListState() {
        return { shelfIndex: shelfView.shelfIndex, itemIndex: shelfView.itemIndex }
    }

    function openShelfItem(item) {
        var entry = shelfModel[shelfView.shelfIndex]
        if (!entry || !item)
            return
        if (tileOf(item)) {
            playlistsRoot.navigateTo("Subscriptions.qml", {
                mode: "playlist",
                playlistId: entry.playlistId,
                playlistName: entry.title
            }, shelfListState())
            return
        }
        // The video's own screen first, and the playlist rides along, exactly
        // as it does when the video is opened out of the list view (see
        // Subscriptions.qml).
        playlistsRoot.navigateTo("Video.qml", {
            item: item,
            sourceLabel: entry.title,
            playlistName: entry.title
        }, shelfListState())
    }

    // Space plays the selected cell outright, where Return opens its screen —
    // the same pair the video lists offer. A VIEW ALL card is a thing to open
    // rather than a thing to play, so it is not offered the gesture, and the
    // footer only names it where there is something to press it on.
    readonly property bool canPlaySelected:
        useShelves && !!shelfView.currentItemData
                   && !tileOf(shelfView.currentItemData)

    function playShelfItem() {
        if (!canPlaySelected)
            return
        var entry = shelfModel[shelfView.shelfIndex]
        if (!entry)
            return
        playlistsRoot.navigateTo("Player.qml", {
            item: shelfView.currentItemData,
            playlistName: entry.title
        }, shelfListState())
    }

    // ---
    // UI
    // ---

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: "Playlists"
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
        text: "NO PLAYLISTS FOUND"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    // Playlists as shelves — the poster surface. Same slot the Plex sectioned
    // view uses, and the shared title line at its foot names the selected cell.
    ShelfList {
        id: shelfView
        visible: useShelves
        focus: useShelves
        model: useShelves ? shelfModel : []
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.2166667 //104
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.6104167 //293

        posterSource: playlistsRoot.videoThumbFor
        posterAspectFor: playlistsRoot.cellAspect
        badgeSource: playlistsRoot.videoBadgeFor
        badgeAspect: 1 // a channel avatar is a square
        captionSource: playlistsRoot.videoCaptionFor
        titleText: playlistsRoot.cellTitle

        onActivated: function(item) { playlistsRoot.openShelfItem(item) }
        onBackRequested: playlistsRoot.goBack()
    }

    // Playlist list — the text surface, with no poster art on.
    ListView {
        id: itemList
        model: items
        visible: !useShelves
        focus: !useShelves
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: root.sh * 0.525 //252
        clip: true

        Keys.onUpPressed: {
            if (count === 0) return
            if (currentIndex > 0) currentIndex--
            else currentIndex = count - 1
        }
        Keys.onDownPressed: {
            if (count === 0) return
            if (currentIndex < count - 1) currentIndex++
            else currentIndex = 0
        }
        Keys.onReturnPressed: {
            var item = items[itemList.currentIndex]
            if (!item)
                return
            playlistsRoot.navigateTo("Subscriptions.qml", {
                mode: "playlist",
                playlistId: item.playlistId,
                playlistName: item.title
            }, { currentIndex: itemList.currentIndex })
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                playlistsRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Item {
            width: itemList.width
            height: root.sh * 0.0583333 //28

            Item {
                id: textClip
                width: Math.min(rowText.implicitWidth, itemList.width)
                height: parent.height
                clip: true

                Rectangle {
                    color: root.accentColor
                    anchors.fill: rowText
                    visible: itemList.currentIndex === index
                }

                Text {
                    id: rowText
                    text: modelData.title || ""
                    color: itemList.currentIndex === index ? root.surfaceColor : root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    topPadding: root.sh * 0.0041667 //2
                    leftPadding: root.sw * 0.009375 //6
                    rightPadding: root.sw * 0.009375 //6
                    bottomPadding: root.sh * 0.00625 //3
                    font.pixelSize: root.sh * 0.05 //24
                }

                SequentialAnimation {
                    running: (itemList.currentIndex === index) &&
                             (rowText.implicitWidth > textClip.width)
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) rowText.x = 0
                    PauseAnimation { duration: 1500 }
                    NumberAnimation {
                        target: rowText; property: "x"
                        to: textClip.width - rowText.implicitWidth
                        duration: Math.abs(to) * 20
                    }
                    PauseAnimation { duration: 2000 }
                    PropertyAction { target: rowText; property: "x"; value: 0 }
                }
            }
        }
    }

    // Footer
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
              + (playlistsRoot.canPlaySelected ? root.hints.play_pause + ":PLAY " : "")
              + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
