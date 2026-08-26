import QtQuick

// One horizontal row of cover art under a section heading — the "shelf" the
// sectioned views are built from, and usable alone for a single row such as
// Continue Watching.
//
// Everything sizes off the shelf's own height. Up and Down are not handled here:
// a shelf never knows what is above or below it, so it reports them.
FocusScope {
    id: shelfRoot

    property string sectionTitle: ""
    property alias model: row.model
    property alias currentIndex: row.currentIndex
    property alias count: row.count

    // Same contract as PosterGrid: posterSource returns "" for an item with no
    // art, which draws the titled placeholder instead.
    property var posterSource: function(item, w, h) { return "" }
    property var titleText: function(item) { return (item && item.title) || "" }
    // Optional corner artwork for wide cells only — see badgeFor.
    property var badgeSource: null
    // Shape of that artwork, width over height (a YouTube avatar is square).
    property real badgeAspect: 2 / 3
    // Optional caption for wide cells only, same rule. Returns
    // { top, bottom, corner }, or null for an item with nothing to say.
    property var captionSource: null

    // Fallback shape, used when the host offers no per-item rule.
    property real posterAspect: 2 / 3
    // Per-item shape. Shelf cells share a height but not a width, so a 2:3 cover
    // and a 16:9 still are both shown whole rather than one cut to the other's
    // box. Ragged widths are the cost — a shelf is a handful of items.
    property var posterAspectFor: null

    // Off inside a sectioned view, where one shared line at the bottom carries
    // the selection instead of repeating under every shelf.
    property bool showTitleLine: true

    // Whether this shelf's selection is the one the user is on. A host driving
    // the shelf from outside — keeping focus and calling moveLeft/moveRight —
    // sets it instead of the default.
    property bool highlighted: activeFocus

    readonly property real frameW: root.sh * 0.00625 //3
    readonly property real gutter: frameW * 2 //6

    // The heading names the row and is its primary text; the selected title is
    // the caption under it. Overhead is 48px either way, so the emphasis swap
    // costs no art. Muted when the cells name the row themselves. A shelf named
    // some other way — a spine at the front of its own row, as the YouTube menu
    // does — passes no title, and an empty heading takes no room.
    property bool headingMuted: false
    readonly property real headerH: sectionTitle === "" ? 0
                                  : headingMuted ? root.sh * 0.0375     //18
                                                 : root.sh * 0.0458333  //22
    readonly property real headerGap: sectionTitle === "" ? 0
                                                          : root.sh * 0.0083333 //4
    readonly property real titleH: showTitleLine ? root.sh * 0.0333333 : 0 //16

    // Whatever the heading and title line leave, minus the ring the cell adds on
    // each side. Posters keep their aspect, so height sets how many fit across.
    readonly property real posterH: Math.max(0, height - headerH - headerGap
                                                - titleH - gutter)
    // Nominal width — what a cell measures with no per-item rule.
    readonly property real posterW: posterH * posterAspect

    function aspectFor(item) {
        var a = posterAspectFor ? posterAspectFor(item) : posterAspect
        return (a > 0) ? a : posterAspect
    }

    // Landscape cells only: a portrait cell is already cover art, so a cover-art
    // badge on it would be the same picture twice.
    function badgeFor(item, w, h) {
        return (badgeSource && aspectFor(item) > 1) ? badgeSource(item, w, h) : ""
    }

    // The caption follows the badge exactly.
    function captionFor(item) {
        return (captionSource && aspectFor(item) > 1) ? captionSource(item) : null
    }

    readonly property var currentItemData:
        (row.model && row.currentIndex >= 0 && row.currentIndex < row.count)
            ? row.model[row.currentIndex] : null

    signal activated()
    signal moveUp()
    signal moveDown()
    signal backRequested()
    // A deliberate sideways step, as opposed to a host seating the selection
    // with moveTo(). Hosts carrying a column between shelves listen for this so
    // only real horizontal moves change what that column is.
    signal moved()

    function positionAtCurrent() {
        row.positionViewAtIndex(row.currentIndex, ListView.Contain)
    }

    // Every move ends here: changing currentIndex alone does not scroll a
    // clipped view.
    function moveTo(i) {
        row.currentIndex = i
        positionAtCurrent()
    }

    // Public so a host driving the shelf without giving it focus can step it.
    function moveLeft() {
        if (row.count === 0) return
        moveTo(row.currentIndex > 0 ? row.currentIndex - 1 : row.count - 1)
        moved()
    }
    function moveRight() {
        if (row.count === 0) return
        moveTo(row.currentIndex < row.count - 1 ? row.currentIndex + 1 : 0)
        moved()
    }

    Text {
        id: header
        visible: shelfRoot.sectionTitle !== ""
        text: shelfRoot.sectionTitle
        color: shelfRoot.headingMuted ? root.tertiaryColor : root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: shelfRoot.headingMuted ? root.sh * 0.0333333  //16
                                               : root.sh * 0.0416667  //20
        elide: Text.ElideRight
        width: shelfRoot.width
        height: shelfRoot.headerH
        verticalAlignment: Text.AlignVCenter
    }

    ListView {
        id: row
        orientation: ListView.Horizontal
        anchors.left: parent.left
        anchors.right: parent.right
        y: shelfRoot.headerH + shelfRoot.headerGap
        height: shelfRoot.posterH + shelfRoot.gutter
        clip: true
        focus: true

        Keys.onLeftPressed: shelfRoot.moveLeft()
        Keys.onRightPressed: shelfRoot.moveRight()
        Keys.onUpPressed: shelfRoot.moveUp()
        Keys.onDownPressed: shelfRoot.moveDown()
        Keys.onReturnPressed: shelfRoot.activated()
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
                || event.key === Qt.Key_Back) {
                shelfRoot.backRequested()
                event.accepted = true
            }
        }

        delegate: PosterCell {
            posterW: shelfRoot.posterH * shelfRoot.aspectFor(modelData)
            posterH: shelfRoot.posterH
            frameW: shelfRoot.frameW
            selected: row.currentIndex === index && shelfRoot.highlighted
            // Asked for at this cell's own width, so the server returns art of
            // exactly the cell's shape and the crop removes nothing.
            art: shelfRoot.posterSource(modelData, posterW, posterH)
            // Sized as it is drawn: the shared badge width, its own shape deep.
            badgeArt: shelfRoot.badgeFor(modelData, posterH / 3,
                                         posterH / 3 / shelfRoot.badgeAspect)
            badgeAspect: shelfRoot.badgeAspect
            title: shelfRoot.titleText(modelData)

            readonly property var caption: shelfRoot.captionFor(modelData)
            captionTop: caption ? (caption.top || "") : ""
            captionBottom: caption ? (caption.bottom || "") : ""
            cornerLabel: caption ? (caption.corner || "") : ""
        }
    }

    // Per-cell captions do not fit at 480p, so one line beneath the shelf
    // carries the selected item's name.
    MarqueeText {
        visible: shelfRoot.showTitleLine
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        height: shelfRoot.titleH
        maxWidth: shelfRoot.width
        text: shelfRoot.titleText(shelfRoot.currentItemData)
        color: root.tertiaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: root.sh * 0.0333333 //16
    }
}
