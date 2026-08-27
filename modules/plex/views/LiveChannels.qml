import QtQuick
import Components

// Live TV channel list. Lists the tunable channels of the server's DVR; selecting
// one hands off to LivePlayer.qml, which tunes it and can switch channels in place.
//
// One list, three layouts, chosen by two app settings. Plain, it is the list of
// names it has always been. With TV Guide on, each name carries what is on it
// now, read from the DVR's own EPG. With Poster Grid on as well, the listings
// are what the screen is for and it is drawn as a guide page: the station's
// mark, the channel, what is on with how much of it is gone, and what follows.
FocusScope {
    id: channelsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    property string libraryName: navParams.libraryName || "LIVE TV"
    property var channels: []
    property bool loaded: false
    property string errorMessage: ""

    // The two app settings this screen reads, bound through root rather than
    // appCore — the teardown-safe form the rest of the views use.
    readonly property bool epg: root.liveEpg
    // Artwork puts the station's mark at the head of every row, and a mark needs
    // more height than a line of text does — so the lineup is drawn as a page of
    // channels rather than a list of names, whether or not there are listings to
    // put beside them. With the guide on as well, that page is a guide page: the
    // same rows, carrying what is on and what is next.
    readonly property bool artPage: root.posterGrid

    // The guide as the backend read it: channelId -> { now, next }, each an
    // airing of {title, showTitle, contentRating, beginsAt, endsAt}. A channel
    // the guide had nothing for is simply absent.
    property var guide: ({})
    // The wall clock this screen reads, in epoch seconds, ticked by guideClock.
    // A property rather than a Date.now() in each binding, so every bar and
    // every countdown on the screen measures from the same instant and they all
    // move together.
    property real nowSecs: Date.now() / 1000
    // When the guide stops describing what is on: the first end time in it.
    property real guideExpiry: 0

    // ---
    // The guide
    // ---

    function guideRowFor(channel) {
        var row = channelsRoot.guide[(channel && channel.channelId) || ""]
        return row || null
    }
    function programmeNow(channel)  { var r = guideRowFor(channel); return (r && r.now)  || null }
    function programmeNext(channel) { var r = guideRowFor(channel); return (r && r.next) || null }

    // A programme named the way the player's OSD names it: an episode by its
    // show first, because a title alone ("DEATH HAS A SHADOW") names nothing
    // the viewer is looking for.
    function programmeTitle(p) {
        if (!p || !p.title) return ""
        return p.showTitle ? (p.showTitle + ": " + p.title) : p.title
    }

    function pad(n) { return n < 10 ? "0" + n : "" + n }

    // A listing's clock time, in the app's own hours format. The wall clock
    // writes "9:00 PM"; a guide column has no room for the space, and the
    // reading is unambiguous without it.
    function clockOf(secs) {
        var n = Number(secs || 0)
        if (n <= 0) return ""
        var d = new Date(n * 1000)
        var h = d.getHours()
        if (!root.twelveHour) return pad(h) + ":" + pad(d.getMinutes())
        var suffix = h < 12 ? "AM" : "PM"
        h = h % 12
        if (h === 0) h = 12
        return h + ":" + pad(d.getMinutes()) + suffix
    }

    // How far through the programme the clock is, 0..1. Clamped at both ends:
    // the guide is re-read on a timer rather than at the instant a programme
    // ends, so a bar is briefly asked to measure past its own window.
    function progressOf(p) {
        if (!p) return 0
        var begins = Number(p.beginsAt || 0), ends = Number(p.endsAt || 0)
        if (begins <= 0 || ends <= begins) return 0
        return Math.max(0, Math.min(1, (channelsRoot.nowSecs - begins) / (ends - begins)))
    }

    // What is left of it, written as the OSD writes a programme's remainder —
    // a countdown, with the sign saying which of the two readings it is.
    function remainingOf(p) {
        if (!p) return ""
        var ends = Number(p.endsAt || 0)
        if (ends <= channelsRoot.nowSecs) return ""
        return "-" + Math.max(1, Math.round((ends - channelsRoot.nowSecs) / 60)) + " MIN"
    }

    // The window a listing runs across, which is what the bar beside it measures.
    function windowOf(p) {
        if (!p || !Number(p.beginsAt || 0)) return ""
        return clockOf(p.beginsAt) + "-" + clockOf(p.endsAt)
    }

    // The rating a listing carries, as a mark. A guide writes it with the body
    // that issued it — "us:TV-14", "nz/PG" — and a box this size has room for
    // the rating or for both, not for both. Where the viewer is watching is not
    // news to them, so what is left after the issuer is the mark.
    function ratingOf(p) {
        var r = "" + ((p && p.contentRating) || "")
        var cut = Math.max(r.lastIndexOf(":"), r.lastIndexOf("/"))
        return (cut >= 0 ? r.substring(cut + 1) : r).trim().toUpperCase()
    }

    function refreshGuide() {
        if (!channelsRoot.epg || channelsRoot.channels.length === 0) return
        // Held off for a minute so a slow guide is not asked twice; the answer
        // sets the real next look.
        channelsRoot.guideExpiry = Date.now() / 1000 + 60
        plexBackend.load_live_guide(channelsRoot.channels)
    }

    Connections {
        target: plexBackend

        function onLiveChannelsLoaded(items) {
            channelsRoot.channels = items
            channelsRoot.loaded = true
            if (items.length > 0) {
                var restore = (navListState.currentIndex !== undefined) ? navListState.currentIndex : 0
                channelList.currentIndex = Math.min(restore, items.length - 1)
                channelList.positionViewAtIndex(channelList.currentIndex, ListView.Contain)
                channelsRoot.refreshGuide()
            }
        }

        function onLiveGuideLoaded(guide) {
            channelsRoot.guide = guide || ({})
            channelsRoot.nowSecs = Date.now() / 1000

            // The guide is only as current as its first ending programme, so
            // that is when it is worth reading again — floored a couple of
            // minutes out, since across a long lineup something ends most
            // minutes and the whole grid is one request.
            var soonest = 0
            for (var id in channelsRoot.guide) {
                var p = channelsRoot.guide[id].now
                var ends = p ? Number(p.endsAt || 0) : 0
                if (ends > channelsRoot.nowSecs && (soonest === 0 || ends < soonest)) soonest = ends
            }
            // Nothing on air anywhere in the answer is asked again in ten
            // minutes rather than in two: a guide missing its listings now
            // rarely gains them in a hurry. LivePlayer holds off for the same
            // reason and by the same amount.
            channelsRoot.guideExpiry = Math.max(soonest > 0 ? soonest
                                                            : channelsRoot.nowSecs + 600,
                                                channelsRoot.nowSecs + 120)
        }

        function onErrorOccurred(msg) {
            console.log("[LiveChannels] Error: " + msg)
            channelsRoot.loaded = true
            channelsRoot.errorMessage = msg
        }
    }

    // Moves every bar on the screen, and reads the guide again when it has run
    // out. A quarter-minute tick: a bar across a half-hour programme moves a
    // pixel or so in that time, and nothing here is worth a repaint per second
    // on a Pi. Stopped dead when the guide is off — there is nothing drawn that
    // moves.
    Timer {
        id: guideClock
        interval: 15000
        repeat: true
        running: channelsRoot.epg
        onTriggered: {
            channelsRoot.nowSecs = Date.now() / 1000
            if (channelsRoot.nowSecs >= channelsRoot.guideExpiry) channelsRoot.refreshGuide()
        }
    }

    Component.onCompleted: plexBackend.load_live_channels()

    focus: true

    // ---
    // Measurements
    // ---

    // The list's slot. The guide page takes the taller, higher one the poster
    // views use — five listings rather than nine names — where both text
    // layouts keep the one the channel list has always had.
    readonly property real listW:   root.sw * 0.76875 //492
    readonly property real listTop: artPage ? root.sh * 0.2166667 //104
                                              : root.sh * 0.25 //120
    readonly property real listH:   artPage ? root.sh * 0.6104167 //293
                                              : root.sh * 0.525 //252

    // The guide page's columns, measured once here rather than in the delegate,
    // so a column heading and the column it names cannot drift apart.
    readonly property real rowH:    root.sh * 0.1083333 //52
    readonly property real rowPad:  root.sh * 0.00625 //3
    readonly property real colGap:  root.sw * 0.0125 //8
    readonly property real headerH: root.sh * 0.0416667 //20
    // The station's mark, in the square the poster shelf gives it, plus the
    // ring every PosterCell carries on both sides.
    readonly property real logoSide: root.sh * 0.0833333 //40
    readonly property real logoCol:  logoSide + root.sh * 0.0125 //+6
    readonly property real chanX:    logoCol + colGap
    readonly property real chanCol:  listW * 0.2
    // What the name may actually run to. With the guide on it is the column the
    // headings name; with the guide off there is nothing to its right, and a
    // name cut short in front of an empty row would be a cut for nothing.
    readonly property real nameCol:  epg ? chanCol : listW - chanX
    readonly property real nextCol:  listW * 0.26
    readonly property real nextX:    listW - nextCol
    readonly property real nowX:     chanX + chanCol + colGap
    readonly property real nowCol:   nextX - colGap - nowX

    // The widest channel number in the lineup, and the column it asks for. A
    // number is set at the head of its row and its name after it, so a lineup
    // running 1 to 12 starts "ONE" one character further left than "TEN" and the
    // names read as two lists rather than one. The column is measured off the
    // longest number there actually is, not off a guessed three digits: most
    // lineups number in single figures, and a column sized for the numbers a
    // lineup does not have is width taken off the names it does.
    readonly property string widestNumber: {
        var widest = ""
        for (var i = 0; i < channels.length; i++) {
            var n = "" + (channels[i].number || "")
            if (n.length > widest.length) widest = n
        }
        return widest
    }

    // Measured rather than counted in characters: the font is monospaced, but
    // nothing else in the app assumes that, and one hidden line of text costs
    // less than the assumption would if a theme ever changed the face.
    Text {
        id: numberRuler
        visible: false
        text: channelsRoot.widestNumber
        font.family: root.globalFont
        font.pixelSize: root.sh * 0.05 //24
    }
    readonly property real rowNumW: numberRuler.implicitWidth
    // One character between the number and the name, where the single-line row
    // used to write two spaces. The name pays for the alignment out of its own
    // column, so the gap is the smallest one that still reads as a gap.
    readonly property real rowNumGap: root.sw * 0.028125 //18

    // The widest mark the guide actually carries, on the same terms as
    // widestNumber: a lineup whose listings have no ratings gives the room back
    // to the programme names rather than holding a column open for nothing.
    readonly property string widestRating: {
        var widest = ""
        for (var id in guide) {
            var row = guide[id]
            var a = ratingOf(row.now), b = ratingOf(row.next)
            if (a.length > widest.length) widest = a
            if (b.length > widest.length) widest = b
        }
        return widest
    }

    // The text list's three columns, when the guide is on without the artwork.
    // The channel keeps the larger share: it is what the viewer is scanning for,
    // and it is the one they can act on.
    readonly property real rowChanW: listW * 0.42

    // The time column is measured off the widest reading the clock writes — a
    // 12-hour one carries its AM/PM — rather than taken as a share of the row.
    // A share is a fraction of the screen's *width* while the type is a fraction
    // of its *height*, so on a wide screen the column grows and the reading in
    // it does not: the gap that opens between the time and the programme name is
    // width the name should have had.
    Text {
        id: timeRuler
        visible: false
        text: root.twelveHour ? "12:00PM" : "00:00"
        font.family: root.globalFont
        font.pixelSize: channelsRoot.smallH
    }
    RatingMark {
        id: ratingRuler
        visible: false
        rating: channelsRoot.widestRating
    }
    readonly property real rowClockW:  timeRuler.implicitWidth
    // Held open for every row or for none, so the names all start in the same
    // place; a mark drawn where each row's own clock happens to end would set
    // the column zigzagging down the page.
    readonly property real ratingGap:  root.sw * 0.00625 //4
    readonly property real rowRatingW: channelsRoot.widestRating === ""
                                       ? 0 : ratingGap + ratingRuler.implicitWidth
    readonly property real rowTimeW:   rowClockW + rowRatingW

    // A column's text stops a gap short of its own edge, where the column beside
    // it starts. Without it the two runs of text meet in the middle of the gutter
    // and a row reads as one sentence running across four columns.
    readonly property real textGap: colGap

    // Line heights, shared by both guide layouts.
    readonly property real titleH: root.sh * 0.0375 //18
    readonly property real smallH: root.sh * 0.0270833 //13
    readonly property real barH:   root.sh * 0.0145833 //7
    // The thin form of the bar, for a row with one line's worth of height in it.
    readonly property real lineH:  root.sh * 0.0041667 //2

    // ---
    // Parts
    // ---

    // The bar beside a listing: the same reading the playback OSD's seek bar
    // gives, of the same thing, drawn the same way — an outlined box with an
    // inset fill. The OSD measures the programme with mpv's clock because a
    // paused viewer stops moving through it; a list has only the wall clock,
    // which is the right one here, since nobody is watching these channels yet.
    component ProgressBar: Rectangle {
        id: bar
        property real fraction: 0
        // A selected row is filled with the accent colour, so everything drawn
        // on one is drawn in the surface colour instead of the palette's own.
        property color ink: root.primaryColor

        color: "transparent"
        border.width: root.sh * 0.0020833 //1
        border.color: ink

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: bar.border.width * 2
            width: Math.max(0, (bar.width - bar.border.width * 4) * bar.fraction)
            color: bar.ink
        }
    }

    // The same reading where there is no room for the boxed bar: a rule the
    // width of what it is measuring, the run so far drawn over it. No border and
    // no inset — at two pixels those are the whole of it — so the track is the
    // same ink held back instead, which every theme's palette then answers for.
    component ProgressLine: Item {
        property real fraction: 0
        property color ink: root.primaryColor

        Rectangle {
            anchors.fill: parent
            color: parent.ink
            opacity: 0.35
        }
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(1, parent.fraction))
            color: parent.ink
        }
    }

    // A rating as the playback OSD draws one: boxed the way a certificate card
    // is, which is as official as this can honestly look — the real marks are
    // trademarked artwork, and neither ASS nor a QML rectangle draws those. The
    // border is a hairline, since at this size anything thicker is half the box.
    component RatingMark: Rectangle {
        id: mark
        property string rating: ""
        property color ink: root.primaryColor
        // Shorter than the line it sits beside: a rating is a footnote to the
        // time, and a box drawn to the same height as the reading competes with
        // it. Small enough still to be read across a room, since everything
        // here is measured off the screen's own height.
        property real lineH: channelsRoot.smallH * 0.85

        visible: rating !== ""
        color: "transparent"
        border.width: root.sh * 0.0020833 //1
        border.color: ink
        implicitWidth: markText.implicitWidth + lineH * 0.8
        implicitHeight: lineH
        width: implicitWidth
        height: implicitHeight

        Text {
            id: markText
            anchors.centerIn: parent
            text: mark.rating
            color: mark.ink
            font.family: root.globalFont
            font.pixelSize: mark.lineH * 0.7
        }
    }

    // Every small line on a guide row: the times, the channel number, the
    // column headings. One place so they are all one size.
    component GuideLabel: Text {
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: channelsRoot.smallH * 0.85
        height: channelsRoot.smallH
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }

    // ---
    // UI
    // ---

    // Header
    AppBar {
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: channelsRoot.libraryName
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125 //60
        anchors.leftMargin: root.sw * 0.125 //80
    }

    // Loading / empty / error indicator
    Text {
        visible: channels.length === 0
        text: channelsRoot.errorMessage !== "" ? channelsRoot.errorMessage
              : (channelsRoot.loaded ? "NO CHANNELS" : "LOADING...")
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.centerIn: parent
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        width: root.sw * 0.6
        font.pixelSize: root.sh * 0.05 //24
    }

    // The guide page's column headings, on the list's own measurements. What
    // makes a table of rows that would otherwise be four unexplained columns.
    Item {
        id: guideHeader
        visible: channelsRoot.artPage && channelsRoot.channels.length > 0
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: channelsRoot.listTop
        anchors.leftMargin: root.sw * 0.115625 //74
        width: channelsRoot.listW
        height: channelsRoot.headerH

        GuideLabel {
            x: channelsRoot.chanX
            width: channelsRoot.nameCol
            text: "CHANNEL"
            color: root.tertiaryColor
        }
        GuideLabel {
            visible: channelsRoot.epg
            x: channelsRoot.nowX
            width: channelsRoot.nowCol
            text: "ON NOW"
            color: root.tertiaryColor
        }
        GuideLabel {
            visible: channelsRoot.epg
            x: channelsRoot.nextX
            width: channelsRoot.nextCol
            text: "NEXT"
            color: root.tertiaryColor
        }

        // A rule under the headings, the width of the table: the headings are
        // read as belonging to the rows below rather than to the screen.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: root.sh * 0.0020833 //1
            color: root.tertiaryColor
        }
    }

    // Body
    ListView {
        id: channelList
        model: channels
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: channelsRoot.listTop
                           + (channelsRoot.artPage ? channelsRoot.headerH + channelsRoot.rowPad : 0)
        anchors.leftMargin: root.sw * 0.115625 //74
        width: channelsRoot.listW
        // Whole rows only, on the guide page: a row is four columns and three
        // lines deep, and the last one cut through the middle reads as a fault
        // rather than as a list that carries on. A line of text clipped by the
        // same edge does not, which is why the text layouts keep their slot.
        height: channelsRoot.artPage
                ? Math.floor((channelsRoot.listH - channelsRoot.headerH - channelsRoot.rowPad)
                             / channelsRoot.rowH) * channelsRoot.rowH
                : channelsRoot.listH
        clip: true
        focus: true

        delegate: channelsRoot.artPage ? channelArtRow
                : channelsRoot.epg        ? guideTextRow
                                          : channelTextRow

        Keys.onUpPressed: {
            if (count === 0) return
            // Off the top of the list is the SERVER | PROFILE line in the corner,
            // when this screen has one; otherwise the list wraps as it always has.
            if (currentIndex === 0 && moduleRoot.focusStatus()) return
            if (currentIndex > 0) currentIndex--
            else currentIndex = count - 1
            channelList.positionViewAtIndex(channelList.currentIndex, ListView.Contain)
        }
        Keys.onDownPressed: {
            if (count === 0) return
            if (currentIndex < count - 1) currentIndex++
            else currentIndex = 0
            channelList.positionViewAtIndex(channelList.currentIndex, ListView.Contain)
        }

        Keys.onReturnPressed: {
            if (channels.length === 0) return
            channelsRoot.navigateTo("LivePlayer.qml", {
                channel: channels[currentIndex]
            }, { currentIndex: channelList.currentIndex })
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace || event.key === Qt.Key_Back) {
                channelsRoot.goBack()
                event.accepted = true
            }
        }
    }

    // The list of names: the highlight hugs the line rather than banding the
    // whole row, and the selected line scrolls itself when it is too long for
    // the list — both as this screen has always drawn them. The number sits in
    // the column the guide row gives it, so the names line up down the page
    // whichever of the two layouts is on.
    Component {
        id: channelTextRow

        Item {
            id: plainRow
            width: channelList.width
            height: root.sh * 0.0583333 //28

            readonly property bool sel: channelList.currentIndex === index
            readonly property color ink: sel ? root.surfaceColor : root.primaryColor
            readonly property real padX: root.sw * 0.009375 //6
            readonly property real padTop: root.sh * 0.0041667 //2
            readonly property real padBottom: root.sh * 0.00625 //3
            readonly property real nameX: padX + channelsRoot.rowNumW + channelsRoot.rowNumGap

            Item {
                id: textClip
                width: Math.min(line.width, channelList.width)
                height: parent.height
                clip: true

                // The number and the name move as one line — the highlight wraps
                // it whole and the scroll carries it whole, which is what this
                // list has always done. Only the number's column is new: without
                // it a lineup running 1 to 12 starts "ONE" a character further
                // left than "TEN".
                Item {
                    id: line
                    x: 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: plainRow.nameX + nameText.implicitWidth + plainRow.padX
                    height: nameText.implicitHeight + plainRow.padTop + plainRow.padBottom

                    Rectangle {
                        anchors.fill: parent
                        color: root.accentColor
                        visible: plainRow.sel
                    }

                    Text {
                        id: numberText
                        x: plainRow.padX
                        y: plainRow.padTop
                        text: modelData.number || ""
                        color: plainRow.ink
                        font.family: root.globalFont
                        font.pixelSize: root.sh * 0.05 //24
                    }

                    Text {
                        id: nameText
                        x: plainRow.nameX
                        y: plainRow.padTop
                        text: modelData.title || ""
                        color: plainRow.ink
                        font.family: root.globalFont
                        font.capitalization: Font.AllUppercase
                        font.pixelSize: root.sh * 0.05 //24
                    }
                }

                SequentialAnimation {
                    running: plainRow.sel && (line.width > textClip.width)
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) line.x = 0
                    PauseAnimation { duration: 1500 }
                    NumberAnimation {
                        target: line; property: "x"
                        to: textClip.width - line.width
                        duration: Math.abs(to) * 20
                    }
                    PauseAnimation { duration: 2000 }
                    PropertyAction { target: line; property: "x"; value: 0 }
                }
            }
        }
    }

    // The same list of names with the guide on it: the name, when what is on it
    // started, and what that is. The highlight takes the whole line here rather
    // than hugging the name — the row is now three things read across, and a
    // block around only the first of them would read as the row stopping there.
    Component {
        id: guideTextRow

        Item {
            id: textRow
            width: channelList.width
            height: root.sh * 0.0583333 //28

            readonly property bool sel: channelList.currentIndex === index
            readonly property var prog: channelsRoot.programmeNow(modelData)
            readonly property color ink: sel ? root.surfaceColor : root.primaryColor
            readonly property color dim: sel ? root.surfaceColor : root.secondaryColor
            readonly property real pad: root.sw * 0.009375 //6
            readonly property real nameX:  pad + channelsRoot.rowNumW + channelsRoot.rowNumGap
            readonly property real timeX:  channelsRoot.rowChanW + channelsRoot.colGap
            readonly property real titleX: timeX + channelsRoot.rowTimeW + channelsRoot.colGap

            Rectangle {
                anchors.fill: parent
                color: root.accentColor
                visible: textRow.sel
            }

            // The number in its own column, so every name below starts where
            // this one does whatever the numbers are.
            Text {
                x: textRow.pad
                anchors.verticalCenter: parent.verticalCenter
                width: channelsRoot.rowNumW
                text: modelData.number || ""
                color: textRow.ink
                font.family: root.globalFont
                font.pixelSize: root.sh * 0.05 //24
                verticalAlignment: Text.AlignVCenter
            }

            MarqueeText {
                x: textRow.nameX
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                maxWidth: channelsRoot.rowChanW - textRow.nameX - channelsRoot.textGap
                active: textRow.sel
                text: modelData.title || ""
                color: textRow.ink
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.05 //24
            }

            // When it started, ahead of the name the way a printed listing is
            // read: the time first, then what began at it. The two sit together
            // as one block, held off the row's centre by the rule's own height
            // so the pair is centred rather than the time alone.
            GuideLabel {
                id: rowTime
                x: textRow.timeX
                width: channelsRoot.rowTimeW
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -channelsRoot.lineH / 2
                // A shade larger than the guide page's captions: on that screen
                // a time is one of three lines in a block, here it is one of the
                // three things the row says.
                font.pixelSize: channelsRoot.smallH
                text: textRow.prog ? channelsRoot.clockOf(textRow.prog.beginsAt) : ""
                color: textRow.dim
            }

            // What it is rated, after the time it started at. The mark is the
            // OSD's, at the size the row can spare, and it sits in the column
            // held open for it rather than at the end of this row's own clock.
            RatingMark {
                x: textRow.timeX + channelsRoot.rowClockW + channelsRoot.ratingGap
                // On the row's own centre line, with the programme it belongs
                // to — not with the time, which is held above centre to leave
                // room for the rule under it.
                anchors.verticalCenter: parent.verticalCenter
                rating: channelsRoot.ratingOf(textRow.prog)
                ink: textRow.dim
            }

            // How much of it has gone, under the time it started at: the reading
            // belongs to the clock beside it, and a row one line deep has no
            // other place to put it. Thin where the guide page's is boxed — this
            // one lies under a line of text rather than beside one.
            ProgressLine {
                visible: textRow.prog !== null
                x: textRow.timeX
                anchors.top: rowTime.bottom
                // As wide as the reading it sits under, never as wide as the
                // column: a rule running on past the last digit reads as a rule
                // under the row, and it is under the time.
                width: rowTime.contentWidth
                height: channelsRoot.lineH
                ink: textRow.ink
                fraction: channelsRoot.progressOf(textRow.prog)
            }

            // Smaller than the channel it is against: the name is what the
            // viewer is scanning for, and the listing is what it is showing.
            MarqueeText {
                id: rowProgramme
                x: textRow.titleX
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                maxWidth: channelsRoot.listW - textRow.titleX - textRow.pad
                active: textRow.sel
                text: textRow.prog ? channelsRoot.programmeTitle(textRow.prog) : "NO LISTING"
                color: textRow.prog ? textRow.dim : root.tertiaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: root.sh * 0.0416667 //20
            }
        }
    }

    // A page of channels: one per row, read across — the station's mark, then
    // its number and name. With the guide on the row carries two more columns,
    // what is on with the bar measuring it and the window it runs across, and
    // what follows; without it the name has the rest of the row to run in. The
    // mark is why the list gives up the extra height either way, and the columns
    // are why the headings above the list exist.
    Component {
        id: channelArtRow

        Item {
            id: guideRow
            width: channelList.width
            height: channelsRoot.rowH

            readonly property bool sel: channelList.currentIndex === index
            readonly property var prog: channelsRoot.programmeNow(modelData)
            readonly property var upNext: channelsRoot.programmeNext(modelData)
            // Everything on a selected row is drawn on the accent fill, so it
            // is drawn in the surface colour; on any other row, in the
            // palette's own, with the second rank of each column a shade back.
            readonly property color ink: sel ? root.surfaceColor : root.primaryColor
            readonly property color dim: sel ? root.surfaceColor : root.secondaryColor

            Rectangle {
                anchors.fill: parent
                anchors.bottomMargin: channelsRoot.rowPad
                color: root.accentColor
                visible: guideRow.sel
            }

            // The station's mark, from the shelf that already draws these:
            // fitted whole over a veil of the surface colour, so a black mark
            // under a black theme still reads, and a station the guide has no
            // logo for falls back to the titled card rather than to a hole in
            // the column.
            PosterCell {
                id: logoCell
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -channelsRoot.rowPad / 2
                logoArt: true
                art: plexBackend.live_channel_logo_url(modelData)
                title: modelData.title || ""
                posterW: channelsRoot.logoSide
                posterH: channelsRoot.logoSide
            }

            // The channel, over two lines rather than the one the text list
            // writes: a number set above its name costs the column no width,
            // and the numbers then line up down the page the way they do in a
            // printed guide.
            GuideLabel {
                id: chanNumber
                x: channelsRoot.chanX
                y: channelsRoot.rowPad
                width: channelsRoot.nameCol
                text: modelData.number || ""
                color: guideRow.dim
            }

            MarqueeText {
                id: chanName
                x: channelsRoot.chanX
                anchors.top: chanNumber.bottom
                height: channelsRoot.titleH
                maxWidth: channelsRoot.nameCol - channelsRoot.textGap
                active: guideRow.sel
                text: modelData.title || ""
                color: guideRow.ink
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: channelsRoot.titleH * 0.85
            }

            // What is on — this column and the one after it are the guide's,
            // and stand down with it.
            MarqueeText {
                id: nowTitle
                visible: channelsRoot.epg
                x: channelsRoot.nowX
                y: channelsRoot.rowPad
                height: channelsRoot.titleH
                maxWidth: channelsRoot.nowCol - channelsRoot.textGap
                active: guideRow.sel
                text: guideRow.prog ? channelsRoot.programmeTitle(guideRow.prog) : "NO LISTING"
                color: guideRow.prog ? guideRow.ink : root.tertiaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: channelsRoot.titleH * 0.85
            }

            ProgressBar {
                id: nowBar
                visible: channelsRoot.epg && guideRow.prog !== null
                x: channelsRoot.nowX
                anchors.top: nowTitle.bottom
                anchors.topMargin: channelsRoot.rowPad
                width: channelsRoot.nowCol
                height: channelsRoot.barH
                ink: guideRow.ink
                fraction: channelsRoot.progressOf(guideRow.prog)
            }

            // The two readings of that bar, at its two ends, the way the OSD
            // sets them at the two ends of its own: where the programme runs
            // from and to, and what is left of it.
            GuideLabel {
                id: nowWindow
                visible: nowBar.visible
                x: channelsRoot.nowX
                anchors.top: nowBar.bottom
                anchors.topMargin: channelsRoot.rowPad
                width: channelsRoot.nowCol / 2
                text: channelsRoot.windowOf(guideRow.prog)
                color: guideRow.dim
            }

            // What it is rated, at the end of the window it runs across — the
            // one line on this row that is already about the programme rather
            // than about the channel or the clock.
            RatingMark {
                visible: nowWindow.visible && rating !== ""
                x: channelsRoot.nowX + nowWindow.contentWidth + channelsRoot.ratingGap
                anchors.verticalCenter: nowWindow.verticalCenter
                rating: channelsRoot.ratingOf(guideRow.prog)
                ink: guideRow.dim
            }
            GuideLabel {
                visible: nowBar.visible
                x: channelsRoot.nowX + channelsRoot.nowCol / 2
                anchors.top: nowBar.bottom
                anchors.topMargin: channelsRoot.rowPad
                width: channelsRoot.nowCol / 2
                horizontalAlignment: Text.AlignRight
                text: channelsRoot.remainingOf(guideRow.prog)
                color: guideRow.dim
            }

            // What follows it. Named on the line the programme beside it is
            // named on, with its start time under, so the two columns read as
            // one sentence across: this until then, that after it.
            MarqueeText {
                id: nextTitle
                visible: channelsRoot.epg
                x: channelsRoot.nextX
                y: channelsRoot.rowPad
                height: channelsRoot.titleH
                maxWidth: channelsRoot.nextCol - channelsRoot.textGap
                active: guideRow.sel
                text: guideRow.upNext ? channelsRoot.programmeTitle(guideRow.upNext) : ""
                color: guideRow.dim
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: channelsRoot.titleH * 0.85
            }

            GuideLabel {
                id: nextTime
                visible: channelsRoot.epg && guideRow.upNext !== null
                x: channelsRoot.nextX
                anchors.top: nextTitle.bottom
                width: channelsRoot.nextCol
                text: channelsRoot.clockOf(guideRow.upNext && guideRow.upNext.beginsAt)
                color: guideRow.dim
            }

            RatingMark {
                visible: nextTime.visible && rating !== ""
                x: channelsRoot.nextX + nextTime.contentWidth + channelsRoot.ratingGap
                anchors.verticalCenter: nextTime.verticalCenter
                rating: channelsRoot.ratingOf(guideRow.upNext)
                ink: guideRow.dim
            }
        }
    }

    // Footer
    Text {
        id: footer
        text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE " + root.hints.select + ":WATCH"
        color: root.tertiaryColor
        font.family: root.globalFont
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.bottomMargin: root.sh * 0.1041667 //50
        anchors.leftMargin: root.sw * 0.125 //80
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
