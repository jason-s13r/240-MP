import QtQuick

// One cover-art cell: the artwork, a titled placeholder when there is none, and
// the selection ring. Shared by PosterGrid and PosterShelf.
//
// The ring is drawn on every cell at the same thickness and only coloured when
// selected, so nothing shifts as the selection travels. The gutter between
// neighbours is two rings wide, so adjacent rings meet exactly.
Item {
    id: posterCell

    property string art: ""
    property string title: ""
    property bool selected: false

    // Optional second artwork over the bottom-left corner: a 16:9 still says
    // nothing about which show it came from, so the show's cover names it.
    property string badgeArt: ""
    // Shape of that corner art, width over height (a YouTube avatar is square).
    property real badgeAspect: 2 / 3
    // Every badge is one width whatever its shape, so all take the same bite out
    // of the artwork and the caption beside them starts in the same place.
    readonly property real badgeW: posterH / 3

    // Two caption lines over the art, for the same reason: the item's own name
    // along the top edge, what it belongs to (or how old it is) along the bottom.
    property string captionTop: ""
    property string captionBottom: ""
    // A short label at the end of the bottom line — a runtime. That line gives
    // up the width it takes, so the two never meet.
    property string cornerLabel: ""
    // A label that identifies the cell rather than describing it — the live
    // lineup's channel number, along the bottom from the same corner the
    // runtime reads from. Its own property and not the end of a caption line,
    // because the cells that want it are square and small, with no room for a
    // line of caption to run beside it. It shares that corner with cornerLabel:
    // a host sets one or the other, never both.
    property string cornerTagLabel: ""

    // The artwork is a logo rather than cover art — a station's mark, drawn on
    // whatever canvas the broadcaster chose and meaning nothing with its ends
    // cropped off. Fitted whole instead of cropped to fill, and held off the
    // cell's edges, so the cell reads as a box with a mark in it rather than as
    // a picture that happens to stop at the border — which is what a row of
    // them cropped to fill reads as, one continuous band. The overlays keep the
    // cell's real corners: a channel number sits in the margin the mark gives up.
    property bool logoArt: false
    readonly property real logoInset: logoArt ? posterH * 0.125 : 0
    // A mark is as often black on transparent as white, and the app's own
    // background is black in every theme but one — so a logo cell is backed a
    // shade off it rather than left to sit on it. A neutral veil over whatever
    // the surface is, not a colour of its own: it lifts a black surface to a
    // dark grey and settles a light one, and no theme has to name it.
    readonly property color logoBackdrop:
        Qt.tint(root.surfaceColor, Qt.rgba(0.5, 0.5, 0.5, 0.18))

    property real posterW: 0
    property real posterH: 0
    property real frameW: root.sh * 0.00625 //3

    // Everything laid over the artwork is held this far off the edge it sits
    // against, so nothing reads as cut off by the cell's own edge.
    readonly property real inset: root.sh * 0.0020833 //1

    // Fixed, not derived from the corner art, so caption lines land in the same
    // place on every cell in a row whatever is beside them.
    readonly property real captionLineH: posterH / 8
    // Floored at the size the app's small labels run at: an eighth of a 64px
    // channel square is a 6px digit, and a number that cannot be read is not
    // worth the corner it sits in.
    readonly property real cornerTagLineH: Math.max(captionLineH, root.sh * 0.025) //12
    // Held further off its corner than the caption lines are off theirs. Those
    // lie over photography that runs to the cell's edge, where a pixel is all
    // it takes to stop reading as cut off; this one sits inside a bordered
    // card, and a pixel would leave it touching the card's own rule.
    readonly property real cornerTagInset: root.sh * 0.0104167 //5

    // Past twice as tall as it is wide there is no width left to read a word
    // across, so a placeholder title takes a quarter turn and is read up the
    // card — a spine. Turning rather than stacking is what makes a long name
    // fit: stacked, a word costs its length in height.
    readonly property bool titleTurned: posterW > 0 && posterH >= posterW * 2

    // Clear of the placeholder's own 2px border, with a pixel to spare.
    readonly property real turnedMargin: root.sh * 0.00625 //3

    // Every caption line: sized off the line it is given, outlined in the
    // surface colour because it lies over photography of any brightness.
    component OverlayText: Text {
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        font.pixelSize: height * 0.75
        style: Text.Outline
        styleColor: root.surfaceColor
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }

    width: posterW + frameW * 2
    height: posterH + frameW * 2

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: posterCell.frameW
        border.color: posterCell.selected ? root.accentColor : "transparent"
    }

    Item {
        anchors.centerIn: parent
        width: posterCell.posterW
        height: posterCell.posterH

        // Under the mark, and only under a mark: the same bordered card the
        // placeholder below draws, so a channel with a logo and one without are
        // framed alike. The placeholder covers this when there is no art.
        Rectangle {
            anchors.fill: parent
            visible: posterCell.logoArt
            color: posterCell.logoBackdrop
            border.color: root.tertiaryColor
            border.width: root.sh * 0.003125 //2
        }

        // Filled, not fitted: scaled until it covers the cell, overflow clipped
        // centred. The host normally has the server crop to this size already,
        // so this is the backstop for art that arrives off-ratio anyway. A logo
        // is the exception both ways — see logoArt.
        Image {
            id: poster
            anchors.fill: parent
            anchors.margins: posterCell.logoInset
            source: posterCell.art
            asynchronous: true
            cache: true
            fillMode: posterCell.logoArt ? Image.PreserveAspectFit
                                         : Image.PreserveAspectCrop
            clip: true
            sourceSize.width: posterCell.posterW - posterCell.logoInset * 2
            sourceSize.height: posterCell.posterH - posterCell.logoInset * 2
            visible: status === Image.Ready
        }

        // No art, or the fetch failed: a bordered card carrying the title,
        // never a broken-image box. On a logo cell it takes the backdrop's
        // shade, so a channel whose mark never arrived sits at the same weight
        // as the ones beside it rather than as a hole in the row.
        Rectangle {
            anchors.fill: parent
            visible: !poster.visible
            color: posterCell.logoArt ? posterCell.logoBackdrop : root.surfaceColor
            border.color: root.tertiaryColor
            border.width: root.sh * 0.003125 //2

            Text {
                visible: !posterCell.titleTurned
                anchors.fill: parent
                anchors.margins: root.sw * 0.009375 //6
                text: posterCell.title
                // Primary: with no image the text is the whole cell.
                color: root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                // A shelf card can be 64px wide, which RECOMMENDED does not fit
                // at 10px. Fit gives back rather than eliding the word away.
                font.pixelSize: root.sh * 0.0208333 //10
                fontSizeMode: Text.Fit
                minimumPixelSize: root.sh * 0.0145833 //7
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            // The same title on a card too narrow for it, read from the foot up.
            // Laid out along the card's height, then turned about the centre.
            Text {
                visible: posterCell.titleTurned
                anchors.centerIn: parent
                width: parent.height - posterCell.turnedMargin * 2
                height: parent.width - posterCell.turnedMargin * 2
                rotation: -90
                text: posterCell.title
                color: root.primaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                // Gives back further than text usually does here: a spine is a
                // label on the way past, and small beats cut off at ELIDE.
                font.pixelSize: Math.max(1, Math.min(root.sh * 0.0208333, //10
                                                     height * 0.8))
                fontSizeMode: Text.Fit
                minimumPixelSize: root.sh * 0.0104167 //5
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        // Only over real artwork: on the placeholder the title already names it.
        Rectangle {
            id: badge
            visible: posterCell.badgeArt !== "" && poster.visible
                     && badgeImage.status === Image.Ready
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            // Held off the corner so the still reads as continuing behind it.
            anchors.leftMargin: posterCell.inset
            anchors.bottomMargin: posterCell.inset
            width: posterCell.badgeW
            height: posterCell.badgeAspect > 0 ? width / posterCell.badgeAspect : width
            color: "transparent"
            // A hairline between the two images; anything thicker eats the art.
            border.color: root.surfaceColor
            border.width: root.sh * 0.0020833 //1

            Image {
                id: badgeImage
                anchors.fill: parent
                anchors.margins: badge.border.width
                source: posterCell.badgeArt
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectCrop
                clip: true
                sourceSize.width: badge.width
                sourceSize.height: badge.height
            }
        }

        // Along the top edge: what this cell is.
        OverlayText {
            visible: posterCell.captionTop !== "" && poster.visible
            anchors.left: parent.left
            anchors.leftMargin: posterCell.inset
            anchors.right: parent.right
            anchors.rightMargin: posterCell.inset
            anchors.top: parent.top
            anchors.topMargin: posterCell.inset
            height: posterCell.captionLineH
            text: posterCell.captionTop
        }

        // The foot of the cell, at the same corner the runtime reads from — the
        // channel number under its station logo.
        OverlayText {
            id: cornerTagText
            visible: posterCell.cornerTagLabel !== "" && poster.visible
            text: posterCell.cornerTagLabel
            anchors.right: parent.right
            anchors.rightMargin: posterCell.cornerTagInset
            anchors.bottom: parent.bottom
            anchors.bottomMargin: posterCell.cornerTagInset
            height: posterCell.cornerTagLineH
        }

        // Along the bottom, from wherever the corner art leaves off, stopping
        // short of the label at the far end.
        OverlayText {
            visible: posterCell.captionBottom !== "" && poster.visible
            anchors.left: badge.visible ? badge.right : parent.left
            anchors.leftMargin: posterCell.inset
            anchors.right: cornerText.visible    ? cornerText.left
                         : cornerTagText.visible ? cornerTagText.left
                                                 : parent.right
            // Twice the inset where two runs of text meet: one pixel between
            // letterforms does not read as a gap.
            anchors.rightMargin: (cornerText.visible || cornerTagText.visible)
                                 ? posterCell.inset * 2 : posterCell.inset
            anchors.bottom: parent.bottom
            anchors.bottomMargin: posterCell.inset
            height: posterCell.captionLineH
            text: posterCell.captionBottom
        }

        // The end of that bottom line — the corner a runtime is read from.
        OverlayText {
            id: cornerText
            visible: posterCell.cornerLabel !== "" && poster.visible
            text: posterCell.cornerLabel
            anchors.right: parent.right
            anchors.rightMargin: posterCell.inset
            anchors.bottom: parent.bottom
            anchors.bottomMargin: posterCell.inset
            height: posterCell.captionLineH
        }
    }
}
