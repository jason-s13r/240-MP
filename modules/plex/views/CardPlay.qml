import QtQuick

// NFC card deep-link target. Resolves the card's Plex guid to a playable item,
// asks who is watching and from where, then replaces itself with Player.qml.
//
// replaceWith (not navigateTo) is the point: this view leaves no entry on the
// module's nav stack, so backing out of the player unwinds straight to the
// screen the card was tapped from rather than stranding the user inside Plex,
// which they never chose to enter.
//
// The visual language here is the NFC module's, not Plex's — a card tap should
// look the same whatever module ends up serving it.
FocusScope {
    id: cardRoot

    property var navParams: ({})

    signal replaceWith(string path, var params)
    signal goBack()

    property string cardRef:   navParams.cardRef   || ""
    property string cardMode:  navParams.cardMode  || ""
    property string cardTitle: navParams.cardTitle || ""
    property string authState: navParams.authState || ""
    property string pendingPin: navParams.pendingPin || ""

    // loading   — resolving the card as whoever is active
    // choosing  — resume / play / change profile
    // profiles  — which Home profile is watching
    // pin       — that profile's PIN, asked only because plex.tv refused
    // error     — anything above went wrong; ENTER retries
    property string phase: "loading"

    property string errorMessage: ""
    property string sessionId:    ""
    // Guard a stray reply from an earlier attempt (or an earlier profile) from
    // being taken for this one.
    property bool   resolving:    false
    property bool   launching:    false
    property var    pendingDetail: null
    // What the chosen row asked to play from. Set at the moment of choosing, not
    // read off the detail at launch, so PLAY FROM THE BEGINNING stays 0 even
    // though the item itself has a position on it.
    property int    chosenOffset: 0
    // Whether the chooser below actually put the resume question to the user.
    // Passed to the Player, which would otherwise ask it a second time.
    property bool   askedResume: false
    // Set for the one resolve that follows a profile switch. By then the profile
    // question has been answered, so a profile with nothing to resume has nothing
    // left to be asked and simply plays.
    property bool   justSwitched: false

    property string activeUserName: ""
    property string activeUserId:   ""
    property var    homeUsers: []
    // The chooser exists to ask which profile is watching, so it has nothing to
    // ask a Home of one — those setups play on tap exactly as they always have.
    readonly property bool multiProfile: homeUsers.length > 1

    readonly property int resumeMs: (pendingDetail && pendingDetail.viewOffset) || 0

    // What the current profile can do with this card. Rebuilt after a profile
    // switch, which is why RESUME comes and goes: it is only ever offered to
    // someone who actually has a position in this item.
    readonly property var choices: {
        var out = []
        if (cardRoot.resumeMs > 0)
            out.push({ kind: "resume", label: "RESUME " + cardRoot.formatTime(cardRoot.resumeMs) })
        out.push({ kind: "start",
                   label: cardRoot.resumeMs > 0 ? "PLAY FROM THE BEGINNING" : "PLAY" })
        if (cardRoot.multiProfile)
            out.push({ kind: "profile", label: "CHANGE PROFILE" })
        return out
    }
    property int choiceIndex: 0
    property int profileIndex: 0

    // A card tap is meant to be one gesture: tap it, the show starts. The chooser
    // is only there for the times you want something other than that, so it counts
    // itself out and then takes its own first row — RESUME when the profile has a
    // position, otherwise PLAY. Any key press is somebody who does want to choose,
    // and stops the count for the rest of the visit.
    readonly property int autoPlaySeconds: 5
    property bool autoPlayArmed: false
    property int  autoPlayLeft:  autoPlaySeconds

    Timer {
        interval: 1000
        repeat: true
        running: cardRoot.autoPlayArmed && cardRoot.phase === "choosing"
        onTriggered: {
            cardRoot.autoPlayLeft--
            if (cardRoot.autoPlayLeft > 0) return
            cardRoot.autoPlayArmed = false
            // choiceIndex cannot have moved while the count was still armed, so
            // this is the first row, which is the one the card already implies.
            cardRoot.chooseCurrent()
        }
    }

    // --- PIN entry, for a profile plex.tv refuses to switch into without one ---
    readonly property int slotCount: 4
    property var    digits: [0, 0, 0, 0]
    property int    cursor: 0
    property string pinUserId: ""
    property string pinUserTitle: ""
    property string pinError: ""
    property bool   pinSubmitting: false

    focus: true

    function newSessionId() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var id = ""
        for (var i = 0; i < 12; i++) id += chars[Math.floor(Math.random() * chars.length)]
        return id
    }

    function pad(n) { return n < 10 ? "0" + n : "" + n }

    function formatTime(ms) {
        var s = Math.floor(ms / 1000)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        return h > 0 ? h + ":" + pad(m) + ":" + pad(s % 60)
                     : m + ":" + pad(s % 60)
    }

    function fail(msg) {
        resolving = false
        launching = false
        pinSubmitting = false
        justSwitched = false
        errorMessage = msg
        phase = "error"
    }

    function refreshIdentity() {
        activeUserName = plexBackend.get_active_user_name()
        activeUserId   = plexBackend.get_active_user_id()
        // Whoever is watching leads the list, so the two screens agree on who
        // "current" is and the row that changes nothing is never in the way.
        var mine = [], rest = []
        var all = plexBackend.get_home_users()
        for (var i = 0; i < all.length; i++)
            (all[i].id === activeUserId ? mine : rest).push(all[i])
        homeUsers = mine.concat(rest)
    }

    function profileTitle(userId) {
        for (var i = 0; i < homeUsers.length; i++)
            if (homeUsers[i].id === userId) return homeUsers[i].title || ""
        return ""
    }

    // Resolves the card as whoever is active now — run again after a profile
    // switch, because which episode is on deck and where it is up to are both
    // that profile's own answers, not the card's.
    function start() {
        errorMessage = ""
        phase = "loading"
        refreshIdentity()
        // A card never signs anybody in: an unusable session is an error the user
        // resolves in the Plex module itself.
        if (authState === "none") { fail("NOT SIGNED IN TO PLEX"); return }
        if (authState === "needs_user") { fail("NO PLEX SERVER SELECTED"); return }
        if (pendingPin !== "") { fail("THIS PLEX PROFILE NEEDS ITS PIN\n\nOPEN THE PLEX MODULE TO SIGN IN"); return }
        if (cardRef === "") { fail("THIS CARD HAS NO PLEX ITEM"); return }
        resolving = true
        plexBackend.resolve_card(cardRef, cardMode)
    }

    function launch(offsetMs) {
        if (!pendingDetail) return
        var d = pendingDetail
        chosenOffset = offsetMs
        sessionId = newSessionId()
        resolving = false
        launching = true
        phase = "loading"
        // Unlike Item.qml, no set_audio_stream / set_subtitle_stream call: a card
        // tap must not rewrite the server's stored per-part track defaults.
        // Whatever the server already prefers is what plays.
        if (d.forceTranscode) {
            // Always from 0 so the whole timeline stays seekable; Player.qml seeks
            // to the chosen point itself.
            plexBackend.request_transcode(d.ratingKey, d.partKey, sessionId,
                                          d.selectedAudioId || "",
                                          d.selectedSubtitleId || "0", 0)
        } else {
            plexBackend.build_stream_url(d.ratingKey, d.partKey, sessionId)
        }
    }

    function chooseCurrent() {
        var c = choices[choiceIndex]
        if (!c) return
        if (c.kind === "resume")       launch(resumeMs)
        else if (c.kind === "start")   launch(0)
        else if (c.kind === "profile") {
            // Land on the first profile that isn't the one already watching:
            // this list is opened to change something.
            profileIndex = homeUsers.length > 1 ? 1 : 0
            phase = "profiles"
        }
    }

    function chooseProfile() {
        var u = homeUsers[profileIndex]
        if (!u) return
        // Picking who is already watching is how you back out of this list
        // without a round trip to plex.tv.
        if (u.id === activeUserId) { phase = "choosing"; return }
        pinUserId = u.id
        pinUserTitle = u.title || ""
        phase = "loading"
        // reauth_select_user, not select_user: this switch must land the user back
        // where they were, not walk them into the server picker.
        plexBackend.reauth_select_user(u.id)
    }

    function setDigit(value) {
        var d = digits.slice()
        d[cursor] = (value + 10) % 10
        digits = d
    }

    function submitPin() {
        pinSubmitting = true
        pinError = ""
        plexBackend.reauth_select_user(pinUserId, digits.join(""))
    }

    Keys.onPressed: function(event) {
        // Someone is here and pressing keys, so an unattended countdown has no
        // business finishing — including on a key this view does nothing with.
        autoPlayArmed = false

        var back = (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
                    || event.key === Qt.Key_Back)
        var enter = (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)

        if (phase === "error") {
            if (back)       goBack()
            else if (enter) start()
            else return
            event.accepted = true
            return
        }

        if (phase === "choosing") {
            if (back)                          goBack()
            else if (event.key === Qt.Key_Up)   choiceIndex = choiceIndex > 0 ? choiceIndex - 1 : choices.length - 1
            else if (event.key === Qt.Key_Down) choiceIndex = choiceIndex < choices.length - 1 ? choiceIndex + 1 : 0
            else if (enter)                     chooseCurrent()
            else return
            event.accepted = true
            return
        }

        if (phase === "profiles") {
            if (back)                          phase = "choosing"
            else if (event.key === Qt.Key_Up)   profileIndex = profileIndex > 0 ? profileIndex - 1 : homeUsers.length - 1
            else if (event.key === Qt.Key_Down) profileIndex = profileIndex < homeUsers.length - 1 ? profileIndex + 1 : 0
            else if (enter)                     chooseProfile()
            else return
            event.accepted = true
            return
        }

        if (phase === "pin") {
            if (back) {
                // Nothing was switched, so nothing is pending — drop the parked
                // user before going back, or the Plex module would prompt for it
                // on its own next entry.
                plexBackend.cancel_pending_pin()
                phase = "profiles"
            } else if (pinSubmitting) {
                // let it land
            } else if (event.key === Qt.Key_Up)    setDigit(digits[cursor] + 1)
            else if (event.key === Qt.Key_Down)    setDigit(digits[cursor] - 1)
            // Wraps, per the app-wide list convention. BACKSPACE leaves the view,
            // so LEFT is how you go back to correct a digit.
            else if (event.key === Qt.Key_Left)    cursor = cursor > 0 ? cursor - 1 : slotCount - 1
            else if (event.key === Qt.Key_Right)   cursor = cursor < slotCount - 1 ? cursor + 1 : 0
            else if (enter)                        submitPin()
            else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
                setDigit(event.key - Qt.Key_0)
                if (cursor < slotCount - 1) cursor++
            } else return
            event.accepted = true
            return
        }

        // "loading" swallows everything: a keypress mid-switch would be acted on
        // against state that is about to be replaced.
        event.accepted = true
    }

    Connections {
        target: plexBackend

        function onCardItemReady(detail) {
            if (!cardRoot.resolving) return
            cardRoot.resolving = false
            cardRoot.pendingDetail = detail
            var wasSwitch = cardRoot.justSwitched
            cardRoot.justSwitched = false
            // A Home of one has nothing to be asked: play as it always has, from
            // wherever this profile left off.
            if (!cardRoot.multiProfile) {
                cardRoot.launch(detail.viewOffset || 0)
                return
            }
            // Just switched to a profile with no position in this: the only
            // question left would have one answer, so don't ask it.
            if (wasSwitch && !(detail.viewOffset > 0)) {
                cardRoot.launch(0)
                return
            }
            cardRoot.choiceIndex = 0
            cardRoot.askedResume = true
            cardRoot.autoPlayLeft = cardRoot.autoPlaySeconds
            cardRoot.autoPlayArmed = true
            cardRoot.phase = "choosing"
        }

        function onCardError(message) {
            if (!cardRoot.resolving) return
            cardRoot.fail(message)
        }

        // The switch landed. Re-resolve as the new profile: their on-deck episode
        // and their position in it are the two things that just changed.
        function onAuthSuccess() {
            if (cardRoot.phase !== "loading" && cardRoot.phase !== "pin") return
            cardRoot.pinSubmitting = false
            cardRoot.digits = [0, 0, 0, 0]
            cardRoot.cursor = 0
            cardRoot.pendingDetail = null
            cardRoot.justSwitched = true
            cardRoot.start()
        }

        function onUserPinRequired(userId, wrongPin) {
            if (cardRoot.phase !== "loading" && cardRoot.phase !== "pin") return
            cardRoot.pinSubmitting = false
            cardRoot.pinUserId = userId
            cardRoot.pinUserTitle = cardRoot.profileTitle(userId)
            cardRoot.pinError = wrongPin ? "INCORRECT PIN" : ""
            cardRoot.phase = "pin"
        }

        function onStreamUrlReady(url, plexToken) {
            if (!cardRoot.launching || !cardRoot.pendingDetail) return
            var d = cardRoot.pendingDetail
            cardRoot.launching = false
            cardRoot.replaceWith("Player.qml", {
                streamUrl:          url,
                plexToken:          plexToken,
                ratingKey:          d.ratingKey,
                partKey:            d.partKey,
                partId:             d.partId,
                sessionId:          cardRoot.sessionId,
                viewOffset:         cardRoot.chosenOffset,
                resumeAsked:        cardRoot.askedResume,
                title:              d.title,
                grandparentTitle:   d.grandparentTitle || "",
                // See Item.qml: larger than drawn, cropped to the window by the app.
                posterUrl:          plexBackend.poster_url(d, 300, 450, "grid"),
                contentRating:      d.contentRating || "",
                parentIndex:        d.parentIndex || 0,
                index:              d.index || 0,
                audioStreams:       d.audioStreams,
                subtitleStreams:    d.subtitleStreams,
                isTranscoding:      d.forceTranscode || false,
                selectedAudioId:    d.selectedAudioId,
                selectedSubtitleId: d.selectedSubtitleId,
                // A shuffle card is a jukebox: report no timeline, so it leaves the
                // show's watched state and Continue Watching untouched.
                trackProgress:      d.trackProgress !== false,
                // Set only for a shuffle card. It makes the Player draw the next
                // episode from the card's show/season instead of taking the
                // sequential next one — a shuffle card keeps rolling, it just
                // rolls randomly. Autoplay itself is left to the user's setting.
                shuffleScope:       d.cardScope || ""
            })
        }

        function onErrorOccurred(message) {
            if (cardRoot.phase === "pin") {
                // A refused PIN comes through userPinRequired; this is the switch
                // itself failing, which is worth saying out loud.
                cardRoot.pinSubmitting = false
                cardRoot.pinError = message
                return
            }
            if (!cardRoot.resolving && !cardRoot.launching && cardRoot.phase !== "loading") return
            cardRoot.fail(message)
        }
    }

    Component.onCompleted: {
        // A card tap is user activity but arrives with no key event — without this
        // the loading frame and any error would render behind the screen saver.
        root.dismissScreenSaver()
        start()
    }

    Rectangle {
        anchors.fill: parent
        color: "black"

        // --- LOADING ---
        Column {
            anchors.centerIn: parent
            spacing: root.sh * 0.05
            visible: cardRoot.phase === "loading"

            Text {
                text: "LOADING..."
                color: "white"
                font.family: root.globalFont
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.05
            }
            Text {
                visible: cardRoot.cardTitle !== ""
                text: cardRoot.cardTitle
                color: "#919191"
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                width: root.sw * 0.76875
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }
        }

        // --- WHO IS WATCHING, AND FROM WHERE ---
        Column {
            id: chooser
            anchors.centerIn: parent
            spacing: root.sh * 0.0333333
            width: root.sw * 0.5625
            visible: cardRoot.phase === "choosing" || cardRoot.phase === "profiles"

            // What is actually about to play — the card names a show, this names
            // the episode that profile is up to, which is the thing that changes
            // under them when they switch.
            Text {
                text: cardRoot.cardTitle
                color: "#919191"
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0291667
            }

            Text {
                visible: text !== ""
                text: {
                    if (!cardRoot.pendingDetail) return ""
                    var d = cardRoot.pendingDetail
                    if (d.grandparentTitle && d.parentIndex && d.index)
                        return "S" + d.parentIndex + "E" + d.index + " " + (d.title || "")
                    return d.title || ""
                }
                color: "white"
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0375
            }

            Item { width: 1; height: root.sh * 0.0166667 }

            Text {
                text: cardRoot.phase === "profiles" ? "WHO IS WATCHING?"
                                                    : "PLAYING AS " + cardRoot.activeUserName
                color: "#919191"
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0291667
            }

            // Actions for the profile that is active now.
            Column {
                width: parent.width
                visible: cardRoot.phase === "choosing"

                Repeater {
                    model: cardRoot.choices
                    delegate: Item {
                        width: chooser.width
                        height: root.sh * 0.0583333

                        Rectangle {
                            anchors.fill: rowLabel
                            color: root.accentColor
                            visible: index === cardRoot.choiceIndex
                        }

                        Text {
                            id: rowLabel
                            anchors.centerIn: parent
                            text: modelData.label
                            color: index === cardRoot.choiceIndex ? root.surfaceColor : "white"
                            font.family: root.globalFont
                            font.capitalization: Font.AllUppercase
                            topPadding: root.sh * 0.0041667
                            leftPadding: root.sw * 0.009375
                            rightPadding: root.sw * 0.009375
                            bottomPadding: root.sh * 0.00625
                            font.pixelSize: root.sh * 0.0416667
                        }
                    }
                }
            }

            // The Home's profiles. The one watching is listed too, and selecting
            // it is simply how you back out without a round trip to plex.tv.
            Column {
                width: parent.width
                visible: cardRoot.phase === "profiles"

                Repeater {
                    model: cardRoot.homeUsers
                    delegate: Item {
                        width: chooser.width
                        height: root.sh * 0.0583333

                        readonly property bool isCurrent: modelData.id === cardRoot.activeUserId
                        readonly property bool selected: index === cardRoot.profileIndex

                        Rectangle {
                            anchors.fill: profileLabel
                            color: root.accentColor
                            visible: parent.selected
                        }

                        Text {
                            id: profileLabel
                            anchors.centerIn: parent
                            text: (modelData.title || "")
                                  + (parent.isCurrent ? "  (WATCHING)" : "")
                                  // Not a promise that it will ask — plex.tv has
                                  // the last word on that — but the flag is why
                                  // it usually will.
                                  + (modelData.protected === true ? "  • PIN" : "")
                            color: parent.selected ? root.surfaceColor : "white"
                            font.family: root.globalFont
                            font.capitalization: Font.AllUppercase
                            topPadding: root.sh * 0.0041667
                            leftPadding: root.sw * 0.009375
                            rightPadding: root.sw * 0.009375
                            bottomPadding: root.sh * 0.00625
                            font.pixelSize: root.sh * 0.0416667
                        }
                    }
                }
            }

            Item { width: 1; height: root.sh * 0.0166667 }

            Text {
                // Keeps its line whether or not it has anything to say.
                text: cardRoot.autoPlayArmed
                      ? "PLAYING IN " + cardRoot.autoPlayLeft + "..."
                      : " "
                color: root.accentColor
                font.family: root.globalFont
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }

            Text {
                text: root.hints.back + ":BACK " + root.hints.navigate + ":NAVIGATE "
                      + root.hints.select + ":SELECT"
                color: "#919191"
                font.family: root.globalFont
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }
        }

        // --- PROFILE PIN ---
        // A spinner rather than a text field: the app is driven by a remote and a
        // gamepad, which have no digit keys. Digit keys still work on a keyboard.
        Column {
            anchors.centerIn: parent
            spacing: root.sh * 0.0416667
            visible: cardRoot.phase === "pin"

            Text {
                text: cardRoot.pinUserTitle !== ""
                      ? "ENTER THE PIN FOR " + cardRoot.pinUserTitle
                      : "ENTER THE PROFILE PIN"
                color: "#919191"
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.sw * 0.025

                Repeater {
                    model: cardRoot.slotCount
                    delegate: Rectangle {
                        width: root.sw * 0.0625
                        height: root.sh * 0.1
                        color: index === cardRoot.cursor ? root.accentColor : "transparent"
                        border.color: index === cardRoot.cursor ? root.accentColor : "#919191"
                        border.width: root.sh * 0.003125

                        Text {
                            anchors.centerIn: parent
                            text: cardRoot.digits[index]
                            color: index === cardRoot.cursor ? root.surfaceColor : "white"
                            font.family: root.globalFont
                            font.pixelSize: root.sh * 0.05
                        }
                    }
                }
            }

            Text {
                visible: cardRoot.pinError !== ""
                text: cardRoot.pinError
                color: "white"
                font.family: root.globalFont
                font.capitalization: Font.AllUppercase
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }

            Text {
                text: cardRoot.pinSubmitting
                      ? "CHECKING..."
                      : root.hints.back + ":BACK " + root.hints.navigate + ":DIGIT "
                        + root.hints.select + ":ENTER"
                color: "#919191"
                font.family: root.globalFont
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }
        }

        // --- ERROR ---
        Column {
            anchors.centerIn: parent
            spacing: root.sh * 0.05
            visible: cardRoot.phase === "error"

            Text {
                text: cardRoot.errorMessage
                color: "white"
                font.family: root.globalFont
                width: root.sw * 0.5625
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0375
            }
            Text {
                text: root.hints.back + ":BACK " + root.hints.select + ":RETRY"
                color: "#919191"
                font.family: root.globalFont
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: root.sh * 0.0333333
            }
        }
    }
}
