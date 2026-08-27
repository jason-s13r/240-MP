import QtQuick

// SERVER | PROFILE, in the top corner of every Plex screen.
//
// Which server you are browsing and who you are browsing it as change what every
// list contains, and nothing else says them once you are past the main menu. So
// they sit in the corner permanently, the way a VCR shows the channel it is
// tuned to.
//
// On the main menu both halves are nav targets: the host hands focus here from
// the top of its own list (Root.focusStatus) and takes it back on Down or BACK.
// Deeper in, the host clears `navigable` and the line is only the reading — see
// Root.statusNavigable for why.
FocusScope {
    id: statusRoot

    property string serverName: ""
    property string userName: ""
    // False everywhere but the main menu, where neither half is a link and the
    // whole line is drawn in the muted tone a read-out gets.
    property bool navigable: true
    // Offered only when there is somewhere to switch to.
    property bool canSwitchServer: false

    readonly property bool serverIsLink: navigable && canSwitchServer && hasServer
    readonly property bool userIsLink: navigable && hasUser

    signal serverActivated()
    signal userActivated()
    // Focus is leaving — the host puts it back on the view underneath.
    signal exited()

    // 0 = server, 1 = profile. Entry lands on the profile: it is the nearer of
    // the two to the content the selection came up from, and the one more often
    // switched. The server is a step further out, left or up from here.
    property int segment: 1

    // Three quarters of the clock's size, beside it: this qualifies the reading
    // in the corner rather than being one — the same proportion the playback OSD
    // draws the pair at (scripts/mpv-osc.lua).
    readonly property real fontSize: root.sh * 0.025 //12

    readonly property bool hasServer: serverName !== ""
    readonly property bool hasUser: userName !== ""

    // A server or profile name can be arbitrarily long; the corner cannot. Each
    // half elides into its own share rather than pushing the other off screen —
    // and the share is modest, because the top row is now split three ways with
    // the clock beside it and the header opposite.
    readonly property real maxSegmentWidth: root.sw * 0.125 //80

    implicitWidth: line.width
    implicitHeight: line.height
    width: implicitWidth
    height: implicitHeight

    function enter() {
        segment = userIsLink ? 1 : 0
        forceActiveFocus()
    }

    function selected(which) { return activeFocus && segment === which }

    // Up and Left both reach the server: it reads as the outer of the two on a
    // line that runs left to right, and as the row above on a screen where the
    // step that got here was a step upward.
    Keys.onUpPressed:    if (serverIsLink) segment = 0
    Keys.onLeftPressed:  if (serverIsLink) segment = 0
    Keys.onRightPressed: if (userIsLink) segment = 1
    Keys.onDownPressed:  statusRoot.exited()
    Keys.onReturnPressed: {
        if (segment === 0) { if (serverIsLink) statusRoot.serverActivated() }
        else if (userIsLink) statusRoot.userActivated()
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
            || event.key === Qt.Key_Back) {
            statusRoot.exited()
            event.accepted = true
        }
    }

    // ---
    // UI
    // ---

    Row {
        id: line
        spacing: 0

        // Server
        Item {
            visible: statusRoot.hasServer
            width: serverText.width
            height: serverText.height

            Rectangle {
                anchors.fill: parent
                color: root.accentColor
                visible: statusRoot.selected(0)
            }

            Text {
                id: serverText
                text: statusRoot.serverName
                // Dimmed to the muted tone when it is not a link — whether
                // because there is nowhere to switch to or because this screen
                // only reports. It should not look like one.
                color: statusRoot.selected(0) ? root.surfaceColor
                     : statusRoot.serverIsLink ? root.secondaryColor
                                               : root.tertiaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: statusRoot.fontSize
                elide: Text.ElideRight
                width: Math.min(implicitWidth, statusRoot.maxSegmentWidth)
                leftPadding: root.sw * 0.0078125 //5
                rightPadding: root.sw * 0.0078125 //5
                topPadding: root.sh * 0.0041667 //2
                bottomPadding: root.sh * 0.0041667 //2
            }
        }

        Text {
            visible: statusRoot.hasServer && statusRoot.hasUser
            text: "|"
            color: root.tertiaryColor
            font.family: root.globalFont
            font.pixelSize: statusRoot.fontSize
            topPadding: root.sh * 0.0041667 //2
            bottomPadding: root.sh * 0.0041667 //2
        }

        // Profile
        Item {
            visible: statusRoot.hasUser
            width: userText.width
            height: userText.height

            Rectangle {
                anchors.fill: parent
                color: root.accentColor
                visible: statusRoot.selected(1)
            }

            Text {
                id: userText
                text: statusRoot.userName
                color: statusRoot.selected(1) ? root.surfaceColor
                     : statusRoot.userIsLink ? root.secondaryColor
                                             : root.tertiaryColor
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                font.pixelSize: statusRoot.fontSize
                elide: Text.ElideRight
                width: Math.min(implicitWidth, statusRoot.maxSegmentWidth)
                leftPadding: root.sw * 0.0078125 //5
                rightPadding: root.sw * 0.0078125 //5
                topPadding: root.sh * 0.0041667 //2
                bottomPadding: root.sh * 0.0041667 //2
            }
        }
    }
}
