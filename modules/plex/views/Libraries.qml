import QtQuick
import Components

// Main Plex home screen: the library menu. With cover art on, each library is a
// shelf carrying its own menu as a row of tiles — the whole of Library.qml's
// intermediate menu, so that view is simply never reached in this mode — and
// LIVE TV is a shelf of the DVR lineup, one square station logo per channel.
FocusScope {
    id: browseRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    // Used for the PIN handoff below: replacing rather than pushing keeps this
    // view from ending up on the stack twice when ProfilePin returns here.
    signal replaceWith(string path, var params)
    signal goBack()

    property var libraries: []
    // Only for the PIN prompt below, which names the profile it is asking for.
    property string userName: ""
    property string errorMsg: ""

    // What each library actually has, so no tile opens on NO ITEMS FOUND. Three
    // requests per library (check_section_capabilities), one Continue Watching
    // fetch for all of them, and the channel lineup where there is a DVR. The
    // menu waits on the lot: tiles that appear and vanish under the selection
    // are worse than a moment of LOADING.
    property var caps: ({})       // sectionId -> { recommended, collections, playlists }
    property var cwItems: ({})    // sectionId -> the items in progress in it
    // The DVR's channel lineup, when the server has one. Held here because LIVE
    // TV is a shelf of its channels in poster mode, the way a library is a shelf
    // of its own menu — see navEntries.
    property var liveChannels: []
    property int capsPending: 0
    property bool cwPending: false
    property bool livePending: false
    property bool menuResolved: false

    readonly property bool menuReady: libraries.length > 0
                                      && (!root.posterGrid || menuResolved)
    readonly property bool posterMenu: root.posterGrid && menuResolved

    // A live channel, as opposed to a library item or a menu tile: it comes off
    // the DVR lineup and carries none of an item's fields.
    function isChannel(item) { return item !== null && item !== undefined
                                      && item.channelId !== undefined }

    // The artwork rule lives in PlexBackend::poster_url; tiles carry none, so
    // this returns "" for them and PosterCell draws its titled card instead. A
    // channel's logo is the EPG's, not the library's, and comes from its own
    // resolver — empty for a station the guide has no mark for, which draws the
    // same titled card and is why text alone still reads.
    function posterFor(item, w, h) {
        if (!item || item.nav !== undefined) return ""
        if (isChannel(item)) return plexBackend.live_channel_logo_url(item)
        return plexBackend.poster_url(item, Math.round(w), Math.round(h), "shelf")
    }

    // A tile has no badge either — posterFor already gave it none — and neither
    // has a channel: a logo is already the whole of what the cell is saying.
    function badgeFor(item, w, h) {
        if (!item || item.nav !== undefined || isChannel(item)) return ""
        return plexBackend.poster_url(item, Math.round(w), Math.round(h), "badge")
    }

    // The episode and show names, and the runtime, a 16:9 still cannot give. A
    // tile has none of them, and the shelf only asks on landscape cells anyway.
    function captionFor(item) {
        if (!item || item.nav !== undefined || isChannel(item)) return null
        return { top:    item.title || "",
                 bottom: item.grandparentTitle || "",
                 corner: item.durationDisplay || "" }
    }

    // The channel number, in the corner of the logo it belongs to. The title
    // line at the foot of the screen names one channel at a time, and a lineup
    // is walked by number — so the numbers belong on the cells, together.
    function cornerTagFor(item) {
        return isChannel(item) ? (item.number || "") : ""
    }

    // The card at the front of every shelf is a spine, not a poster: it is the
    // way through to the whole library, so it takes the least width it can and
    // PosterCell turns the label a quarter turn. Standing at the front of the
    // row, that turned name names the row — which is what let the heading go.
    //
    // Only that one card. The rest of a library's menu leads to a corner of it,
    // and those stay plain portrait cards wide enough to read RECOMMENDED.
    readonly property real spinePosterW: root.sh * 0.0375 //18
    function isSpine(item) {
        return item && (item.nav === "library_all" || item.nav === "live_all")
    }

    // Tiles are always portrait, whatever shape the art beside them is: matched
    // to a TV shelf's 16:9 stills, five of them would eat the row before a
    // single episode is in it. A cell keeps its aspect and the shelf's height
    // sets its size, so a width is asked for as the aspect that comes out that
    // wide at that height.
    function aspectFor(item) {
        if (!item) return 2 / 3
        // A spine is one width whatever it leads, so it is measured against the
        // height of its own shelf — the live row is the shorter of the two.
        if (isSpine(item)) {
            var h = (item.nav === "live_all") ? livePosterH : shelfPosterH
            return (h > 0) ? spinePosterW / h : 2 / 3
        }
        // Square, the way a YouTube channel's avatar is: a station logo is a
        // mark rather than cover art, and every one of them a different shape —
        // one box for the lot, each logo fitted whole inside it.
        if (isChannel(item)) return 1
        return (item.nav !== undefined) ? 2 / 3
                                        : plexBackend.poster_aspect(item, "shelf")
    }

    // A library's shelf: its own menu as tiles — the rows Library.qml lists —
    // then the items in progress. VIEW ALL and CATEGORIES need no probe. The
    // CONTINUE WATCHING tile sits last, immediately before the items it names,
    // so the posters at the end of a row are not read as the whole library.
    function tilesFor(lib) {
        var c = caps[lib.sectionId] || ({})
        var n = lib.title
        // label is what the card reads, title what the view it opens is called:
        // the card names its library because the shelf no longer does, while the
        // breadcrumb already has the library in front of it and would otherwise
        // say MOVIES > MOVIES CATEGORIES. The spine reads the bare name, not
        // VIEW ALL — that is said in captionTitle, where a selection is
        // described.
        var out = [{ nav: "library_all", title: "VIEW ALL", label: n }]
        if (c.recommended)
            out.push({ nav: "hubs", title: "RECOMMENDED", label: "RECOMMENDED " + n })
        if (c.collections)
            out.push({ nav: "collections", title: "COLLECTIONS", label: n + " COLLECTIONS" })
        if (c.playlists)
            out.push({ nav: "playlists", title: "PLAYLISTS", label: n + " PLAYLISTS" })
        out.push({ nav: "categories", title: "CATEGORIES", label: n + " CATEGORIES" })
        return out.concat(cwItems[lib.sectionId] || [])
    }

    // The LIVE TV shelf: the same spine every library shelf leads with — here it
    // opens the full channel list, which is what the row was before it had one —
    // and then the lineup, one square logo per channel.
    function liveTiles(lib) {
        return [{ nav: "live_all", title: "VIEW ALL", label: lib.title }]
               .concat(liveChannels)
    }


    // One flat column of entries. Each real library is a shelf holding its menu,
    // and LIVE TV is a shelf of the lineup — the one synthetic entry with
    // something of its own to put on a row. The all-libraries Continue Watching
    // list has no such thing and stays a nav row, as does LIVE TV on a server
    // whose lineup came back empty. Tiles carry no artwork, so PosterCell draws
    // them as its bordered titled cards.
    readonly property var navEntries: {
        var out = []
        for (var i = 0; i < libraries.length; i++) {
            var lib = libraries[i]
            if (posterMenu && lib.sectionId)
                out.push({ kind: "shelf", title: lib.title, lib: lib, items: tilesFor(lib) })
            else if (posterMenu && lib.key === "live_tv" && liveChannels.length > 0)
                out.push({ kind: "shelf", title: lib.title, lib: lib,
                           items: liveTiles(lib), live: true })
            else
                out.push({ kind: "row", title: lib.title, lib: lib })
        }
        return out
    }

    // Where the selection sits along the current shelf. Vertical steps reset it,
    // so Up and Down land on the front of the row they arrive at — a carried
    // column would drop out of a long Continue Watching run into the middle of
    // the next library. It survives leaving the screen (listState) and a shelf
    // being scrolled out of view and rebuilt.
    property int shelfColumn: 0

    // Shelf mode borrows the poster grid's taller content box: the AppBar ends
    // at y84 and the hint row starts at y414, so 104..397 is free. Without a
    // shelf every value here is today's layout unchanged.
    readonly property real contentTop: posterMenu ? root.sh * 0.2166667  //104
                                                  : root.sh * 0.25       //120
    readonly property real contentH: posterMenu ? root.sh * 0.5833333  //280
                                                : root.sh * 0.525      //252
    // One line for the whole screen, in the strip the shelves give up for it.
    readonly property real titleH: root.sh * 0.0375 //18
    readonly property real rowH: root.sh * 0.0583333 //28
    // Posters plus the cells' ring, and nothing else: the spine at the front of
    // the row already names the library, so a heading would say it a third time
    // for a quarter of a poster's height — which buys another library on the
    // screen instead. One row height for every library, whichever shape its art
    // is: 16:9 cells, with 2:3 covers brought down to the same height.
    readonly property real shelfGutter: root.sh * 0.0125 //6 — PosterShelf's frameW * 2
    readonly property real shelfPosterH: root.sh * 0.15625 //75
    readonly property real shelfEntryH: shelfPosterH + shelfGutter //81
    // One cover's width across, and square — so the live row measures the same
    // step as every other row on the screen instead of running wider than the
    // posters above and below it. A station logo stays recognisable that small,
    // the way a YouTube channel's avatar does, and the height the shorter row
    // gives back buys more of the menu.
    readonly property real livePosterH: shelfPosterH * 2 / 3 //50
    readonly property real liveEntryH: livePosterH + shelfGutter //56

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
    // binding can watch from out here, so every place that moves a selection
    // says so — the shelves included, through onMoved and on being built.
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

    // A step to another entry, as opposed to restoring a remembered position:
    // the shelf arrived at starts at its first item.
    function stepTo(i) {
        shelfColumn = 0
        moveTo(i)
    }

    // Builds the menu once every probe has answered. Called after each one and
    // once up front, so a server with nothing to probe does not wait at all.
    function resolveMenu() {
        if (menuResolved || capsPending > 0 || cwPending || livePending) return
        probeTimeout.stop()
        menuResolved = true
        restoreSelection()
    }

    function restoreSelection() {
        if (navEntries.length === 0) return
        shelfColumn = navListState.shelfColumn || 0
        var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
        moveTo(Math.min(restore, navEntries.length - 1))
    }

    function listState() {
        return { currentIndex: navList.currentIndex, shelfColumn: browseRoot.shelfColumn }
    }

    // Names a tile, and — beside the library heading — whatever the selection
    // is. An episode reads as its show plus SxEy, as it does in Items.qml: its
    // own name alone says nothing about which show it belongs to.
    function tileTitle(item) {
        if (!item) return ""
        if (item.nav !== undefined) return item.label || item.title || ""
        // A channel reads as it does in the full list: its number, then its name.
        if (isChannel(item))
            return (item.number ? item.number + "  " : "") + (item.title || "")
        if (item.type === "episode" && item.grandparentTitle) {
            var sNum = (item.parentIndex != null) ? item.parentIndex : "?"
            var eNum = (item.index != null) ? item.index : "?"
            return item.grandparentTitle + " S" + sNum + "E" + eNum + ": " + (item.title || "")
        }
        return item.title || ""
    }

    // What the title line says. The posters sit at the end of a row of menu
    // tiles, so what marks them as in-progress belongs on the item itself and
    // not only on the tile ahead of them.
    function captionTitle(item) {
        if (!item) return ""
        // The one cell whose name is not what it is but where it goes.
        if (isSpine(item)) return "VIEW ALL " + tileTitle(item)
        if (item.nav !== undefined) return tileTitle(item)
        // Named for what Return does with it, the way Continue is below: a logo
        // sitting on a menu row otherwise says nothing about being playable.
        if (isChannel(item)) return "Watch: " + tileTitle(item)
        return "Continue: " + tileTitle(item)
    }

    // Tiles reach the leaf views directly: with the menu on the shelf there is
    // nothing left for Library.qml to show, so it is not entered at all here.
    function openTile(lib, tile) {
        if (!lib || !tile) return
        browseRoot.navigateTo("Items.qml", {
            listType: tile.nav,
            title: tile.title,
            sectionId: lib.sectionId,
            libraryName: lib.title
        }, browseRoot.listState())
    }

    // A shelf holds both, so Return lands here first.
    function openShelfItem(lib, item) {
        if (!lib || !item) return
        // A channel is watched straight off the shelf; its spine falls through to
        // openLibrary, which is the LiveChannels list this row used to open.
        if (isChannel(item)) openLiveChannel(item)
        else if (item.nav === "live_all") openLibrary(lib)
        else if (item.nav !== undefined) openTile(lib, item)
        else openMedia(lib, item)
    }

    function openLiveChannel(channel) {
        browseRoot.navigateTo("LivePlayer.qml", { channel: channel },
                              browseRoot.listState())
    }

    // The same three destinations Items.qml picks between. Continue Watching is
    // episodes and movies, but the rule belongs with the item's type rather than
    // with the list it arrived in.
    function openMedia(lib, item) {
        var path = (item.type === "show") ? "ItemShow.qml"
                 : (item.type === "season") ? "ItemSeason.qml"
                 : "Item.qml"
        var params = { item: item, libraryName: lib.title }
        if (item.type === "season") params.showTitle = item.parentTitle || ""
        browseRoot.navigateTo(path, params, browseRoot.listState())
    }

    function openLibrary(lib) {
        if (!lib) return
        if (lib.key === "continue_watching") {
            browseRoot.navigateTo("Items.qml", {
                listType: "continue_watching",
                title: "CONTINUE WATCHING",
                libraryName: lib.title
            }, browseRoot.listState())
        } else if (lib.key === "live_tv") {
            browseRoot.navigateTo("LiveChannels.qml", {
                libraryName: lib.title
            }, browseRoot.listState())
        } else {
            browseRoot.navigateTo("Library.qml", {
                libraryName: lib.title,
                sectionId: lib.sectionId,
                sectionType: lib.sectionType
            }, browseRoot.listState())
        }
    }

    Connections {
        target: plexBackend

        function onLibrariesLoaded(items) {
            browseRoot.errorMsg = ""
            browseRoot.libraries = items
            if (!root.posterGrid) { browseRoot.restoreSelection(); return }

            // Every probe goes out at once — they are independent and small —
            // and the menu is built when the last one answers.
            browseRoot.caps = ({})
            browseRoot.cwItems = ({})
            browseRoot.liveChannels = []
            browseRoot.capsPending = 0
            browseRoot.cwPending = false
            browseRoot.livePending = false
            for (var i = 0; i < items.length; i++) {
                if (items[i].sectionId) {
                    browseRoot.capsPending++
                    plexBackend.check_section_capabilities(items[i].sectionId)
                } else if (items[i].key === "continue_watching") {
                    browseRoot.cwPending = true
                } else if (items[i].key === "live_tv") {
                    browseRoot.livePending = true
                }
            }
            if (browseRoot.cwPending) plexBackend.load_continue_watching()
            // Only when the server actually has a DVR — load_libraries has
            // already established that by the time the row is in the list.
            if (browseRoot.livePending) plexBackend.load_live_channels()
            probeTimeout.restart()
            browseRoot.resolveMenu()
        }

        function onCapabilitiesLoaded(c) {
            if (!c.sectionId) return
            // A 498 retry emits twice for the same section; only the first
            // answer is what capsPending is counting.
            if (browseRoot.caps[c.sectionId] === undefined) browseRoot.capsPending--
            browseRoot.caps[c.sectionId] = c
            browseRoot.capsChanged()
            browseRoot.resolveMenu()
        }

        function onContinueWatchingLoaded(items) {
            // One request covers every library; each shelf takes its own slice,
            // in the order the server sent — Plex's own recency order.
            var by = ({})
            for (var i = 0; i < items.length; i++) {
                var id = items[i].librarySectionID
                if (!id) continue
                if (!by[id]) by[id] = []
                by[id].push(items[i])
            }
            browseRoot.cwItems = by
            browseRoot.cwPending = false
            browseRoot.resolveMenu()
        }

        function onLiveChannelsLoaded(items) {
            browseRoot.liveChannels = items
            browseRoot.livePending = false
            browseRoot.resolveMenu()
        }

        function onErrorOccurred(msg) {
            console.log("[Library] Error: " + msg)
            // The libraries are already up, so this is a probe failing behind
            // them. Build the menu without what it could not confirm rather
            // than covering a working screen with an error.
            if (browseRoot.libraries.length > 0 && !browseRoot.menuResolved) {
                browseRoot.cwPending = false
                browseRoot.livePending = false
                browseRoot.capsPending = 0
                browseRoot.resolveMenu()
                return
            }
            browseRoot.errorMsg = msg
        }

        // The 401-recovery retry re-runs the user switch, which can turn out to
        // need the profile's PIN.
        function onUserPinRequired(userId, wrongPin) {
            browseRoot.replaceWith("ProfilePin.qml", {
                userId: userId,
                title: browseRoot.userName,
                reauth: true,
                wrongPin: wrongPin
            })
        }
    }

    // The menu used to appear the moment the libraries did; now it waits on the
    // probes, so a request that never answers would leave it on LOADING forever.
    // Past this the menu is built with whatever came back.
    Timer {
        id: probeTimeout
        interval: 5000
        onTriggered: {
            browseRoot.capsPending = 0
            browseRoot.cwPending = false
            browseRoot.livePending = false
            browseRoot.resolveMenu()
        }
    }

    Component.onCompleted: {
        browseRoot.userName = plexBackend.get_active_user_name()
        plexBackend.load_libraries()
    }

    focus: true

    // ---
    // UI
    // ---

    // Header. No subtitle: it used to carry SERVER (PROFILE), which the corner
    // now says on every screen — see StatusLine.qml.
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Loading Indicator
    Text {
        visible: !browseRoot.menuReady && browseRoot.errorMsg === ""
        text: "LOADING..."
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    // Error message
    Text {
        visible: browseRoot.errorMsg !== ""
        text: browseRoot.errorMsg
        color: root.secondaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        width: root.sw * 0.6 //384
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.0375 //18
    }

    // A nav row. Identical to the menu row this screen has always had.
    Component {
        id: rowComponent

        Item {
            readonly property bool current: navList.currentIndex === entryIndex

            Item {
                id: textClip
                width: Math.min(rowText.implicitWidth, navList.width)
                height: browseRoot.rowH
                clip: true

                Rectangle {
                    color: root.accentColor
                    anchors.fill: rowText
                    visible: current
                }

                Text {
                    id: rowText
                    text: entry.title || ""
                    color: current ? root.surfaceColor : root.primaryColor
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
                    running: current && (rowText.implicitWidth > textClip.width)
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

    // A library's Continue Watching row. Focus stays on navList — the shelf is
    // stepped from there — so it is told when it holds the selection.
    Component {
        id: shelfComponent

        // No size here: the Loader already has one and resizes what it loads,
        // which would only fight a binding set from in here.
        PosterShelf {
            // No heading: the spine at the front of the row is the library's
            // name, and a heading over it would only be saying it again.
            model: entry.items || []
            highlighted: navList.currentIndex === entryIndex
            showTitleLine: false
            // Station logos are fitted whole inside their squares; cover art is
            // cropped to fill its cell.
            logoArt: entry.live === true

            posterSource: browseRoot.posterFor
            badgeSource: browseRoot.badgeFor
            captionSource: browseRoot.captionFor
            cornerTagSource: browseRoot.cornerTagFor
            titleText: browseRoot.tileTitle
            posterAspectFor: browseRoot.aspectFor

            onMoved: {
                browseRoot.shelfColumn = currentIndex
                browseRoot.refreshSelected()
            }
            Component.onCompleted: {
                currentIndex = Math.min(browseRoot.shelfColumn, Math.max(0, count - 1))
                if (navList.currentIndex === entryIndex) browseRoot.refreshSelected()
            }
        }
    }

    // Body
    ListView {
        id: navList
        model: navEntries
        // Hidden until resolved: the entries are all plain nav rows until the
        // probes land, and flashing a text menu before the shelves reads as a
        // glitch rather than as loading.
        visible: browseRoot.menuReady
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: browseRoot.contentTop
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.76875 //492
        height: browseRoot.contentH
        clip: true
        focus: true
        // A shelf costs a row of poster requests, so only the entries on screen
        // (plus the one being scrolled to) are ever built.
        cacheBuffer: browseRoot.shelfEntryH

        Keys.onUpPressed: {
            if (count === 0) return
            // Off the top of the list is the SERVER | PROFILE line in the corner,
            // when this screen has one; otherwise the list wraps as it always has.
            if (currentIndex === 0 && moduleRoot.focusStatus()) return
            browseRoot.stepTo(currentIndex > 0 ? currentIndex - 1 : count - 1)
        }
        Keys.onDownPressed: {
            if (count === 0) return
            browseRoot.stepTo(currentIndex < count - 1 ? currentIndex + 1 : 0)
        }
        // Left and Right belong to the shelf, and to nothing else: they used to
        // double as the server switch, which made every walk to the front of a
        // shelf a near miss with leaving the screen. The switch is on the
        // SERVER | PROFILE line in the corner instead, up from the top row.
        Keys.onLeftPressed: {
            var sh = browseRoot.currentShelf()
            if (sh) sh.moveLeft()
        }
        Keys.onRightPressed: {
            var sh = browseRoot.currentShelf()
            if (sh) sh.moveRight()
        }
        Keys.onReturnPressed: {
            var e = browseRoot.entryAt(currentIndex)
            if (!e) return
            if (e.kind === "shelf") {
                var sh = browseRoot.currentShelf()
                browseRoot.openShelfItem(e.lib, sh ? sh.currentItemData : null)
                return
            }
            browseRoot.openLibrary(e.lib)
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                browseRoot.goBack()
                event.accepted = true
            }
        }

        delegate: Loader {
            required property int index
            required property var modelData

            readonly property var entry: modelData
            readonly property int entryIndex: index

            width: navList.width
            height: entry.kind !== "shelf" ? browseRoot.rowH
                  : entry.live                ? browseRoot.liveEntryH
                                              : browseRoot.shelfEntryH
            sourceComponent: entry.kind === "shelf" ? shelfComponent : rowComponent
        }
    }

    // Selected item's title: one line for the whole view rather than one per
    // shelf, which would repeat the heading it sits under and name an item rows
    // away from wherever the selection actually is.
    MarqueeText {
        visible: browseRoot.posterMenu
        anchors.left: parent.left
        anchors.bottom: footer.top
        anchors.leftMargin: root.sw * 0.115625 //74
        anchors.bottomMargin: root.sh * 0.0166667 //8
        height: browseRoot.titleH
        maxWidth: root.sw * 0.76875 //492
        text: browseRoot.captionTitle(browseRoot.selectedItem)
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: root.sh * 0.0375 //18
    }

    // Footer
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
