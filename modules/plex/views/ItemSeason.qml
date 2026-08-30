import QtQuick
import Components

FocusScope {
    id: seasonRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property var item: navParams.item || {}
    property string showTitle: navParams.showTitle || item.grandparentTitle || ""
    property string libraryName: navParams.libraryName || ""

    property var episodes: []
    property bool isLoading: false

    // Extras attached to this season (trailers, behind the scenes, …)
    property var extras: []
    readonly property bool hasExtras: extras.length > 0

    // Poster art. The image loads whenever the feature is on; showPoster only
    // flips once it is actually decoded, so a season with no art keeps the
    // original full-width layout rather than leaving a hole.
    readonly property string posterUrl: root.posterGrid
        ? plexBackend.poster_url(item, root.sw * 0.1875, root.sh * 0.25, "detail") : ""
    readonly property bool showPoster: posterImage.status === Image.Ready

    // With a poster in the left column the episode list no longer fits beneath
    // the details row, so it moves alongside — right of the poster, under the
    // season/year line. Both branches of each are today's values.
    readonly property real sectionX: showPoster ? root.sw * 0.209375 : 0 //144 : 0
    readonly property real sectionW: showPoster ? root.sw * 0.54375   //348
                                                : root.sw * 0.76875   //492

    // The action column's own geometry. A 2:3 poster drawn at the column's full
    // width stands taller than the buttons under it have room for, so it is
    // capped here: the picture is decoration, the buttons are the screen's
    // purpose, and the poster is what gives way for them.
    readonly property real maxPosterH: root.sh * 0.35 //168

    // Bottom edge of whichever action button holds the focus, measured inside
    // the column. 0 when the focus is elsewhere, which parks the column at rest.
    readonly property real focusedActionBottom: {
        var b = focusRow === 0 ? playButton
              : focusRow === 1 ? extrasButton
              : focusRow === 4 ? writeCardButton : null
        return b ? b.y + b.height : 0
    }

    // Episode still beside each row title. The taller rows spend the same extra
    // box height the poster unlocked, so the two appear together and the list
    // can never outgrow the content box. Slot width is reserved for every row
    // so titles line up whether or not an episode has a still.
    readonly property bool rowArt: showPoster
    readonly property real rowArtW: root.sw * 0.09375    //60 — a 16:9 still at rowArtH
    readonly property real rowArtH: root.sh * 0.0666667  //32
    function rowArtFor(m) {
        return (rowArt && m) ? plexBackend.poster_url(m, rowArtW, rowArtH, "detail") : ""
    }

    // Focus rows: 0 = play button, 1 = extras (when hasExtras),
    // 4 = write NFC card (when a reader is present), 2 = episode list.
    // The NFC row is 4 rather than 3 so the existing saved-focus restores, which
    // compare against literal row numbers, keep working untouched.
    property int focusRow: 0

    property color baseColor: root.primaryColor

    Connections {
        target: plexBackend

        function onChildrenLoaded(loadedItems) {
            seasonRoot.isLoading = false
            seasonRoot.episodes = loadedItems
            if (loadedItems.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                episodeList.currentIndex = Math.min(restore, loadedItems.length - 1)
                if (navListState.focusRow === 2) focusRow = 2
                episodeList.positionViewAtIndex(episodeList.currentIndex, ListView.Contain)
            }
        }

        function onExtrasLoaded(items) {
            seasonRoot.extras = items
            if (navListState.focusRow === 1 && items.length > 0) focusRow = 1
        }

        function onErrorOccurred(msg) {
            seasonRoot.isLoading = false
            console.log("[SeasonItem] Error: " + msg)
        }
    }

    Component.onCompleted: {
        isLoading = true
        focusRow = 0
        if (item.ratingKey) {
            plexBackend.load_children(item.ratingKey)
            plexBackend.load_extras(item.ratingKey)
        }
    }

    focus: true

    // Season label as displayed in the header line ("SPECIALS" / "SEASON n")
    function seasonLabel() {
        if (item.index === 0) return "Specials"
        if (item.index) return "Season " + item.index
        return ""
    }

    Keys.onUpPressed: {
        // Row 0 is the top of this screen; above it is the SERVER | PROFILE line
        // in the corner, when there is one. Otherwise the rows wrap as before.
        if (focusRow === 0 && moduleRoot.focusStatus()) return
        if (focusRow === 2) {
            if (episodeList.currentIndex > 0) {
                episodeList.currentIndex--
            } else {
                focusRow = cardWriter.available ? 4 : (hasExtras ? 1 : 0)
            }
        } else if (focusRow === 4) {
            focusRow = hasExtras ? 1 : 0
        } else if (focusRow === 1) {
            focusRow = 0
        } else {
            if (episodes.length > 0) {
                episodeList.currentIndex = episodes.length - 1
                focusRow = 2
            } else if (cardWriter.available) {
                focusRow = 4
            } else if (hasExtras) {
                focusRow = 1
            }
        }
        episodeList.positionViewAtIndex(episodeList.currentIndex, ListView.Contain)
    }
    Keys.onDownPressed: {
        if (focusRow === 0) {
            if (hasExtras) focusRow = 1
            else if (cardWriter.available) focusRow = 4
            else if (episodes.length > 0) {
                episodeList.currentIndex = 0
                focusRow = 2
            }
        } else if (focusRow === 1) {
            if (cardWriter.available) focusRow = 4
            else if (episodes.length > 0) {
                episodeList.currentIndex = 0
                focusRow = 2
            } else {
                focusRow = 0
            }
        } else if (focusRow === 4) {
            if (episodes.length > 0) {
                episodeList.currentIndex = 0
                focusRow = 2
            } else {
                focusRow = 0
            }
        } else {
            if (episodeList.currentIndex < episodes.length - 1) {
                episodeList.currentIndex++
            } else {
                episodeList.currentIndex = 0
                focusRow = 0
            }
        }
        episodeList.positionViewAtIndex(episodeList.currentIndex, ListView.Contain)
    }
    Keys.onReturnPressed: {
        if (focusRow === 0) {
            playBestEpisode()
        } else if (focusRow === 4) {
            cardWriter.open()
        } else if (focusRow === 1) {
            var label = seasonLabel()
            seasonRoot.navigateTo("Extras.qml", {
                extras: extras,
                ratingKey: item.ratingKey,
                itemTitle: showTitle + (label ? " - " + label : ""),
                libraryName: libraryName
            }, { focusRow: 1 })
        } else {
            var ep = episodes[episodeList.currentIndex]
            if (!ep) return
            seasonRoot.navigateTo("Item.qml", {
                item: ep,
                libraryName: libraryName
            }, { currentIndex: episodeList.currentIndex, focusRow: 2 })
        }
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
            goBack()
            event.accepted = true
        }
    }

    function playBestEpisode() {
        if (episodes.length === 0) return
        var target = null
        // 1. In-progress episode (viewOffset > 0)
        for (var i = 0; i < episodes.length; i++) {
            if (episodes[i].viewOffset > 0) { target = episodes[i]; break }
        }
        // 2. First unwatched episode (viewCount === 0)
        if (!target) {
            for (var j = 0; j < episodes.length; j++) {
                if (!episodes[j].viewCount || episodes[j].viewCount === 0) { target = episodes[j]; break }
            }
        }
        // 3. All watched — start from beginning
        if (!target) {
            target = episodes[0]
        }
        var ep = Object.assign({}, target)
        // For cases 2 and 3 ensure we start from beginning
        if (!ep.viewOffset) ep.viewOffset = 0
        seasonRoot.navigateTo("Item.qml", {
            item: ep,
            libraryName: libraryName
        }, {})
    }

    // ---
    // UI
    // ---

    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: libraryName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    Text {
        visible: isLoading
        text: "LOADING..."
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        font.pixelSize: root.sh * 0.05 //24
    }

    Item {
        visible: !isLoading
        anchors.top: parent.top
        anchors.left: parent.left
        // A poster stacked over the buttons needs more column than the text
        // layout ever did, and there is dead space to take it from: the AppBar
        // ends at y84 and the hint row does not start until y414.
        anchors.topMargin: seasonRoot.showPoster ? root.sh * 0.2166667 //104
                                         : root.sh * 0.25      //120
        anchors.leftMargin: root.sw * 0.115625 //74
        id: body
        width: root.sw * 0.76875 //492
        height: seasonRoot.showPoster ? root.sh * 0.6104167 //293
                              : root.sh * 0.525     //252
        clip: true

        Row {
            id: seasonDetails
            height: seasonRoot.showPoster ? root.sh * 0.4833333 //232
                                          : root.sh * 0.175     //84
            spacing: root.sw * 0.0375 //24

            Column {
                id: actionColumn
                width: root.sw * 0.1875 //120

                // Scrolled so the focused button is always in view. Nothing moves
                // while the stack fits — which is what the sizes above are for —
                // and past that the poster is what slides away first, the buttons
                // below it being the reason to be here at all.
                y: -Math.max(0, seasonRoot.focusedActionBottom - body.height)
                Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

                // Poster, above the action buttons. The wrapper carries the 8px
                // gap and collapses to nothing when hidden — a Column skips
                // invisible children, so the button stack is unmoved with the
                // feature off.
                Item {
                    visible: seasonRoot.showPoster
                    width: parent.width
                    height: posterImage.height + root.sh * 0.0125 //6 gap

                    Image {
                        id: posterImage
                        source: seasonRoot.posterUrl
                        asynchronous: true
                        cache: true
                        // Fitted, not cropped, and sized from what came back —
                        // a 2:3 poster stands tall, a 16:9 episode still is wide.
                        // Clamped to the button column's width, so a wide still
                        // can never spill into the summary beside it, and to
                        // maxPosterH, so a tall one can't push the buttons under
                        // it off the bottom of the clip. Whichever binds first.
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: root.sw * 0.1875 //120
                        sourceSize.height: root.sh * 0.25  //120
                        width: Math.min(implicitWidth, parent.width,
                                        implicitHeight > 0
                                            ? seasonRoot.maxPosterH * implicitWidth / implicitHeight
                                            : parent.width)
                        height: implicitWidth > 0
                                ? width * implicitHeight / implicitWidth : 0
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }

                // PLAY / RESUME button
                Rectangle {
                    id: playButton
                    color: focusRow === 0 ? root.accentColor : root.surfaceColor
                    border.color: focusRow === 0 ? root.accentColor : root.tertiaryColor
                    width: root.sw * 0.1875 //120
                    height: root.sh * 0.0875 //42
                    border.width: root.sh * 0.003125 //2

                    Text {
                        anchors.centerIn: parent
                        text: {
                            // Show RESUME if any in-progress episode exists
                            for (var i = 0; i < seasonRoot.episodes.length; i++) {
                                if (seasonRoot.episodes[i].viewOffset > 0) return "RESUME \u25BA"
                            }
                            return "PLAY \u25BA"
                        }
                        color: focusRow === 0 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.05 //24
                    }
                }

                // Extras Button
                Rectangle {
                    id: extrasButton
                    visible: seasonRoot.hasExtras
                    color: focusRow === 1 ? root.accentColor : Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.1)
                    width: parent.width
                    height: extrasLabel.implicitHeight + root.sh * 0.025 //12
                    anchors.horizontalCenter: parent.horizontalCenter

                    Text {
                        id: extrasLabel
                        text: "VIEW EXTRAS"
                        color: focusRow === 1 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        anchors.centerIn: parent
                        font.pixelSize: root.sh * 0.025 //12
                    }
                }

                // Write NFC Card. Directly under Extras so it collapses upward
                // when there are no extras, leaving screen height unchanged.
                Rectangle {
                    id: writeCardButton
                    visible: cardWriter.available
                    color: focusRow === 4 ? root.accentColor : Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.1)
                    width: parent.width
                    height: writeCardLabel.implicitHeight + root.sh * 0.025 //12
                    anchors.horizontalCenter: parent.horizontalCenter

                    Text {
                        id: writeCardLabel
                        text: "WRITE NFC TAG"
                        color: focusRow === 4 ? root.surfaceColor : root.primaryColor
                        font.family: root.globalFont
                        anchors.centerIn: parent
                        font.pixelSize: root.sh * 0.025 //12
                    }
                }
            }

            Column {
                id: textColumn
                topPadding: root.sh * 0.0083333 //4
                width: root.sw * 0.54375 //348
                spacing: root.sh * 0.0166667 //8

                Text {
                    text: showTitle
                    color: root.primaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.05 //24
                }

                Text {
                    text: {
                        var parts = []
                        if (item.index === 0) parts.push("Specials")
                        else if (item.index) parts.push("SEASON " + item.index)
                        var yr = item.originallyAvailableAt
                                 ? item.originallyAvailableAt.substring(0, 4)
                                 : (item.year ? String(item.year) : "")
                        if (yr) parts.push(yr)
                        return parts.join(" - ")
                    }
                    color: root.secondaryColor
                    font.family: root.globalFont
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                    font.pixelSize: root.sh * 0.0333333 //16
                }
            }
        }

        ListView {
            id: episodeList
            model: episodes
            x: seasonRoot.sectionX
            y: (seasonRoot.showPoster ? textColumn.height : seasonDetails.height)
               + root.sh * 0.05625 //27
            width: seasonRoot.sectionW
            height: seasonRoot.rowArt ? root.sh * 0.375      //180 — 5 rows of 36
                                      : root.sh * 0.2916667  //140 — 5 rows of 28
            clip: true

            delegate: Item {
                width: episodeList.width
                height: seasonRoot.rowArt ? root.sh * 0.075      //36
                                          : root.sh * 0.0583333  //28

                Image {
                    id: rowThumb
                    visible: status === Image.Ready
                    source: seasonRoot.rowArtFor(modelData)
                    asynchronous: true
                    cache: true
                    // Fitted inside the reserved slot, so art of any aspect is
                    // shown whole and centred rather than cropped to the box.
                    fillMode: Image.PreserveAspectFit
                    width: seasonRoot.rowArtW
                    height: seasonRoot.rowArtH
                    sourceSize.width: seasonRoot.rowArtW
                    sourceSize.height: seasonRoot.rowArtH
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    id: textClip
                    x: seasonRoot.rowArt ? seasonRoot.rowArtW : 0
                    width: Math.min(rowText.implicitWidth, episodeList.width - x)
                    height: parent.height
                    clip: true

                    Rectangle {
                        color: root.accentColor
                        anchors.fill: rowText
                        visible: episodeList.currentIndex === index && focusRow === 2
                    }

                    Text {
                        id: rowText
                        text: {
                            var s = (modelData.parentIndex != null) ? ("S" + modelData.parentIndex) : ""
                            var e = modelData.index ? ("E" + modelData.index) : ""
                            var prefix = (s || e) ? (s + e + ": ") : ""
                            return prefix + (modelData.title || "")
                        }
                        color: (episodeList.currentIndex === index && focusRow === 2)
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
                        running: (episodeList.currentIndex === index) &&
                                 (focusRow === 2) &&
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
    NfcCardWriter {
        id: cardWriter
        anchors.fill: parent
        offerShuffle: true
        cardRef:   item.guid || ""
        // "Show (Year) - S1" rather than "Show - Season 1", so season cards for one
        // show stay distinct, sort next to that show's episode cards, and don't
        // collide with a same-named show from another year. parentYear is the
        // show's year — a season carries no year of its own.
        cardTitle: seasonRoot.showTitle
                   + (item.parentYear ? " (" + item.parentYear + ")" : "")
                   + (item.index !== undefined ? " - S" + item.index : "")
        onClosed: seasonRoot.forceActiveFocus()
    }

}
