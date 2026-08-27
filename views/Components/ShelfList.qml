import QtQuick

// A vertical stack of PosterShelf rows — the sectioned browse view. Up and Down
// change shelf, Left and Right move along the focused one, so the whole thing is
// one 2D surface even though each shelf scrolls independently.
//
// Selection is two numbers, not one: the host reads shelfIndex/itemIndex for its
// saved list state and receives the chosen item with the activated signal.
FocusScope {
    id: shelfListRoot

    // [{ title: string, items: array }] — a shelf per entry, in order.
    property var model: []

    property var posterSource: function(item, w, h) { return "" }
    property var titleText: function(item) { return (item && item.title) || "" }
    // Forwarded to every shelf: per-item cell shape, so nothing is cropped.
    property var posterAspectFor: null
    // Forwarded to every shelf: corner artwork for landscape cells, its shape,
    // and the two lines of caption over the artwork.
    property var badgeSource: null
    property real badgeAspect: 2 / 3
    property var captionSource: null
    // See PosterShelf.progressSource — how much of each item has been watched.
    property var progressSource: null

    // One shelf's slot: heading, gap, art, and the ring the cells add above and
    // below. The art height is shared by every shelf in the app whichever shape
    // is on it. At 75 two shelves fit whole and the next one's heading clears
    // the bottom with a sliver of art showing — the stack saying it scrolls.
    readonly property real headingH: root.sh * 0.0458333 //22 — PosterShelf's heading
    readonly property real headingGapH: root.sh * 0.0083333 //4
    readonly property real gutterH: root.sh * 0.0125 //6 — PosterShelf's frameW * 2
    property real posterH: root.sh * 0.15625 //75
    property real shelfH: headingH + headingGapH + posterH + gutterH //107
    // Breathing room between shelves, on top of each shelf's own poster gutter.
    property real shelfGap: root.sh * 0.0166667 //8

    // Off when the stack is one section of a larger column: moving past either
    // end reports out instead of looping, so the whole screen wraps once rather
    // than each part wrapping inside itself.
    property bool wrapVertically: true

    readonly property alias count: shelves.count
    readonly property int shelfIndex: shelves.currentIndex
    readonly property int itemIndex: column
    readonly property var currentItemData:
        shelves.currentItem ? shelves.currentItem.currentItemData : null

    // The column the user last stepped to, carried between shelves so Up and
    // Down land on the same position. Kept separate from any shelf's index — the
    // way a text cursor keeps its wanted column — so passing through a short
    // shelf does not shrink the column for every shelf after it. It also stands
    // in for per-shelf memory: a shelf scrolled out of view is destroyed with its
    // currentIndex, and reads the column back when recreated.
    property int column: 0

    function seatCurrent() {
        var sh = shelves.currentItem
        if (sh) sh.moveTo(Math.min(column, Math.max(0, sh.count - 1)))
    }

    signal activated(var item)
    signal backRequested()
    // Only with wrapVertically false.
    signal exitUp()
    signal exitDown()

    // Seats the selection before the delegates exist, which is the case when a
    // host restores saved state the moment its data arrives: each shelf reads
    // the column as it is created, so nothing depends on currentItem being live.
    function setPosition(shelfIdx, col) {
        var n = shelfListRoot.model ? shelfListRoot.model.length : 0
        if (n === 0 || shelfIdx === undefined || shelfIdx < 0) return
        column = col || 0
        shelves.currentIndex = Math.min(shelfIdx, n - 1)
        Qt.callLater(function() {
            shelves.positionViewAtIndex(shelves.currentIndex, ListView.Contain)
            seatCurrent()
            if (shelves.currentItem) shelves.currentItem.forceActiveFocus()
        })
    }

    function moveShelf(delta) {
        if (shelves.count === 0) return
        var next = shelves.currentIndex + delta
        if (next < 0) {
            if (!wrapVertically) { shelfListRoot.exitUp(); return }
            next = shelves.count - 1
        } else if (next >= shelves.count) {
            if (!wrapVertically) { shelfListRoot.exitDown(); return }
            next = 0
        }
        shelves.currentIndex = next
        shelves.positionViewAtIndex(next, ListView.Contain)
        seatCurrent()
        if (shelves.currentItem) shelves.currentItem.forceActiveFocus()
    }

    // Entry point for a host handing focus back in: atLast picks the bottom
    // shelf, which is the one a column arrives at when moving upward.
    function focusEnd(atLast) {
        if (shelves.count === 0) return
        shelves.currentIndex = atLast ? shelves.count - 1 : 0
        shelves.positionViewAtIndex(shelves.currentIndex, ListView.Contain)
        seatCurrent()
        if (shelves.currentItem) shelves.currentItem.forceActiveFocus()
        else forceActiveFocus()
    }

    ListView {
        id: shelves
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: sharedTitle.top
        anchors.bottomMargin: shelfListRoot.shelfGap
        model: shelfListRoot.model
        spacing: shelfListRoot.shelfGap
        clip: true
        focus: true
        // A shelf costs a row of poster requests, so only the ones on screen
        // (plus the one being scrolled to) are ever built.
        cacheBuffer: shelfListRoot.shelfH

        delegate: PosterShelf {
            width: shelves.width
            height: shelfListRoot.shelfH
            sectionTitle: modelData.title || ""
            model: modelData.items || []
            showTitleLine: false
            posterSource: shelfListRoot.posterSource
            titleText: shelfListRoot.titleText
            posterAspectFor: shelfListRoot.posterAspectFor
            badgeSource: shelfListRoot.badgeSource
            badgeAspect: shelfListRoot.badgeAspect
            captionSource: shelfListRoot.captionSource
            progressSource: shelfListRoot.progressSource

            Component.onCompleted: {
                currentIndex = Math.min(shelfListRoot.column, Math.max(0, count - 1))
                if (ListView.isCurrentItem) forceActiveFocus()
            }
            onMoved: shelfListRoot.column = currentIndex
            ListView.onIsCurrentItemChanged: if (ListView.isCurrentItem) forceActiveFocus()

            onActivated: shelfListRoot.activated(currentItemData)
            onBackRequested: shelfListRoot.backRequested()
            onMoveUp: shelfListRoot.moveShelf(-1)
            onMoveDown: shelfListRoot.moveShelf(1)
        }
    }

    // The selection's title, shared by every shelf — repeating it under each one
    // costs a line of height the 480p box does not have.
    MarqueeText {
        id: sharedTitle
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        height: root.sh * 0.0375 //18
        maxWidth: shelfListRoot.width
        text: shelfListRoot.titleText(shelfListRoot.currentItemData)
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: root.sh * 0.0375 //18
    }
}
