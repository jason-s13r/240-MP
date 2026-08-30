import QtQuick
import QtQuick.Effects

// The NFC reader's light in the top-right corner, drawn by the app shell beside
// the clock whenever the module is enabled.
//
// It is there to say the reader is listening from wherever you happen to be —
// which is the whole point of a card: you tap it, you don't first walk to the
// screen that reads it. And because a tap arrives with no keypress and no screen
// of its own, this is the only acknowledgement it gets before the app moves, so
// the light also beats out what the card turned out to be.
Item {
    id: indicator

    // "none" (idle), "matched" (a card that plays), "unmatched" (one that doesn't).
    readonly property string cardState:
        nfcReaderBackend ? nfcReaderBackend.cardState : "none"

    // A tap would actually be picked up right now: a reader is plugged in and the
    // shell has taps armed. Otherwise the light is dim — the module is on, but
    // nothing is listening.
    readonly property bool ready:
        nfcReaderBackend ? (nfcReaderBackend.readerConnected && nfcReaderBackend.tapsArmed)
                         : false

    // Animated rather than the tint's opacity itself, which is bound — an
    // animation writing that property would break the binding for good.
    property real pulse: 1.0

    // Sized to the text beside it — the waves fill their whole viewBox, so this
    // is the height of the *ink* they should match, not a font size. Main.qml
    // measures the clock's own digits and binds it; this default is that
    // measurement at the clock's size, for a host that doesn't.
    implicitHeight: root.sh * 0.0244140 //11.7
    implicitWidth: waves.width
    height: implicitHeight
    width: implicitWidth

    Image {
        id: waves
        visible: false  // drawn by the tint below
        source: "../../assets/images/nfc.svg"
        height: indicator.height
        sourceSize.height: height
        fillMode: Image.PreserveAspectFit
    }

    MultiEffect {
        id: tint
        anchors.fill: waves
        source: waves
        colorization: 1.0
        colorizationColor: indicator.cardState === "matched"   ? root.accentColor
                         : indicator.cardState === "unmatched" ? root.primaryColor
                         : indicator.ready                     ? root.secondaryColor
                                                               : root.tertiaryColor
        opacity: (indicator.ready || indicator.cardState !== "none" ? 1.0 : 0.45)
                 * indicator.pulse
    }

    // Beats while a card is on the reader — accent for one that matched and is
    // about to play, primary for one with nothing mapped to it, which keeps
    // beating for as long as the card sits there unread.
    SequentialAnimation {
        running: indicator.cardState !== "none"
        loops: Animation.Infinite
        onRunningChanged: if (!running) indicator.pulse = 1.0
        NumberAnimation {
            target: indicator; property: "pulse"
            to: 0.25; duration: 350; easing.type: Easing.InOutQuad
        }
        NumberAnimation {
            target: indicator; property: "pulse"
            to: 1.0; duration: 350; easing.type: Easing.InOutQuad
        }
    }
}
