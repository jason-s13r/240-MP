import QtQuick
import Components

// The module's menu. With poster art on, its rows become shelves — channels as
// a row of avatars, the rest as rows of thumbnails — built the same way
// modules/plex/views/Libraries.qml is: one ListView of mixed entries behind a
// Loader delegate, focus never leaving it, Left/Right forwarded to the shelf.
FocusScope {
    id: itemsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    property bool isLoading: false
    property string errorMessage: ""

    // Which entries this install can offer at all — each file gates its own.
    property bool subsOk: false
    property bool playlistsOk: false
    property var watchLater: []
    property var history: []

    // The channel list, for the shelf. Only poster mode asks for it: in text
    // mode the menu has always been a synchronous read of the two files.
    property var channels: []
    // The front of the subscriptions feed. Served by the same pass over the
    // channel feeds, so the shelf costs no extra request.
    property var feed: []
    // Playlists, drawn as cells rather than a row to drill into. A fetch of its
    // own — a yt-dlp run per list — so the menu never waits on it (playlistShelf).
    property var playlists: []
    property bool menuResolved: false

    readonly property bool posterMenu: root.posterGrid
    // Held at LOADING until the channels answer, rather than drawn as a text row
    // that turns into a shelf a second later and shoves everything under it down.
    readonly property bool menuReady: (subsOk || playlistsOk) && (!posterMenu || menuResolved)

    // Avatars resolve behind the shelf; reading artRev is what re-runs the
    // cells' art bindings when one lands (see Channels.qml). metaRev does the
    // same for the runtimes on the Watch Later cells.
    property int artRev: 0
    property int metaRev: 0

    // ----------------------------------------------------------------
    // Entries
    // ----------------------------------------------------------------

    // A shelf swallows the nav row it replaces, so it carries a card through to
    // the full list — otherwise that list, with its A–Z panel and remove
    // gesture, is unreachable. Titled with the row's own name rather than VIEW
    // ALL: at this width the label is read down the card as a spine, and a spine
    // at the front of a row names the row. What it does is said in selectedTitle.
    function withViewAll(title, list) {
        return [{ nav: "all", title: title }].concat(list)
    }

    // Shelf of recent videos, or the nav row it has always been: a feed that
    // never came back leaves the row rather than nothing.
    readonly property bool feedShelf: posterMenu && feed.length > 0

    // Playlists take the shelf before there is anything to put on it: their
    // contents land seconds after the screen is up, and a row that becomes a
    // shelf then shoves everything under it down while the user is reading. So
    // the shelf is there from the start, filling in beside its card; a fetch
    // that never comes back leaves a row with only the card, which still opens.
    readonly property bool playlistShelf: posterMenu && playlistsOk

    // One entry per section in one order, kept whether the section draws as a
    // shelf or falls back to its nav row — rearranging the menu around a failed
    // fetch is worse than the failure. Sections with nothing in them at all drop
    // out: an empty Watch Later is not a thing to offer.
    function rowEntry(key, title) {
        return { kind: "row", key: key, title: title }
    }
    function shelfEntry(key, title, list) {
        return { kind: "shelf", shelfKind: key, key: key, title: title,
                 items: withViewAll(title, list) }
    }
    readonly property var navEntries: {
        var out = []
        if (subsOk)
            out.push(feedShelf ? shelfEntry("feed", "Subscriptions", feed)
                               : rowEntry("feed", "Subscriptions"))
        if (watchLater.length > 0)
            out.push(posterMenu ? shelfEntry("watchlater", "Watch Later", watchLater)
                                : rowEntry("watchlater", "Watch Later"))
        if (playlistsOk)
            out.push(playlistShelf ? shelfEntry("playlists", "Playlists", playlists)
                                   : rowEntry("playlists", "Playlists"))
        // Channels comes from the subscriptions file, exactly as the feed does.
        if (subsOk)
            out.push((posterMenu && channels.length > 0)
                        ? shelfEntry("channels", "Channels", channels)
                        : rowEntry("channels", "Channels"))
        if (history.length > 0)
            out.push(posterMenu ? shelfEntry("history", "History", history)
                                : rowEntry("history", "History"))
        return out
    }

    // ----------------------------------------------------------------
    // Shelf cell resolvers
    // ----------------------------------------------------------------

    // A VIEW ALL card rather than a channel or a video.
    function tileOf(item) { return item && item.nav !== undefined }

    function channelArtFor(item, w, h) {
        var rev = artRev // dependency: re-runs when an avatar lands
        if (!item || tileOf(item) || rev < 0 || !youtubeBackend)
            return ""
        return youtubeBackend.channel_art_url(item.channelId, Math.round(Math.max(w, h)))
    }

    function videoThumbFor(item, w, h) {
        if (!item || tileOf(item) || !youtubeBackend)
            return ""
        return youtubeBackend.video_thumb_url(item.videoId || "")
    }

    // A saved video stores its channel's name but not its ID (getWatchLater), so
    // the badge matches against the subscription list already loaded above.
    readonly property var channelIdByName: {
        var map = ({})
        for (var i = 0; i < channels.length; i++)
            map[channels[i].title] = channels[i].channelId
        return map
    }

    // A 16:9 thumbnail says nothing about which channel it came from; the
    // avatar in its corner does.
    function videoBadgeFor(item, w, h) {
        var rev = artRev // dependency: re-runs when an avatar lands
        if (!item || tileOf(item) || rev < 0 || !youtubeBackend)
            return ""
        var id = item.channelId || channelIdByName[item.channelName || ""] || ""
        return id ? youtubeBackend.channel_art_url(id, Math.round(Math.max(w, h))) : ""
    }

    // How much of a video has been watched, for the rule along the foot of its
    // thumbnail. A playlist or a channel is not a thing that is part-watched,
    // and the card at the front of the row is not a video at all.
    function videoProgressFor(item) {
        var rev = metaRev // dependency: re-runs when a duration probe lands
        if (!item || tileOf(item) || rev < 0 || !youtubeBackend)
            return 0
        return youtubeBackend.video_progress(item.videoId || "")
    }

    // Over the art: the video's name on top, its age and runtime sharing the
    // line beneath — age from the left, runtime from the corner.
    function videoCaptionFor(item) {
        var rev = metaRev // dependency: re-runs when a duration probe lands
        if (!item || tileOf(item) || rev < 0 || !youtubeBackend)
            return null
        var id = item.videoId || ""
        return {
            top:    item.title || "",
            bottom: youtubeBackend.video_age_text(id),
            corner: youtubeBackend.video_duration_text(id)
        }
    }

    // A playlist is drawn as one of its videos would be: the 16:9 cover YouTube
    // picked, so a row of lists steps with the rows of videos above and below.
    function playlistThumbFor(item, w, h) {
        if (!item || tileOf(item) || !youtubeBackend)
            return ""
        // Unsized: the thumbnail host serves fixed sizes rather than taking a
        // crop instruction, so the cell fills from whatever comes back.
        return youtubeBackend.playlist_thumb_url(item.playlistId || "")
    }

    // A list says of itself what a video does: how long since it changed (by
    // when it was last added to, which is the date YouTube shows) and how much
    // of it there is, in the corner a runtime is read from. A Mix or a channel's
    // uploads has no such date, and there the channel's name takes the line.
    // No revision to read: everything here came in with the playlist itself.
    function playlistCaptionFor(item) {
        if (!item || tileOf(item) || !youtubeBackend)
            return null
        var n = item.videoCount || 0
        var age = youtubeBackend.age_text(item.modifiedMs || 0)
        return {
            top:    item.title || "",
            bottom: age !== "" ? age : (item.channelName || ""),
            corner: n > 0 ? (n + (n === 1 ? " VIDEO" : " VIDEOS")) : ""
        }
    }

    // Whose playlist it is, when it is anyone's. yt-dlp reports no owner, so it
    // comes from the videos: one channel throughout is that channel's, a mix is
    // nobody's and says nothing. The front of the list is enough to tell.
    readonly property int playlistChannelSample: 8
    function playlistChannel(playlistId) {
        var videos = youtubeBackend.playlist_videos(playlistId, playlistChannelSample)
        if (videos.length === 0)
            return ""
        var name = videos[0].channelName || ""
        for (var i = 1; i < videos.length; i++) {
            if ((videos[i].channelName || "") !== name)
                return ""
        }
        return name
    }

    // Worked out once as the list lands rather than on every binding pass.
    function describePlaylists(loaded) {
        var out = []
        for (var i = 0; i < loaded.length; i++) {
            var p = loaded[i]
            out.push({
                playlistId:  p.playlistId,
                title:       p.title || "",
                videoCount:  p.videoCount || 0,
                modifiedMs:  p.modifiedMs || 0,
                // Worked out even for a list that will state its date instead:
                // the channel is also what the corner avatar is matched on, so
                // it is carried whether or not the caption ends up saying it.
                channelName: playlistChannel(p.playlistId)
            })
        }
        return out
    }

    // The card is the same width on every shelf: it leads its row, so its width
    // is where each row's first real cell starts, and three widths would put
    // three shelves' cells at three different x. A spine, not a poster — a card
    // is a way through, so it takes the least it can and PosterCell turns the
    // label a quarter turn to fit it.
    readonly property real tilePosterW: root.sh * 0.0375 //18

    // A cell keeps its aspect and its shelf's height sets its size, so a width is
    // asked for as the aspect that comes out that wide at that height.
    function tileAspect(shelfPosterH, shelfAspect) {
        return function(item) {
            return (tileOf(item) && shelfPosterH > 0) ? tilePosterW / shelfPosterH
                                                      : shelfAspect
        }
    }

    function shelfItemTitle(item) {
        return item ? (item.title || "") : ""
    }

    // The same items named at the foot of the screen. A card's name is where it
    // goes, not what it is, so the line says VIEW ALL SUBSCRIPTIONS.
    function selectedTitle(item) {
        if (!item) return ""
        return tileOf(item) ? "VIEW ALL " + (item.title || "")
                            : (item.title || "")
    }

    // ----------------------------------------------------------------
    // What a shelf holds
    // ----------------------------------------------------------------

    // Same setting the list behind the card reads (Subscriptions.qml), so the
    // shelf is the front of that list rather than a differently-filtered one.
    // Unset/true/"ON" => show shorts (default); explicit false => hide.
    function filterShorts(videos) {
        var raw = appCore.get_setting(moduleRoot.moduleId, "display_shorts")
        var showShorts = (raw === undefined || raw === null) ? true
                         : (raw === true || raw === "ON")
        if (showShorts)
            return videos
        return videos.filter(function(v) { return !v.isShort })
    }

    // A shelf is a glance at a list — the whole of it is one Return away on the
    // card. Twenty cells, with a fortnight as the floor, so a busy two weeks is
    // not cut off half way and a quiet one still fills the row.
    readonly property int shelfCount: 20
    readonly property int shelfDays: 14

    // Both lists arrive newest-first, so the caller only says which date to read.
    function recentSlice(items, stampKey) {
        var cutoff = Date.now() - shelfDays * 24 * 60 * 60 * 1000
        var recent = 0
        // An item with no date reads as 0 and sorts to the back, which ends the
        // window rather than extending it — the right answer either way.
        while (recent < items.length && (items[recent][stampKey] || 0) >= cutoff)
            recent++
        return items.slice(0, Math.max(shelfCount, recent))
    }

    // ----------------------------------------------------------------
    // Selection
    // ----------------------------------------------------------------

    // Where the selection sits along the current shelf. A vertical step resets it
    // — these shelves hold unrelated things, so a carried column lands nowhere.
    property int shelfColumn: 0

    // Shelf mode borrows the poster grid's taller content box: the AppBar ends
    // at y84 and the hint row starts at y414. Without a shelf, today's layout.
    readonly property real contentTop: posterMenu ? root.sh * 0.2166667 //104
                                                  : root.sh * 0.25      //120
    readonly property real contentH: posterMenu ? root.sh * 0.5833333 //280
                                                : root.sh * 0.525     //252
    readonly property real titleH: root.sh * 0.0375 //18
    readonly property real rowH: root.sh * 0.0583333 //28

    // Posters plus the cells' ring, and nothing else: Libraries.qml adds 22 for
    // a heading, but here the spine at the front of the row already names it,
    // and that height buys another shelf on the screen instead.
    readonly property real shelfOverheadH: shelfGutter //6
    // An avatar stays recognisable small, so the channel shelf runs at 64 and
    // fits seven across where 96 fit five.
    readonly property real channelPosterH: root.sh * 0.1333333 //64
    // A video cell is one avatar pair wide, so the video row steps in step with
    // the channel row: every second avatar sits under a thumbnail edge.
    readonly property real shelfGutter: root.sh * 0.0125 //6 — PosterShelf's frameW * 2
    readonly property real videoPosterH: (channelPosterH * 2 + shelfGutter) * 9 / 16 //75
    readonly property real channelShelfH: channelPosterH + shelfOverheadH //70
    readonly property real videoShelfH: videoPosterH + shelfOverheadH //81

    function entryAt(i) {
        return (i >= 0 && i < navEntries.length) ? navEntries[i] : null
    }

    // The PosterShelf for the selected entry, or null when it is a nav row.
    // navList.currentItem is the Loader; its item is the shelf.
    function currentShelf() {
        var e = entryAt(navList.currentIndex)
        if (!e || e.kind !== "shelf") return null
        return navList.currentItem ? navList.currentItem.item : null
    }

    // What the title line names. A shelf's own currentIndex is not something a
    // binding can watch from out here, so every move says so.
    property var selectedItem: null
    function refreshSelected() {
        var sh = currentShelf()
        selectedItem = sh ? sh.currentItemData : null
    }

    function moveTo(i) {
        navList.currentIndex = i
        navList.positionViewAtIndex(i, ListView.Contain)
        // Seats an already-built shelf on the carried column; one created by
        // this move seats itself in Component.onCompleted.
        var sh = currentShelf()
        if (sh) sh.moveTo(Math.min(shelfColumn, Math.max(0, sh.count - 1)))
        refreshSelected()
    }

    function stepTo(i) {
        shelfColumn = 0
        moveTo(i)
    }

    function listState() {
        return { currentIndex: navList.currentIndex, shelfColumn: itemsRoot.shelfColumn }
    }

    function restoreSelection() {
        if (navEntries.length === 0) return
        shelfColumn = navListState.shelfColumn || 0
        var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
        moveTo(Math.min(restore, navEntries.length - 1))
    }

    // ----------------------------------------------------------------
    // Opening things
    // ----------------------------------------------------------------

    function openRow(key) {
        var state = itemsRoot.listState()
        if (key === "feed")            navigateTo("Subscriptions.qml", { mode: "feed" }, state)
        else if (key === "channels")   navigateTo("Channels.qml", {}, state)
        else if (key === "playlists")  navigateTo("Playlists.qml", {}, state)
        else if (key === "watchlater") navigateTo("Subscriptions.qml", { mode: "watchlater" }, state)
        else if (key === "history")    navigateTo("Subscriptions.qml", { mode: "history" }, state)
    }

    // A shelf holds its VIEW ALL card and its items, so Return lands here first.
    function openShelfItem(entry, item) {
        if (!entry || !item) return
        if (tileOf(item)) { openRow(entry.key); return }
        if (entry.shelfKind === "channels") {
            navigateTo("Subscriptions.qml", {
                mode: "channel",
                channelId: item.channelId,
                channelName: item.title
            }, itemsRoot.listState())
        } else if (entry.shelfKind === "playlists") {
            // The same screen the playlists list opens a playlist on, reached
            // one Return earlier.
            navigateTo("Subscriptions.qml", {
                mode: "playlist",
                playlistId: item.playlistId,
                playlistName: item.title
            }, itemsRoot.listState())
        } else {
            // Videos go by way of their own screen, not straight to mpv — see
            // Video.qml.
            navigateTo("Video.qml", { item: item, sourceLabel: entry.title },
                       itemsRoot.listState())
        }
    }

    // Space plays a shelf's video where Return opens its screen first. Only a
    // video answers; the footer offers the hint only when one is selected.
    function playableItem(entry, item) {
        if (!entry || entry.kind !== "shelf" || !item || tileOf(item))
            return null
        if (entry.shelfKind === "channels" || entry.shelfKind === "playlists")
            return null
        return item
    }

    readonly property bool canPlaySelected:
        playableItem(entryAt(navList.currentIndex), selectedItem) !== null

    function playShelfItem(entry, item) {
        var video = playableItem(entry, item)
        if (video)
            navigateTo("Player.qml", { item: video }, itemsRoot.listState())
    }

    // ----------------------------------------------------------------
    // Loading
    // ----------------------------------------------------------------

    // Everything but the channel shelf is a local read, so the menu builds
    // synchronously; the shelf needs the feed the rest of the module reads
    // anyway, and loading it here warms that cache for the views behind.
    // Either youtube_subscriptions.txt or youtube_playlists.txt is enough; each
    // file only gates its own entries.
    Component.onCompleted: {
        var subsStatus = youtubeBackend.check_subscriptions()
        var plStatus = youtubeBackend.check_playlists()
        if (!subsStatus.ok && !plStatus.ok) {
            // A file that exists but failed its check has the more actionable
            // error; with no files at all, point at both options.
            if (subsStatus.fileExists)
                errorMessage = subsStatus.error
            else if (plStatus.fileExists)
                errorMessage = plStatus.error
            else
                errorMessage = "REQUIRED FILES NOT FOUND\n\n"
                             + "ADD YOUTUBE_SUBSCRIPTIONS.TXT OR YOUTUBE_PLAYLISTS.TXT\n\n"
                             + "PLEASE SEE THE WIKI FOR DETAILS"
            return
        }
        subsOk = subsStatus.ok
        playlistsOk = plStatus.ok
        watchLater = youtubeBackend.getWatchLater()
        history = recentSlice(youtubeBackend.getHistory(), "lastPlayed")

        loadPlaylistShelf()
        loadChannelsOrResolve()
    }

    // Outside what the menu waits for: the load Playlists.qml does, run a screen
    // earlier so the shelf fills in and that screen opens from cache.
    function loadPlaylistShelf() {
        if (posterMenu && playlistsOk && playlists.length === 0)
            youtubeBackend.load_playlists()
    }

    // Turning the setting on while this screen is up asks for a shelf with no
    // channel list behind it, so the load is driven from the setting.
    onPosterMenuChanged: {
        if (posterMenu && subsOk && channels.length === 0)
            loadChannelsOrResolve()
        loadPlaylistShelf()
    }

    function loadChannelsOrResolve() {
        if (!posterMenu || !subsOk) {
            resolveMenu()
            return
        }
        isLoading = true
        channelsTimeout.start()
        // One pass answers both: the emit flags queue on the refresh that is
        // already in flight, and the feed lands just before the channels do.
        youtubeBackend.load_subscriptions_feed()
        youtubeBackend.load_channels()
    }

    // Builds the menu with whatever has arrived. A channel list that never came
    // back leaves CHANNELS as the nav row it has always been, rather than
    // stranding the whole menu on LOADING.
    function resolveMenu() {
        if (menuResolved) { isLoading = false; return }
        channelsTimeout.stop()
        isLoading = false
        menuResolved = true
        restoreSelection()
    }

    Timer {
        id: channelsTimeout
        interval: 5000
        onTriggered: itemsRoot.resolveMenu()
    }

    Connections {
        target: youtubeBackend

        function onSubscriptionsFeedLoaded(videos) {
            itemsRoot.feed = itemsRoot.recentSlice(itemsRoot.filterShorts(videos), "publishedMs")
        }

        function onPlaylistsLoaded(loaded) {
            // The one list that lands on a screen already being read, and a new
            // entries array resets the nav list to the top. The shelf was
            // already standing, so the selection is put back where it was.
            var at  = navList.currentIndex
            var col = itemsRoot.shelfColumn
            itemsRoot.playlists = itemsRoot.describePlaylists(loaded)
            if (itemsRoot.menuResolved) {
                itemsRoot.shelfColumn = col
                itemsRoot.moveTo(at)
            }
        }

        function onChannelsLoaded(loaded) {
            itemsRoot.channels = loaded
            itemsRoot.resolveMenu()
        }

        function onChannelArtLoaded(channelId, artUrl) {
            itemsRoot.artRev++
        }

        function onVideoMetaLoaded() {
            itemsRoot.metaRev++
        }

        // The menu itself still stands without a channel list — the feed's own
        // views report the failure when they are opened.
        function onErrorOccurred(msg) {
            itemsRoot.resolveMenu()
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
    }

    // Loading / Error states
    Text {
        visible: isLoading || (!menuReady && errorMessage === "")
        text: "LOADING..."
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }
    Text {
        visible: errorMessage !== ""
        text: errorMessage
        color: root.secondaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        width: root.sw * 0.76875 //492 — long guidance lines wrap instead of clipping offscreen
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: root.sh * 0.05 //24
    }

    // A nav row. Identical to the menu row this screen has always had.
    Component {
        id: rowComponent

        Item {
            readonly property bool current: navList.currentIndex === entryIndex

            Rectangle {
                color: root.accentColor
                anchors.fill: label
                visible: current
            }

            Text {
                id: label
                text: entry.title || ""
                color: current ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.05
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: root.sw * 0.009375
                rightPadding: root.sw * 0.009375
                topPadding: root.sh * 0.0041667
                bottomPadding: root.sh * 0.00625
            }
        }
    }

    // A shelf. Focus stays on navList — the shelf is stepped from there — so it
    // is told when it holds the selection rather than working it out from focus.
    Component {
        id: shelfComponent

        // No size here: the Loader already has one and resizes what it loads,
        // which would only fight a binding set from in here.
        PosterShelf {
            id: shelf

            readonly property real shelfAspect:
                entry.shelfKind === "channels" ? 1      // an avatar is a square
                                               : 16 / 9 // a video thumbnail is not

            // No sectionTitle: the card's spine already names the row, and
            // PosterShelf gives back the height a heading would take.
            model: entry.items || []
            highlighted: navList.currentIndex === entryIndex
            // One line at the bottom carries the selection for the whole screen.
            showTitleLine: false

            posterAspect: shelfAspect
            posterAspectFor: itemsRoot.tileAspect(shelf.posterH, shelfAspect)
            posterSource: entry.shelfKind === "channels"  ? itemsRoot.channelArtFor
                        : entry.shelfKind === "playlists" ? itemsRoot.playlistThumbFor
                                                          : itemsRoot.videoThumbFor
            titleText: itemsRoot.shelfItemTitle
            // Both are landscape-cell only inside the shelf, so the square
            // avatars on the channel row never reach them.
            badgeSource: itemsRoot.videoBadgeFor
            captionSource: entry.shelfKind === "playlists" ? itemsRoot.playlistCaptionFor
                                                           : itemsRoot.videoCaptionFor
            // A playlist cell stands for a list rather than a video, so its
            // shelf is the one row of thumbnails with nothing to mark.
            progressSource: entry.shelfKind === "playlists" ? null
                                                            : itemsRoot.videoProgressFor
            badgeAspect: 1 // a channel avatar is a square

            onMoved: {
                itemsRoot.shelfColumn = currentIndex
                itemsRoot.refreshSelected()
            }
            Component.onCompleted: {
                currentIndex = Math.min(itemsRoot.shelfColumn, Math.max(0, count - 1))
                if (navList.currentIndex === entryIndex) itemsRoot.refreshSelected()
            }
        }
    }

    // Body
    ListView {
        id: navList
        model: navEntries
        visible: menuReady && errorMessage === ""
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: itemsRoot.contentTop
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: itemsRoot.contentH
        clip: true
        focus: true
        // A shelf costs a row of image requests, so only the entries on screen
        // (plus the one being scrolled to) are ever built.
        cacheBuffer: itemsRoot.videoShelfH

        Keys.onUpPressed: {
            if (count === 0) return
            itemsRoot.stepTo(currentIndex > 0 ? currentIndex - 1 : count - 1)
        }
        Keys.onDownPressed: {
            if (count === 0) return
            itemsRoot.stepTo(currentIndex < count - 1 ? currentIndex + 1 : 0)
        }
        // Left and Right belong to the shelf when the selection is on one, and
        // mean nothing on a nav row.
        Keys.onLeftPressed: {
            var sh = itemsRoot.currentShelf()
            if (sh) sh.moveLeft()
        }
        Keys.onRightPressed: {
            var sh = itemsRoot.currentShelf()
            if (sh) sh.moveRight()
        }
        Keys.onReturnPressed: {
            var e = itemsRoot.entryAt(currentIndex)
            if (!e) return
            if (e.kind === "shelf") {
                var sh = itemsRoot.currentShelf()
                itemsRoot.openShelfItem(e, sh ? sh.currentItemData : null)
                return
            }
            itemsRoot.openRow(e.key)
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                itemsRoot.goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Space) {
                // The shelf never holds focus here — it is stepped from this
                // list — so the key arrives at the list, as the arrows do.
                itemsRoot.playShelfItem(itemsRoot.entryAt(currentIndex),
                                        itemsRoot.selectedItem)
                event.accepted = true
            }
        }

        delegate: Loader {
            required property int index
            required property var modelData

            readonly property var entry: modelData
            readonly property int entryIndex: index

            width: navList.width
            height: entry.kind !== "shelf" ? itemsRoot.rowH
                  : entry.shelfKind === "channels" ? itemsRoot.channelShelfH
                                                   : itemsRoot.videoShelfH
            sourceComponent: entry.kind === "shelf" ? shelfComponent : rowComponent
        }
    }

    // Selected item's name: one line for the whole view rather than one per
    // shelf, which would repeat the heading it sits under and name an item rows
    // away from wherever the selection actually is.
    MarqueeText {
        visible: itemsRoot.posterMenu && itemsRoot.menuReady
        anchors.left: parent.left
        anchors.bottom: footer.top
        anchors.leftMargin: root.sw * 0.115625 //74
        anchors.bottomMargin: root.sh * 0.0166667 //8
        height: itemsRoot.titleH
        maxWidth: root.sw * 0.76875 //492
        text: itemsRoot.selectedTitle(itemsRoot.selectedItem)
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: root.sh * 0.0375 //18
    }

    // Footer
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
              + (itemsRoot.canPlaySelected ? root.hints.play_pause + ":PLAY " : "")
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
