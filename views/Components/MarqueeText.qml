import QtQuick

// A single line of text that scrolls itself when it does not fit its allowance.
// The idiom is hand-copied in every text list row; this is the shared copy the
// poster views use. Sizes its width to the text (capped at maxWidth) rather than
// filling the row, so a highlight anchored to it hugs the glyphs.
Item {
    id: marqueeRoot

    property alias text: label.text
    property alias color: label.color
    property alias font: label.font

    // Widest the line may draw before it scrolls instead.
    property real maxWidth: 0
    // Hosts that scroll only the focused line gate the animation with this.
    property bool active: true

    width: Math.min(label.implicitWidth, maxWidth)
    clip: true

    Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        x: 0
    }

    SequentialAnimation {
        running: marqueeRoot.active && label.implicitWidth > marqueeRoot.width
        loops: Animation.Infinite
        onRunningChanged: if (!running) label.x = 0
        PauseAnimation { duration: 1500 }
        NumberAnimation {
            target: label; property: "x"
            to: marqueeRoot.width - label.implicitWidth
            duration: Math.abs(to) * 20
        }
        PauseAnimation { duration: 2000 }
        PropertyAction { target: label; property: "x"; value: 0 }
    }
}
