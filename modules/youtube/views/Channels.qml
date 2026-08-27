import QtQuick
import Components

// Alphabetical channel list with the A–Z letter-nav panel
// (pattern from modules/plex/views/Items.qml).
//
// With the global poster-grid setting on, the same list is drawn as a wall of
// channel avatars instead — square, because a profile picture is.
FocusScope {
    id: channelsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var items: []
    property bool isLoading: false
    property string errorMessage: ""

    property bool letterNavActive: false
    property var letterIndex: []

    readonly property bool usePosterGrid: root.posterGrid

    // Avatars are scraped one at a time in the background, so the cells fill in
    // after the list is already on screen. A cell's art: binding tracks every
    // property posterFor() reads, so bumping this re-runs them — reassigning
    // items would do it too, but that resets the grid under the selection.
    property int artRev: 0

    function sortKey(title) {
        var t = (title || "").toLowerCase()
        var articles = ["the ", "a ", "an "]
        for (var i = 0; i < articles.length; i++) {
            if (t.indexOf(articles[i]) === 0) { t = t.substring(articles[i].length); break }
        }
        var ch = t.charAt(0).toUpperCase()
        return (ch >= 'A' && ch <= 'Z') ? ch : '#'
    }

    function buildLetterIndex(itemArr) {
        var seen = {}
        var result = []
        for (var i = 0; i < itemArr.length; i++) {
            var letter = sortKey(itemArr[i].title || "")
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

    // The channel's avatar, sized to the cell so the image host does the
    // resizing. Empty until the backend has resolved that channel, which draws
    // PosterCell's titled placeholder rather than a broken-image box.
    function posterFor(item, w, h) {
        // artRev is read rather than used: that read is what subscribes the
        // cell's art: binding to it, so a fetch landing refreshes the cells.
        var rev = channelsRoot.artRev
        // youtubeBackend reads back null while the view's Loader tears down and
        // every binding runs one last time — the same reason views bind
        // root.hints rather than inputManager.hints.
        if (!item || rev < 0 || !youtubeBackend) return ""
        return youtubeBackend.channel_art_url(item.channelId, Math.round(Math.max(w, h)))
    }

    // Selection lives on whichever view is active; everything else in this file
    // reads and writes it through these two so both modes behave identically.
    readonly property int selectedIndex: usePosterGrid ? posterGridView.currentIndex
                                                       : itemList.currentIndex
    // atBeginning puts the row at the top of the view instead of scrolling the
    // minimum distance — what the A–Z panel wants when it jumps to a letter.
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

    function focusActiveView() {
        if (usePosterGrid) posterGridView.forceActiveFocus()
        else itemList.forceActiveFocus()
    }

    // Highlights the letter matching the currently selected channel.
    function syncLetterToItem() {
        var curLetter = sortKey((items[selectedIndex] && items[selectedIndex].title) || "")
        for (var i = 0; i < letterIndex.length; i++) {
            if (letterIndex[i].letter === curLetter) { letterList.currentIndex = i; break }
        }
        letterList.positionViewAtIndex(letterList.currentIndex, ListView.Contain)
    }

    function openSelected() {
        var item = items[selectedIndex]
        if (!item)
            return
        channelsRoot.navigateTo("Subscriptions.qml", {
            mode: "channel",
            channelId: item.channelId,
            channelName: item.title
        }, { currentIndex: selectedIndex })
    }

    function enterLetterNav() {
        if (letterIndex.length === 0)
            return
        syncLetterToItem()
        letterNavActive = true
        letterList.forceActiveFocus()
    }

    // Grid mode runs a tighter A–Z panel than the text list does — a single
    // letter needs very little width, and every pixel saved goes to the avatars.
    readonly property real letterNavWidth: usePosterGrid ? root.sw * 0.025      //16
                                                         : root.sw * 0.0328125  //21
    readonly property real letterNavGap: usePosterGrid ? root.sw * 0.0125  //8
                                                       : root.sw * 0.0375  //24

    Component.onCompleted: {
        isLoading = true
        errorMessage = ""
        youtubeBackend.load_channels()
    }

    Connections {
        target: youtubeBackend

        function onChannelsLoaded(channels) {
            channelsRoot.isLoading = false
            // A list arriving supersedes a failure reported before it: the
            // backend keeps trying behind a message, and what is on screen
            // should be the newer answer.
            channelsRoot.errorMessage = ""
            channelsRoot.items = channels
            channelsRoot.letterIndex = channelsRoot.buildLetterIndex(channels)
            if (channels.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                channelsRoot.setSelectedIndex(Math.min(restore, channels.length - 1))
            }
        }

        function onChannelArtLoaded(channelId, artUrl) {
            channelsRoot.artRev++
        }

        function onErrorOccurred(msg) {
            channelsRoot.isLoading = false
            channelsRoot.errorMessage = msg
        }
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

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: "Channels"
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
        text: "NO CHANNELS FOUND"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    // Channel list
    ListView {
        id: itemList
        model: usePosterGrid ? [] : items
        visible: !usePosterGrid
        opacity: letterNavActive ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.25 //120
        anchors.leftMargin: root.sw * 0.115625 //74
        width: root.sw * 0.671875 //430
        height: root.sh * 0.525 //252
        clip: true
        focus: !usePosterGrid

        Keys.onUpPressed: {
            if (count === 0) return
            if (currentIndex > 0) {
                channelsRoot.setSelectedIndex(currentIndex - 1)
                channelsRoot.syncLetterToItem()
            }
            else {
                channelsRoot.setSelectedIndex(count - 1)
                letterList.currentIndex = letterIndex.length - 1
                letterList.positionViewAtIndex(letterList.currentIndex, ListView.Contain)
            }
        }
        Keys.onDownPressed: {
            if (count === 0) return
            if (currentIndex < count - 1) {
                channelsRoot.setSelectedIndex(currentIndex + 1)
                channelsRoot.syncLetterToItem()
            }
            else {
                channelsRoot.setSelectedIndex(0)
                letterList.currentIndex = 0
                letterList.positionViewAtIndex(letterList.currentIndex, ListView.Contain)
            }
        }
        Keys.onReturnPressed: channelsRoot.openSelected()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                channelsRoot.goBack()
                event.accepted = true
            } else if (event.key === Qt.Key_Right && letterIndex.length > 0) {
                channelsRoot.enterLetterNav()
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
                    text: modelData.title || ""
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

    // Avatar grid — same slot as itemList, exactly one of the two visible.
    PosterGrid {
        id: posterGridView
        visible: usePosterGrid
        focus: usePosterGrid
        // Starved when hidden: an invisible GridView still builds delegates, and
        // each one would fetch an avatar.
        model: usePosterGrid ? items : []
        opacity: letterNavActive ? 0.3 : 1
        anchors.top: parent.top
        anchors.left: parent.left
        // Taller and higher than the text list's slot: three rows of avatars
        // need the room, and the AppBar ends at y84 while the hints start at y414.
        anchors.topMargin: root.sh * 0.2166667 //104
        anchors.leftMargin: root.sw * 0.115625 //74
        width: letterIndex.length > 0 ? root.sw * 0.73125 : root.sw * 0.76875 //468 or 492
        height: root.sh * 0.6104167 //293

        rows: 3
        // Square: a channel avatar is a circle in a square, not cover art.
        posterAspect: 1
        posterSource: channelsRoot.posterFor
        browseEnabled: letterIndex.length > 0

        onActivated: channelsRoot.openSelected()
        onBackRequested: channelsRoot.goBack()
        onBrowseRequested: channelsRoot.enterLetterNav()
    }

    // Letter navigation panel
    ListView {
        id: letterList
        model: letterIndex
        visible: letterIndex.length > 0
        opacity: letterNavActive ? 1.0 : 0.3
        anchors.left: usePosterGrid ? posterGridView.right : itemList.right
        anchors.leftMargin: channelsRoot.letterNavGap
        anchors.top: usePosterGrid ? posterGridView.top : itemList.top
        width: channelsRoot.letterNavWidth
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
            channelsRoot.setSelectedIndex(letterIndex[currentIndex].firstIndex, true)
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
            channelsRoot.setSelectedIndex(letterIndex[currentIndex].firstIndex, true)
        }
        Keys.onReturnPressed: {
            letterNavActive = false
            channelsRoot.focusActiveView()
        }
        Keys.onLeftPressed: {
            letterNavActive = false
            channelsRoot.focusActiveView()
        }
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                letterNavActive = false
                channelsRoot.focusActiveView()
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
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.browse + ":BROWSE " + root.hints.select + ":SELECT"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
