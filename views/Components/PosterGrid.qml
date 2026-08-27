import QtQuick

// Cover-art browser: a GridView of poster cells with one title line beneath for
// the selected item. The app's only 2D-navigable view, so the wrap rules are
// spelled out rather than left to GridView's defaults.
//
// The host supplies artwork through posterSource(item, w, h) — this component
// never knows which backend the items came from.
FocusScope {
    id: posterGridRoot

    property alias model: grid.model
    property alias currentIndex: grid.currentIndex
    property alias count: grid.count

    // posterSource returns "" for an item with no art, which draws the titled
    // placeholder instead of a broken-image box.
    property var posterSource: function(item, w, h) { return "" }
    property var titleText: function(item) { return (item && item.title) || "" }

    // When true, Right on the last column hands off instead of wrapping — the
    // A-Z letter panel, same affordance the text list gives.
    property bool browseEnabled: false

    signal activated()
    signal browseRequested()
    signal backRequested()
    // Left alone the grid wraps to the last row like every list in the app; a
    // host with somewhere above the grid to go sets this and takes the step.
    property bool exitUpEnabled: false
    signal exitUp()

    // Rows are the fixed quantity; everything else falls out of them. Column
    // count is whatever fits, which is how the grid narrows itself when the A-Z
    // panel is up without any special-casing.
    property int rows: 3
    property real posterAspect: 2 / 3
    // Shrinks the poster below the height the rows allow, which lets one more
    // column fit. For grids whose art is small enough to read at a size the
    // row height alone would overshoot — channel avatars, not cover art.
    property real posterScale: 1

    // Every cell carries a ring of this thickness; only the selected one is
    // coloured. The gutter is two of them, so rings between neighbours meet
    // exactly — the frame lives in the gap it already had, never over the art.
    readonly property real frameW: root.sh * 0.00625 //3
    readonly property real gutter: frameW * 2 //6

    // The cell is one poster plus one gutter in both axes — never
    // "width / columns", which pours the leftover into the column gap and makes
    // the grid look wider-spaced across than down.
    //
    // Two column counts are possible: the most that fit at full poster height
    // (leftover strip on the right), or one more, shrinking posters to fill the
    // width exactly (leftover band under the last row). Whichever wastes less
    // wins, so neither axis is visibly padded and the gutter stays put.
    readonly property real maxPosterH: ((grid.height - rows * gutter) / rows) * posterScale
    readonly property real maxPosterW: maxPosterH * posterAspect

    readonly property int wideCols: Math.max(1, Math.floor(width / (maxPosterW + gutter)))
    readonly property real wideWaste: width - wideCols * (maxPosterW + gutter)

    readonly property int tightCols: wideCols + 1
    readonly property real tightPosterW: width / tightCols - gutter
    readonly property real tightPosterH: tightPosterW / posterAspect
    readonly property real tightWaste: grid.height - rows * (tightPosterH + gutter)

    readonly property bool packTight: tightWaste >= 0 && tightWaste < wideWaste
    readonly property int columns: packTight ? tightCols : wideCols
    readonly property real posterW: packTight ? tightPosterW : maxPosterW
    readonly property real posterH: packTight ? tightPosterH : maxPosterH
    readonly property real cellH: posterH + gutter

    // atBeginning puts the row at the top rather than scrolling the minimum
    // distance — what a letter jump wants.
    function positionAtCurrent(atBeginning) {
        grid.positionViewAtIndex(grid.currentIndex,
                                 atBeginning === true ? GridView.Beginning
                                                      : GridView.Contain)
    }

    // Every move ends here: changing currentIndex alone does not scroll a
    // clipped view, exactly as with the ListViews elsewhere.
    function moveTo(i) {
        grid.currentIndex = i
        positionAtCurrent()
    }

    GridView {
        id: grid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: posterGridRoot.height - titleClip.height - posterGridRoot.gutter
        cellWidth: posterGridRoot.posterW + posterGridRoot.gutter
        cellHeight: posterGridRoot.cellH
        clip: true
        focus: true

        Keys.onLeftPressed: {
            if (count === 0) return
            var col = currentIndex % posterGridRoot.columns
            if (col > 0) { posterGridRoot.moveTo(currentIndex - 1); return }
            // Wrap to the last populated cell of the same row.
            var rowStart = currentIndex - col
            posterGridRoot.moveTo(Math.min(rowStart + posterGridRoot.columns - 1, count - 1))
        }
        Keys.onRightPressed: {
            if (count === 0) return
            var col = currentIndex % posterGridRoot.columns
            var rowStart = currentIndex - col
            var rowEnd = Math.min(rowStart + posterGridRoot.columns - 1, count - 1)
            if (currentIndex < rowEnd) { posterGridRoot.moveTo(currentIndex + 1); return }
            if (posterGridRoot.browseEnabled) { posterGridRoot.browseRequested(); return }
            posterGridRoot.moveTo(rowStart)
        }
        Keys.onUpPressed: {
            if (count === 0) return
            var next = currentIndex - posterGridRoot.columns
            if (next >= 0) { posterGridRoot.moveTo(next); return }
            if (posterGridRoot.exitUpEnabled) { posterGridRoot.exitUp(); return }
            // Wrap to the same column in the last row, clamped to the last item.
            var col = currentIndex % posterGridRoot.columns
            var lastRowStart = Math.floor((count - 1) / posterGridRoot.columns) * posterGridRoot.columns
            posterGridRoot.moveTo(Math.min(lastRowStart + col, count - 1))
        }
        Keys.onDownPressed: {
            if (count === 0) return
            var next = currentIndex + posterGridRoot.columns
            if (next < count) { posterGridRoot.moveTo(next); return }
            // Past the last row — including from a partial one — wrap to the
            // same column at the top.
            posterGridRoot.moveTo(currentIndex % posterGridRoot.columns)
        }
        Keys.onReturnPressed: posterGridRoot.activated()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
                || event.key === Qt.Key_Back) {
                posterGridRoot.backRequested()
                event.accepted = true
            }
        }

        delegate: PosterCell {
            posterW: posterGridRoot.posterW
            posterH: posterGridRoot.posterH
            frameW: posterGridRoot.frameW
            selected: grid.currentIndex === index
            art: posterGridRoot.posterSource(modelData, posterGridRoot.posterW,
                                             posterGridRoot.posterH)
            title: posterGridRoot.titleText(modelData)
        }
    }

    // Per-cell captions do not fit at 480p, so one shared line carries the
    // selected item's name, with the standard marquee for over-wide titles.
    MarqueeText {
        id: titleClip
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        height: root.sh * 0.0375 //18
        maxWidth: posterGridRoot.width
        text: {
            var m = grid.model
            if (!m || grid.currentIndex < 0 || grid.currentIndex >= grid.count) return ""
            return posterGridRoot.titleText(m[grid.currentIndex])
        }
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: root.sh * 0.0375 //18
    }
}
