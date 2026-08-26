import QtQuick
import Components

// Reusable list view — handles all listType values via navParams.
FocusScope {
    id: itemListRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property string listType: navParams.listType || ""
    property string listTitle: navParams.title || ""
    property string sectionId: navParams.sectionId || ""
    property string hubKey: navParams.hubKey || ""
    property string ratingKey: navParams.ratingKey || ""
    property string categoryKey: navParams.categoryKey || ""
    property string libraryName: navParams.libraryName || ""

    // Where this view sits, named by everything walked through to reach it — a
    // category chain is otherwise four screens that all say MOVIES. A parent
    // hands the trail down; entered from a library menu it is the library and
    // this list's own name.
    readonly property var crumbs: {
        if (navParams.crumbs && navParams.crumbs.length > 0) return navParams.crumbs
        var out = libraryName ? [libraryName] : []
        // The all-libraries Continue Watching row is its own library name.
        if (listTitle && listTitle !== libraryName) out.push(listTitle)
        return out
    }
    readonly property string breadcrumb: crumbs.join(" > ")

    // The trail to hand a child: everything that led here, plus the row opened.
    function deeper(title) {
        return crumbs.concat([title || ""])
    }

    property var items: []
    property bool isLoading: false
    property string errorMessage: ""

    property bool showLetterNav: listType === "library_all"
    property bool letterNavActive: false
    property var letterIndex: []

    // Poster grid replaces the text list only where the rows are real media.
    // Directory rows (hubs, collections, playlists, categories) have no artwork
    // and stay as text, which falls out of mediaList with no extra branching.
    readonly property bool mediaList: ["library_all", "hub_items", "collection_items",
                                       "category_items", "continue_watching",
                                       "library_continue_watching"]
                                      .indexOf(listType) >= 0
    readonly property bool usePosterGrid: root.posterGrid && mediaList && !useShelves

    // Two lists are groups rather than one flat run, and with cover art on they
    // are drawn as those groups — a shelf each.
    //
    // Hubs: the server already sent each hub's items with its name
    // (PlexBackend::load_section_hubs); a hub of directories has no shelf.
    // Continue Watching: one mixed list split by library, in the order the
    // libraries first appear — Plex's own recency order.
    readonly property var shelfModel: {
        if (!root.posterGrid) return []
        var out = []
        var i
        if (listType === "hubs") {
            for (i = 0; i < items.length; i++) {
                var hub = items[i]
                if (hub && hub.items && hub.items.length > 0)
                    out.push({ title: hub.title, items: hub.items })
            }
            return out
        }
        if (listType === "continue_watching") {
            var order = [], byLibrary = ({})
            for (i = 0; i < items.length; i++) {
                var id = items[i].librarySectionID || ""
                if (!byLibrary[id]) { byLibrary[id] = []; order.push(id) }
                byLibrary[id].push(items[i])
            }
            for (i = 0; i < order.length; i++) {
                var bucket = byLibrary[order[i]]
                out.push({ title: bucket[0].librarySectionTitle || "CONTINUE WATCHING",
                           items: bucket })
            }
            return out
        }
        return out
    }
    // One section is not a sectioned view — a lone heading over a shelf shows
    // fewer items than the grid would and names something already in the title
    // bar. Hubs are exempt: a hub's name is the only thing saying what it is.
    readonly property bool useShelves: (listType === "continue_watching")
                                       ? shelfModel.length > 1
                                       : shelfModel.length > 0

    // Selection lives on whichever view is active; everything else in this file
    // reads and writes it through these two so both modes behave identically.
    readonly property int selectedIndex: usePosterGrid ? posterGridView.currentIndex
                                                       : itemList.currentIndex
    // atBeginning puts the item at the top of the view instead of scrolling the
    // minimum distance — what the A-Z panel wants when it jumps to a letter.
    function setSelectedIndex(i, atBeginning) {
        if (usePosterGrid) {
            posterGridView.currentIndex = i
            posterGridView.positionAtCurrent(atBeginning === true)
        } else {
            itemList.currentIndex = i
            itemList.positionViewAtIndex(i, atBeginning === true ? ListView.Beginning
                                                                 : ListView.Contain)
        }
    }

    function restoreShelves() {
        shelfView.setPosition(navListState.shelfIndex || 0, navListState.itemIndex || 0)
        shelfView.forceActiveFocus()
    }

    function focusActiveView() {
        if (useShelves) shelfView.forceActiveFocus()
        else if (usePosterGrid) posterGridView.forceActiveFocus()
        else itemList.forceActiveFocus()
    }

    // Grid mode runs a tighter A-Z panel than the text list does — a single
    // letter needs very little width, and every pixel saved goes to the covers.
    readonly property real letterNavWidth: usePosterGrid ? root.sw * 0.025      //16
                                                         : root.sw * 0.0328125  //21
    readonly property real letterNavGap: usePosterGrid ? root.sw * 0.0125  //8
                                                       : root.sw * 0.0375  //24

    // The artwork rule lives in PlexBackend::poster_url; these are null guards
    // over its two cell contexts. A grid gives an episode its show's poster so a
    // library tiles evenly; a shelf is a handful of items, where the episode's
    // own still identifies it better than a repeated cover.
    function posterFor(item, w, h) {
        return item ? plexBackend.poster_url(item, Math.round(w), Math.round(h)) : ""
    }

    function shelfPosterFor(item, w, h) {
        return item ? plexBackend.poster_url(item, Math.round(w), Math.round(h), "shelf") : ""
    }

    // The show (or season) cover that PosterShelf lays over a wide cell. Only
    // ever asked for on a 16:9 still, which is the case that does not say what
    // it belongs to.
    function shelfBadgeFor(item, w, h) {
        return item ? plexBackend.poster_url(item, Math.round(w), Math.round(h), "badge") : ""
    }

    // The two lines that ride over a 16:9 still, for the same reason the badge
    // does: the frame names neither the show it came from nor which episode it
    // is. The shelf asks for these on landscape cells only.
    function shelfCaptionFor(item) {
        if (!item) return null
        // Episode over show over runtime: the still is of the episode, so its
        // own name is the caption and the show it belongs to is the context
        // underneath — the same order YouTube reads video over channel.
        return { top:    item.title || "",
                 bottom: item.grandparentTitle || "",
                 corner: item.durationDisplay || "" }
    }

    // Cells share the shelf's height and take their width from their own art,
    // so a 16:9 still and a 2:3 cover both appear whole.
    function shelfAspectFor(item) {
        return item ? plexBackend.poster_aspect(item, "shelf") : 2 / 3
    }

    // An episode reads as its show plus SxEy: on a poster surface the artwork is
    // the show's, so the title is the only thing saying which episode this is.
    function mediaTitle(item) {
        if (!item) return ""
        if (item.type === "episode" && item.grandparentTitle) {
            var sNum = (item.parentIndex != null) ? item.parentIndex : "?"
            var eNum = (item.index != null) ? item.index : "?"
            return item.grandparentTitle + " S" + sNum + "E" + eNum + ": " + (item.title || "")
        }
        var base = item.title || ""
        return item.editionTitle ? base + " (" + item.editionTitle + ")" : base
    }

    // Buckets by the server's sort title when one is set (Plex sorts the list by
    // titleSort), otherwise falls back to article-stripping the display title —
    // which is what Plex itself does for items without a custom sort title.
    function sortKey(item) {
        var sortTitle = (item && item.titleSort) || ""
        var t = (sortTitle || (item && item.title) || "").toLowerCase()
        if (!sortTitle) {
            var articles = ["the ", "a ", "an "]
            for (var i = 0; i < articles.length; i++) {
                if (t.indexOf(articles[i]) === 0) { t = t.substring(articles[i].length); break }
            }
        }
        var ch = t.charAt(0).toUpperCase()
        return (ch >= 'A' && ch <= 'Z') ? ch : '#'
    }

    // Highlights the letter matching the currently selected item.
    function syncLetterToItem() {
        var curLetter = sortKey(items[selectedIndex])
        for (var i = 0; i < letterIndex.length; i++) {
            if (letterIndex[i].letter === curLetter) { letterList.currentIndex = i; break }
        }
        letterList.positionViewAtIndex(letterList.currentIndex, ListView.Contain)
    }

    function buildLetterIndex(itemArr) {
        var seen = {}
        var result = []
        for (var i = 0; i < itemArr.length; i++) {
            var letter = sortKey(itemArr[i])
            if (!seen[letter]) {
                seen[letter] = true
                result.push({ letter: letter, firstIndex: i })
            }
        }
        result.sort(function(a, b) {
            if (a.letter === '#') return -1
            if (b.letter === '#') return 1
            return a.letter < b.letter ? -1 : 1
        })
        return result
    }

    // ----------------------------------------------------------------
    // Signal connections from backend
    // ----------------------------------------------------------------

    Connections {
        target: plexBackend

        function onItemsLoaded(loadedItems) {
            var consuming = ["library_all", "hub_items", "collection_items",
                             "playlist_items", "category_items", "continue_watching"]
            if (consuming.indexOf(itemListRoot.listType) >= 0) {
                itemListRoot.isLoading = false
                itemListRoot.items = loadedItems
                if (itemListRoot.showLetterNav)
                    itemListRoot.letterIndex = itemListRoot.buildLetterIndex(loadedItems)
                if (loadedItems.length > 0) {
                    var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                    setSelectedIndex(Math.min(restore, loadedItems.length - 1))
                }
            }
        }

        function onContinueWatchingLoaded(loadedItems) {
            var perLibrary = (itemListRoot.listType === "library_continue_watching")
            if (perLibrary || itemListRoot.listType === "continue_watching") {
                // The server has no per-library Continue Watching endpoint — it
                // returns one mixed list — so a library's own view is that list
                // filtered by the section each item came from.
                if (perLibrary) {
                    var mine = []
                    for (var i = 0; i < loadedItems.length; i++)
                        if (loadedItems[i].librarySectionID === itemListRoot.sectionId)
                            mine.push(loadedItems[i])
                    loadedItems = mine
                }
                itemListRoot.isLoading = false
                itemListRoot.items = loadedItems
                if (loadedItems.length === 0) return
                if (itemListRoot.useShelves) { itemListRoot.restoreShelves(); return }
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                setSelectedIndex(Math.min(restore, loadedItems.length - 1))
            }
        }

        function onHubsLoaded(loadedHubs) {
            if (itemListRoot.listType === "hubs") {
                itemListRoot.isLoading = false
                itemListRoot.items = loadedHubs
                if (loadedHubs.length === 0) return
                if (itemListRoot.useShelves) { itemListRoot.restoreShelves(); return }
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                setSelectedIndex(Math.min(restore, loadedHubs.length - 1))
            }
        }

        function onCollectionsLoaded(loadedItems) {
            if (itemListRoot.listType === "collections") {
                itemListRoot.isLoading = false
                itemListRoot.items = loadedItems
                if (itemListRoot.showLetterNav)
                    itemListRoot.letterIndex = itemListRoot.buildLetterIndex(loadedItems)
                if (loadedItems.length > 0) {
                    var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                    setSelectedIndex(Math.min(restore, loadedItems.length - 1))
                }
            }
        }

        function onPlaylistsLoaded(loadedItems) {
            if (itemListRoot.listType === "playlists") {
                itemListRoot.isLoading = false
                itemListRoot.items = loadedItems
                if (itemListRoot.showLetterNav)
                    itemListRoot.letterIndex = itemListRoot.buildLetterIndex(loadedItems)
                if (loadedItems.length > 0) {
                    var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                    setSelectedIndex(Math.min(restore, loadedItems.length - 1))
                }
            }
        }

        function onCategoriesLoaded(loadedItems) {
            if (itemListRoot.listType === "categories") {
                itemListRoot.isLoading = false
                itemListRoot.items = loadedItems
                if (loadedItems.length > 0) {
                    var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                    setSelectedIndex(Math.min(restore, loadedItems.length - 1))
                }
            }
        }

        function onErrorOccurred(msg) {
            if (itemListRoot.listType !== "") {
                itemListRoot.isLoading = false
                itemListRoot.errorMessage = msg
            }
            console.log("[ItemList] Error: " + msg)
        }
    }

    // ----------------------------------------------------------------
    // Select item — navigate based on type
    // ----------------------------------------------------------------

    function selectItem() {
        var item = items[selectedIndex]
        if (!item) return

        // Intermediate lists that navigate deeper
        if (listType === "hubs") {
            // Hub selected → load items for that hub
            itemListRoot.navigateTo("Items.qml", {
                listType: "hub_items",
                title: item.title,
                hubKey: item.hubKey || item.key,
                libraryName: libraryName,
                crumbs: itemListRoot.deeper(item.title)
            }, { currentIndex: selectedIndex })
            return
        }

        if (listType === "collections") {
            itemListRoot.navigateTo("Items.qml", {
                listType: "collection_items",
                title: item.title,
                ratingKey: item.ratingKey,
                libraryName: libraryName,
                crumbs: itemListRoot.deeper(item.title)
            }, { currentIndex: selectedIndex })
            return
        }

        if (listType === "playlists") {
            itemListRoot.navigateTo("Items.qml", {
                listType: "playlist_items",
                title: item.title,
                ratingKey: item.ratingKey,
                libraryName: libraryName,
                crumbs: itemListRoot.deeper(item.title)
            }, { currentIndex: selectedIndex })
            return
        }

        if (listType === "categories") {
            // Boolean filters (e.g. hdr) have no directory listing — apply directly
            var catKey = (item.filterType === "boolean") ? item.key + "=1" : item.key
            itemListRoot.navigateTo("Items.qml", {
                listType: "category_items",
                title: item.title,
                sectionId: sectionId,
                categoryKey: catKey,
                libraryName: libraryName,
                crumbs: itemListRoot.deeper(item.title)
            }, { currentIndex: selectedIndex })
            return
        }

        // For category_items the items are sub-filter values (e.g. genre names),
        // not actual media. Navigate further if type is 'genre_item'.
        if (item.type === "genre_item") {
            // item.ratingKey is actually the filter value key from the server
            // Use it to load actual media items
            itemListRoot.navigateTo("Items.qml", {
                listType: "category_items",
                title: item.title,
                sectionId: item._sectionId || sectionId,
                categoryKey: item._filterKey + "=" + encodeURIComponent(item.ratingKey),
                libraryName: libraryName,
                crumbs: itemListRoot.deeper(item.title)
            }, { currentIndex: selectedIndex })
            return
        }

        itemListRoot.openMedia(item, { currentIndex: selectedIndex })
    }

    // A media row's detail view, by type. Shared by the list, the grid and the
    // shelves — the shelves reach media directly, without a hub row in between,
    // so they cannot go through selectItem.
    function openMedia(item, listState) {
        if (!item) return

        if (item.type === "show") {
            itemListRoot.navigateTo("ItemShow.qml", {
                item: item,
                libraryName: libraryName
            }, listState)
            return
        }

        // Hub shelves are not season-flattened, so a season row can arrive here.
        if (item.type === "season") {
            itemListRoot.navigateTo("ItemSeason.qml", {
                item: item,
                showTitle: item.parentTitle || "",
                libraryName: libraryName
            }, listState)
            return
        }

        itemListRoot.navigateTo("Item.qml", {
            item: item,
            libraryName: libraryName
        }, listState)
    }

    // ----------------------------------------------------------------
    // Data loading on appear
    // ----------------------------------------------------------------

    Component.onCompleted: {
        isLoading = true
        errorMessage = ""
        if (listType === "library_all")
            plexBackend.load_library_all(sectionId)
        else if (listType === "hub_items")
            plexBackend.load_items_for_hub(hubKey)
        else if (listType === "hubs")
            plexBackend.load_section_hubs(sectionId)
        else if (listType === "collections")
            plexBackend.load_collections(sectionId)
        else if (listType === "collection_items")
            plexBackend.load_collection_items(ratingKey)
        else if (listType === "playlists")
            plexBackend.load_playlists(sectionId)
        else if (listType === "playlist_items")
            plexBackend.load_playlist_items(ratingKey)
        else if (listType === "categories")
            plexBackend.load_categories(sectionId)
        else if (listType === "category_items")
            plexBackend.load_category_items(sectionId, categoryKey)
        else if (listType === "continue_watching" || listType === "library_continue_watching")
            plexBackend.load_continue_watching()
    }

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    // ---
    // UI
    // ---

    // Header
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: itemListRoot.breadcrumb
        // The last crumb is the one that says what is on screen, so a trail too
        // long for the bar loses its front rather than its end.
        subtitleElide: Text.ElideLeft
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
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
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: root.sh * 0.05 //24
    }
    Text {
        visible: !isLoading && errorMessage === "" && items.length === 0
        text: "NO ITEMS FOUND"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    // Body
    ListView {
        id: itemList
        model: items
        visible: !usePosterGrid && !useShelves
        opacity: letterNavActive ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: showLetterNav ? root.sw * 0.671875 : root.sw * 0.76875 //430 or 492
        height: root.sh * 0.525 //252
        clip: true
        focus: !usePosterGrid && !useShelves

        Keys.onUpPressed: {
            if (count === 0) return
            // Off the top of the list is the SERVER | PROFILE line in the corner,
            // when this screen has one; otherwise the list wraps as it always has.
            if (currentIndex === 0 && moduleRoot.focusStatus()) return
            if (currentIndex > 0) {
                currentIndex--
                itemListRoot.syncLetterToItem()
            }
            else {
                currentIndex = count - 1
                itemList.positionViewAtIndex(currentIndex, ListView.Contain)
                letterList.currentIndex = letterIndex.length - 1
                letterList.positionViewAtIndex(letterList.currentIndex, ListView.Contain)
            }
        }
        Keys.onDownPressed: {
            if (count === 0) return
            if (currentIndex < count - 1) {
                currentIndex++
                itemListRoot.syncLetterToItem()
            }
            else {
                currentIndex = 0
                itemList.positionViewAtIndex(currentIndex, ListView.Contain)
                letterList.currentIndex = 0
                letterList.positionViewAtIndex(letterList.currentIndex, ListView.Contain)
            }
        }
        Keys.onReturnPressed: itemListRoot.selectItem()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                itemListRoot.goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Right && showLetterNav && letterIndex.length > 0) {
                itemListRoot.syncLetterToItem()
                letterNavActive = true
                letterList.forceActiveFocus()
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
                    visible: itemList.currentIndex === index && !letterNavActive
                }

                Text {
                    id: rowText
                    text: itemListRoot.mediaTitle(modelData)
                    color: (itemList.currentIndex === index && !letterNavActive)
                       ? root.surfaceColor : root.primaryColor
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

    // Poster grid — same slot as itemList, exactly one of the two visible.
    PosterGrid {
        id: posterGridView
        visible: usePosterGrid
        focus: usePosterGrid
        // Starved when hidden: an invisible GridView still builds delegates, and
        // each one would fetch a poster.
        model: usePosterGrid ? items : []
        opacity: letterNavActive ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        // Taller and higher than the text list's slot: three rows of covers need
        // the room, and the AppBar ends at y84 while the hint row starts at y414.
        anchors.topMargin: root.sh * 0.2166667 //104
        anchors.leftMargin: root.sw * 0.115625 //74
        width: showLetterNav ? root.sw * 0.73125 : root.sw * 0.76875 //468 or 492
        height: root.sh * 0.6104167 //293

        rows: 3
        posterSource: itemListRoot.posterFor
        titleText: itemListRoot.mediaTitle
        browseEnabled: showLetterNav && letterIndex.length > 0
        // Above the top row is the corner's SERVER | PROFILE line when this
        // screen has one; with nothing up there the grid keeps its own wrap.
        exitUpEnabled: moduleRoot.statusNavigable

        onExitUp: moduleRoot.focusStatus()
        onActivated: itemListRoot.selectItem()
        onBackRequested: itemListRoot.goBack()
        onBrowseRequested: {
            itemListRoot.syncLetterToItem()
            letterNavActive = true
            letterList.forceActiveFocus()
        }
    }

    // Sectioned shelves — a hub menu drawn as its hubs, or Continue Watching
    // drawn as its libraries. Same slot as the poster grid; the A-Z panel never
    // applies to either, so it takes the full width.
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

        posterSource: itemListRoot.shelfPosterFor
        posterAspectFor: itemListRoot.shelfAspectFor
        badgeSource: itemListRoot.shelfBadgeFor
        captionSource: itemListRoot.shelfCaptionFor
        titleText: itemListRoot.mediaTitle
        // Same as the grid above: the top shelf steps out to the corner's
        // SERVER | PROFILE line rather than wrapping, when there is one to
        // step to. exitDown then has to do the wrap the shelves gave up.
        wrapVertically: !moduleRoot.statusNavigable

        onExitUp: moduleRoot.focusStatus()
        onExitDown: shelfView.focusEnd(false)
        onActivated: function(item) {
            itemListRoot.openMedia(item, { shelfIndex: shelfView.shelfIndex,
                                           itemIndex: shelfView.itemIndex })
        }
        onBackRequested: itemListRoot.goBack()
    }

    // Letter navigation panel
    ListView {
        id: letterList
        model: letterIndex
        visible: showLetterNav && letterIndex.length > 0
        opacity: letterNavActive ? 1.0 : 0.3
        anchors.left: usePosterGrid ? posterGridView.right : itemList.right
        anchors.leftMargin: itemListRoot.letterNavGap
        anchors.top: usePosterGrid ? posterGridView.top : itemList.top
        width: itemListRoot.letterNavWidth
        height: usePosterGrid ? posterGridView.height : itemList.height
        clip: true
        focus: false

        Keys.onUpPressed: {
            if (count === 0) return
            if (currentIndex > 0) {
                currentIndex--
            }
            else {
                currentIndex = count - 1
                letterList.positionViewAtIndex(letterList.currentIndex, ListView.Beginning)
            }
            itemListRoot.setSelectedIndex(letterIndex[currentIndex].firstIndex, true)
        }
        Keys.onDownPressed: {
            if (count === 0) return
            if (currentIndex < count - 1) {
                currentIndex++
            }
            else {
                currentIndex = 0
                letterList.positionViewAtIndex(letterList.currentIndex, ListView.Beginning)
            }
            itemListRoot.setSelectedIndex(letterIndex[currentIndex].firstIndex, true)
        }
        Keys.onReturnPressed: {
            letterNavActive = false
            itemListRoot.focusActiveView()
        }
        Keys.onLeftPressed: {
            letterNavActive = false
            itemListRoot.focusActiveView()
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                letterNavActive = false
                itemListRoot.focusActiveView()
                event.accepted = true
            }
        }

        delegate: Item {
            width: letterList.width
            height: root.sh * 0.04375 //21

            Rectangle {
                color: root.accentColor
                anchors.fill: parent
                visible: letterList.currentIndex === index && letterNavActive
            }

            Text {
                text: modelData.letter
                color: (letterList.currentIndex === index && letterNavActive)
                       ? root.surfaceColor : root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.0354167 //17
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                rightPadding: root.sw * 0.009375 //6
                topPadding: root.sh * 0.0041667 //2
                bottomPadding: root.sh * 0.00625 //3
            }
        }
    }

    // Footer
    Text {
        id: footer
        text: showLetterNav
              ? root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.browse + ":BROWSE " + root.hints.select + ":SELECT"
              : root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
