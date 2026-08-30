import QtQuick
import QtQuick.Window
import Components

Window {
    id: root
    flags: Qt.FramelessWindowHint | Qt.Window
    x:      Qt.platform.os === "osx" ? macScreenX      : Screen.virtualX
    y:      Qt.platform.os === "osx" ? macScreenY      : Screen.virtualY
    width:  Qt.platform.os === "osx" ? macScreenWidth  : Screen.width
    height: Qt.platform.os === "osx" ? macScreenHeight : Screen.height
    // macOS uses manual geometry (the target display chosen by the app-level
    // "display_index" setting, resolved in main.cpp) + a native fullscreen
    // call to keep the mpv-over-window layering intact. Everywhere else,
    // request true fullscreen so a desktop compositor's panel/dock (KDE on the
    // Steam Deck, labwc on the Pi) is covered rather than left stacked on top;
    // the Screen.* bindings track the window's screen, so they follow the
    // display_index move main.cpp performs after load. Headless EGLFS is
    // already fullscreen, so this is a no-op there.
    visibility: Qt.platform.os === "osx" ? Window.AutomaticVisibility
                                         : Window.FullScreen
    visible: true
    color: root.surfaceColor

    // --- Color Schemes ---
    readonly property var themes: ({
        "Video 1": {
            "primary": "#FFFFFF",
            "secondary": "#C2BFE4",
            "tertiary": "#8480C9",
            "surface": "#0A0094",
            "accent": "#AECFFF"
        },
        "Late Night": {
            "primary": "#FFFFFF",
            "secondary": "#A1A1A1",
            "tertiary": "#444444",
            "surface": "#000000",
            "accent": "#FFD900"
        },
        "Synthwave": {
            "primary": "#FFFFFF",
            "secondary": "#D48BFF",
            "tertiary": "#7836B5",
            "surface": "#12012B",
            "accent": "#00E5FF"
        },
        "Terminal": {
            "primary": "#4AF626",
            "secondary": "#32A81B",
            "tertiary": "#1A590E",
            "surface": "#000000",
            "accent": "#4AF626"
        },
        "T-120": {
            "primary": "#000000",
            "secondary": "#818181",
            "tertiary": "#df9c27",
            "surface": "#FAF5E8",
            "accent": "#EE442F"
        },
        "Amber": {
            "primary": "#FFB000",
            "secondary": "#B37B00",
            "tertiary": "#B37B00",
            "surface": "#000000",
            "accent": "#FFEE11"
        },
        "Kinescope": {
            "primary": "#FFFFFF",
            "secondary": "#9E9E9E",
            "tertiary": "#424242",
            "surface": "#121212",
            "accent": "#FFFFFF"
        },
        "SMPTE ECR 1-1978": {  // 75% max 0xFF == 0xBF, 40% max 0xFF == 0x66, 7.5% max 0xFF == 0x13; 75/7.5 targets per https://en.wikipedia.org/wiki/SMPTE_color_bars#Analog_NTSC - mixed with 40% in "off channels" to both wash out and improve contrast
            "primary": "#BFBFBF",
            "secondary": "#66BF66",
            "tertiary": "#6666BF",
            "surface": "#131313",
            "accent": "#BF6666"
        }
    })
    property var allThemes: themes  // may gain a "Custom" entry on startup
    property string currentTheme: "Video 1"
    property string primaryColor:   (allThemes[currentTheme] || allThemes["Video 1"]).primary
    property string secondaryColor: (allThemes[currentTheme] || allThemes["Video 1"]).secondary
    property string tertiaryColor:  (allThemes[currentTheme] || allThemes["Video 1"]).tertiary
    property string surfaceColor:   (allThemes[currentTheme] || allThemes["Video 1"]).surface
    property string accentColor:    (allThemes[currentTheme] || allThemes["Video 1"]).accent

    // The one ink no theme owns: how much of a video has been watched, drawn
    // along the foot of its thumbnail. Red because that is the mark — it is read
    // at a glance and not read at all in a palette's own greys, and a theme
    // recolouring it would be recolouring what it means.
    readonly property string watchedInk: "#FF0000"

    // Whether every clock in the app reads 12-hour. Resolved once by AppCore and
    // mirrored here so views bind root.twelveHour, never appCore.
    property bool twelveHour: false

    // The top row's right-hand corner. The clock sits on the right margin, on
    // the vertical centre the playback OSD draws its own clock at
    // (scripts/mpv-osc.lua), so the reading does not move when mpv takes the
    // screen; a module may hang a status line of its own to the left of it.
    readonly property real cornerGap: root.sw * 0.025 //16
    // Tighter than the gutter above, and deliberately: what the shell hangs
    // beside the clock reads as part of it, not as the next thing along. The
    // full gutter still separates the pair from a module's status line.
    readonly property real badgeGap: root.cornerGap * 0.5 //8
    readonly property real cornerMargin: root.sw * 0.12 //76.8
    readonly property real cornerCenterY: root.sh * 0.1260417 //60.5

    // Width a module claims there. Written by the module that draws one and back
    // to 0 when it goes away, so the header shrinks for it rather than running
    // into it.
    property real statusReserve: 0

    // What the shell itself hangs beside the clock: the NFC indicator, when there
    // is a reader listening. Between the clock and a module's status line, so the
    // shell's own corner reads as one block whichever module is up.
    readonly property real cornerBadges:
        nfcIndicator.visible ? nfcIndicator.width + root.badgeGap : 0

    // Where that line hangs: clear of the clock and of anything the shell has put
    // beside it. A module anchors to parent.right with this margin.
    readonly property real statusMargin:
        root.cornerMargin + appClock.width + root.cornerGap + root.cornerBadges

    // How much of the top row the corner takes, all told. A header sizes itself
    // to what is left rather than running into it, and it moves with the reading
    // — "11:59 PM" is wider than "23:59" — and with whatever is beside it.
    readonly property real cornerReserve: appClock.width
                                        + root.cornerBadges
                                        + (root.statusReserve > 0
                                           ? root.statusReserve + root.cornerGap : 0)
                                        + root.cornerGap

    // Poster art feature switch, read by the media modules' browse and detail
    // views. Mirrors color_scheme: seeded in Component.onCompleted, kept live by
    // onAppSettingChanged. Views must bind root.posterGrid, never appCore.
    property bool posterGrid: false

    // Live TV guide switch, read by the live channel list. Mirrored here for the
    // same reason posterGrid is: views bind root.liveEpg, never appCore.
    property bool liveEpg: false

    readonly property real sw: width
    readonly property real sh: height

    Connections {
        target: appCore
        // Enabling a module, or changing its hours format, can change the answer
        // for the whole app — asked again rather than reasoned about here.
        function onModuleSettingChanged(moduleId, key, value) {
            if (key === "hours_format" || key === "enabled")
                root.twelveHour = appCore.twelve_hour_clock()
        }

        function onAppSettingChanged(key, value) {
            if (key === "color_scheme") {
                root.currentTheme = value
            } else if (key === "poster_grid") {
                root.posterGrid = (value === "On")
            } else if (key === "live_epg") {
                root.liveEpg = (value === "On")
            } else if (key === "screensaver_timeout") {
                var sec = parseInt(value)
                if (sec > 0) {
                    idleTracker.threshold = sec
                    idleTracker.enabled = true
                } else {  // "OFF"
                    idleTracker.enabled = false
                    if (screenSaverActive) screenSaverActive = false
                }
            }
        }
    }

    // The startup module, entered once the settings above have been applied.
    function navigateToStartupModule() {
        var entryPoint = appCore.startupModuleEntryPoint()
        if (!entryPoint)
            return
        root.appNavStack.push({
            source: moduleLoader.source,
            params: root.appCurrentParams,
            listState: {}
        })
        moduleLoader.setSource(entryPoint, { "navParams": { fromAppStartup: true } })
    }

    Component.onCompleted: {
        var cfg = appCore.get_settings()

        var cThemes = appCore.getCustomColorSchemes()
        if (Object.keys(cThemes).length > 0) {
            var t = Object.assign({}, themes, root.allThemes)
            for (var cTheme in cThemes) {
                if (Object.keys(cThemes[cTheme]).length === 5) {
                    t[cTheme] = cThemes[cTheme]
                }
            }
            root.allThemes = t
        }

        var custom = appCore.getCustomColorScheme()
        if (Object.keys(custom).length === 5) {
            var t = Object.assign({}, themes, root.allThemes)
            t["Custom"] = custom
            root.allThemes = t
        }

        root.posterGrid = ((cfg.app && cfg.app.poster_grid) || "Off") === "On"
        root.liveEpg    = ((cfg.app && cfg.app.live_epg) || "Off") === "On"
        root.twelveHour = appCore.twelve_hour_clock()

        var savedTheme = (cfg.app && cfg.app.color_scheme) || "Video 1"
        if (savedTheme === "Custom" && !root.allThemes["Custom"]) {
            appCore.save_setting("", "color_scheme", "Video 1")
            savedTheme = "Video 1"
        }
        root.currentTheme = savedTheme

        // Screensaver: the tracker starts disabled; this is the single place the
        // saved setting is applied (live changes land in onAppSettingChanged above,
        // mirroring color_scheme). parseInt("OFF") is NaN, so OFF stays disabled.
        var ssSec = parseInt(cfg.app && cfg.app.screensaver_timeout)
        if (ssSec > 0) {
            idleTracker.threshold = ssSec
            idleTracker.enabled = true
        }

        // nfcTapsArmed only reports its *changes* to the reader; this is where it
        // states where the app starts out — listening, on the menu, with nothing
        // else on the screen.
        nfcReaderBackend.setTapsArmed(root.nfcTapsArmed)

        // Break declarative bindings on macOS so the C++ NSWindow override
        // in forceWindowFullScreenOnScreen() isn't immediately re-fought by QML.
        if (Qt.platform.os === "osx") {
            root.x = macScreenX
            root.y = macScreenY
            root.width = macScreenWidth
            root.height = macScreenHeight
        }
    }
    
    FontLoader {
        id: font; source: "assets/fonts/VCR_OSD_MONO_1.001.ttf"
    }
    // Unifont fills in glyphs VCR OSD Mono doesn't have (CJK, Hangul, etc.),
    // it's a bitmap-style font so it actually matches the retro CRT look
    // instead of a mismatched serif/sans fallback. This Qt build's font value
    // type has no font.families (checked plugins.qmltypes: family only), so
    // loading it here just registers it with Qt's fontconfig-backed font
    // database; Qt's own missing-glyph fallback then picks it up for every
    // existing font.family: root.globalFont binding with no further changes.
    FontLoader {
        id: unifontLoader; source: "assets/fonts/unifont.otf"
    }
    property string globalFont: font.name;

    // --- INPUT / APP INFO MIRRORS ---
    // Views must bind these via `root.*`, never the appCore/inputManager
    // context properties directly: when the module Loader swaps views, the
    // dying view's context properties resolve to null and any binding on them
    // throws a TypeError during teardown. id-resolved `root.*` stays valid
    // (root lives as long as the app), so these mirrors are teardown-safe.
    // The null guards absorb the same nulling here at app shutdown, when the
    // engine invalidates the root context itself.
    readonly property var hints: inputManager ? inputManager.hints : ({})
    readonly property string appVersion: appCore ? appCore.appVersion : ""
    // True while something else owns the whole display: mpv playing, a weather
    // forecast, a takeover script. The two flags the screen saver already reads,
    // behind the same null guard as the mirrors above.
    readonly property bool displayOwned:
        idleTracker ? (idleTracker.mpvActive || idleTracker.scriptActive) : false

    // --- SCREEN SAVER STATE ---
    property bool screenSaverActive: false

    // Playback counts as user activity even when no key started it (an NFC
    // card tap launches mpv directly). If the saver was showing at launch,
    // nothing key-driven ever reaches its dismiss handler — focus has moved
    // into the module's player view — so clear it on playback transitions.
    function dismissScreenSaver() {
        if (!screenSaverActive) return
        screenSaverActive = false
        moduleLoader.forceActiveFocus()
    }

    // --- APP-LEVEL NAV STACK ---
    property var appNavStack: []
    property var appCurrentParams: ({})
    property bool _startupNavigated: false

    // --- NFC CARD TAPS ---
    // A card plays from wherever the app happens to be, not only from the NFC
    // module's own screen: walking to that screen to tap is exactly the errand a
    // card exists to save. Behind that module's own "Tap From Any Screen" setting,
    // which also drops it from the main menu — with this on there is nothing left
    // to open it for. The module still routes the taps it is up for (it has a
    // cassette to animate and an internal player to reach without reloading
    // itself); everywhere else the shell routes them, below.
    //
    // Armed on every screen the app itself draws. Not while something else has
    // the display (mpv, a takeover script): a tap must never pull the UI out from
    // under a video. And not while a card already accepted is still on its way to
    // a player, so a second tap can't overtake the first.
    readonly property bool nfcTapsArmed: nfcReaderBackend
                                         && nfcReaderBackend.enabled
                                         && nfcReaderBackend.tapAnywhere
                                         && !root.displayOwned
                                         && !root.cardNavActive
    onNfcTapsArmedChanged: nfcReaderBackend.setTapsArmed(root.nfcTapsArmed)

    // Raised from the moment a tapped card is routed somewhere until the app
    // comes back to the screen it was tapped from, and lowered there rather than
    // on playback because that is the one event every trip has: a resolve screen
    // that errors out and is backed away from never reaches a player at all. It
    // is also where the reader is told the card is done with, for the same reason
    // — the NFC module's own player says so itself, a receiving module can't be
    // asked to.
    property bool cardNavActive: false
    property int _cardNavDepth: 0

    function beginCardNav() {
        root._cardNavDepth = root.appNavStack.length
        root.cardNavActive = true
    }

    function endCardNav() {
        if (!root.cardNavActive) return
        root.cardNavActive = false
        if (nfcReaderBackend) nfcReaderBackend.resetAfterPlayback()
    }

    // --- MPV PLAYBACK TRACKING ---
    // Block the screen saver while mpv is playing so it never flashes during or
    // immediately after playback. The core guard is in IdleTracker (mpvActive
    // property), which also resets the idle timer on transitions.
    Connections {
        target: mpvController
        function onPositionChanged(ms) {
            if (ms > 0 && !idleTracker.mpvActive) {
                idleTracker.mpvActive = true
                idleTracker.resetActivity()
                root.dismissScreenSaver()
            }
        }
        function onPlaybackEnded(finalPositionMs, finalDurationMs, reason) {
            idleTracker.mpvActive = false
            idleTracker.resetActivity()
            root.dismissScreenSaver()
        }
    }

    // A running user script suppresses the screen saver too — a takeover script
    // owns the display, and even a console one is legitimately silent for as long
    // as it takes. Its own flag rather than reusing mpvActive, so ending one
    // session can't unblock the saver while the other is still going.
    Connections {
        target: scriptsBackend
        function onScriptRunningChanged() {
            idleTracker.scriptActive = scriptsBackend.scriptBusy
            idleTracker.resetActivity()
            if (!scriptsBackend.scriptBusy)
                root.dismissScreenSaver()
        }
    }

    // --- MODULE LOADER ---
    Loader {
        id: moduleLoader;
        anchors.fill: parent;
        focus: true;
        source: "views/ModuleList.qml";

        Keys.onPressed: (event) => {
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Q) {
                Qt.quit()
            }
        }

        onLoaded: {
            item.forceActiveFocus()
            if (!root._startupNavigated) {
                root._startupNavigated = true
                // Deferred a tick: this fires while the window is still being
                // built, and the app settings — poster_grid, the theme, the
                // 12/24-hour clock — are seeded in the root's own
                // Component.onCompleted, which QML runs only after every child
                // has completed. A module booted straight into would otherwise
                // read every one of them at its default.
                Qt.callLater(root.navigateToStartupModule)
            }
        }

        Connections {
            target: moduleLoader.item
            ignoreUnknownSignals: true

            function onNavigateTo(path, params, listState) {
                // A hand-off the NFC module routed itself, from its own screen.
                // The trip out and back is the shell's to hold open either way.
                if (params && params.cardRef) root.beginCardNav()
                root.appNavStack.push({ source: moduleLoader.source, params: root.appCurrentParams, listState: listState || {} })
                root.appCurrentParams = params || {}
                moduleLoader.setSource(path, { "navParams": params || {} })
            }

            function onGoBack() {
                if (root.appNavStack.length === 0) return
                var prev = root.appNavStack.pop()
                root.appCurrentParams = prev.params
                moduleLoader.setSource(prev.source, { "navParams": prev.params, "navListState": prev.listState || {} })
                // Back at (or above) where a card was tapped: its trip is over.
                if (root.appNavStack.length <= root._cardNavDepth) root.endCardNav()
            }

        }
    }

    // A tap the NFC module is not on screen to route itself. The dwell before the
    // app moves is the tap's receipt: the corner light is already beating in the
    // card's colour, and a hard cut straight to a loading screen would throw that
    // away. Extra taps during it are ignored by the backend, which holds the
    // claim from the moment it matched the card.
    Timer {
        id: cardTapDwell
        interval: 1200
        repeat: false
        // Where the card is going, and what it tells that module on arrival —
        // the module's entry point and its navParams, nothing this level reads.
        property string moduleEntry: ""
        property var params: ({})
        onTriggered: {
            if (moduleEntry === "") return
            root.beginCardNav()
            root.appNavStack.push({ source: moduleLoader.source,
                                    params: root.appCurrentParams,
                                    listState: {} })
            root.appCurrentParams = cardTapDwell.params
            moduleLoader.setSource(cardTapDwell.moduleEntry, { "navParams": cardTapDwell.params })
        }
    }

    Connections {
        target: nfcReaderBackend

        // A card mapped to a file or a stream: the NFC module's own player owns
        // that, so the card is routed into that module the same way any other
        // card is routed into the module that owns it.
        function onPlaybackRequested(videoPath) {
            if (nfcReaderBackend.moduleActive) return
            cardTapDwell.moduleEntry = nfcReaderBackend.entryPoint()
            cardTapDwell.params = { cardVideoPath: videoPath,
                                    cardTitle: nfcReaderBackend.videoTitle }
            cardTapDwell.restart()
        }

        // A card pointing at another module's content (e.g. a Plex guid). That
        // module owns resolution, auth and playback; it is handed the ref and
        // told nothing else.
        function onCardHandoffRequested(moduleId, ref, mode) {
            if (nfcReaderBackend.moduleActive) return
            cardTapDwell.moduleEntry = appCore.module_entry_point(moduleId)
            cardTapDwell.params = { cardRef: ref,
                                    cardMode: mode,
                                    cardTitle: nfcReaderBackend.videoTitle }
            cardTapDwell.restart()
        }
    }

    // --- CLOCK ---
    // Declared after the module loader so it sits over whatever view is up, and
    // before the screen saver so the saver's black frame still covers it.
    // Hidden while something else owns the display — a weather forecast or a
    // takeover script draws its own full screen, clock included.
    Clock {
        id: appClock
        visible: !root.displayOwned
        // Placed where the OSD's own clock sits, so the time stays put when a
        // video's OSD comes up over it.
        anchors.right: parent.right
        anchors.rightMargin: root.cornerMargin
        y: root.cornerCenterY - height / 2
    }

    // --- NFC READER LIGHT ---
    // Beside the clock, because the corner is where the eye already goes and a
    // reader that listens everywhere has to say so somewhere. Only where a tap
    // would do something: the module enabled and set to read from any screen,
    // and the app — not mpv — on it.
    NfcIndicator {
        id: nfcIndicator
        visible: nfcReaderBackend && nfcReaderBackend.enabled
                 && nfcReaderBackend.tapAnywhere
                 && nfcReaderBackend.available && !root.displayOwned
        anchors.right: parent.right
        anchors.rightMargin: root.cornerMargin + appClock.width + root.badgeGap
        y: root.cornerCenterY - height / 2
        // Exactly as tall as the digits it sits beside. Not the clock's font size:
        // that is the em box, and a digit's ink fills only about three quarters
        // of it, where the waves fill their whole viewBox — matching the sizes
        // would leave the icon visibly the larger of the two.
        height: clockInk.tightBoundingRect.height
    }

    // The ink height of a digit in the clock's own font, measured rather than
    // assumed so it follows the font and the clock's size. "0" rather than the
    // reading itself: every glyph the clock can show sits between the same
    // baseline and cap, and a fixed sample doesn't re-measure on the minute.
    TextMetrics {
        id: clockInk
        font: appClock.font
        text: "0"
    }

    // --- SCREEN SAVER (Idle Tracker integration) ---
    Connections {
        target: idleTracker
        function onActiveChanged() {
            // Only show on active → true; never hide here — the overlay's
            // key handler owns dismissal, preventing the C++ event filter's
            // synchronous reset from stealing the key from QML.
            if (idleTracker.active && idleTracker.enabled) {
                if (!screenSaverActive) {
                    var usableW = screenSaverOverlay.width - bounceLogo.width
                    var usableH = screenSaverOverlay.height - bounceLogo.height
                    bounceLogo.x = Math.random() * (usableW > 0 ? usableW : 1)
                    bounceLogo.y = Math.random() * (usableH > 0 ? usableH : 1)
                    bounceLogo.vx = (Math.random() > 0.5 ? 1 : -1) * (1 + Math.random() * 1.5)
                    bounceLogo.vy = (Math.random() > 0.5 ? 1 : -1) * (1 + Math.random() * 1.5)
                    screenSaverActive = true
                    screenSaverOverlay.forceActiveFocus()
                }
            }
        }
    }

    Item {
        id: screenSaverOverlay
        anchors.fill: parent
        visible: screenSaverActive
        z: 9999
        focus: visible

        // Solid black background — no transparency so it serves as a true
        // CRT burn-in prevention black frame between the logo bounces.
        Rectangle {
            anchors.fill: parent
            color: "#000000"
        }

        // Bouncing logo — classic DVD player screen saver
        Image {
            id: bounceLogo
            source: "assets/images/logo.svg"
            sourceSize.width: root.sw * 0.05
            sourceSize.height: root.sw * 0.05
            fillMode: Image.PreserveAspectFit
            antialiasing: true

            property real vx: 0
            property real vy: 0

            // Physics tick at ~60 fps while the overlay is visible
            Timer {
                interval: 16
                repeat: true
                running: screenSaverActive
                onTriggered: {
                    bounceLogo.x += bounceLogo.vx
                    bounceLogo.y += bounceLogo.vy

                    if (bounceLogo.x + bounceLogo.width > screenSaverOverlay.width) {
                        bounceLogo.x = screenSaverOverlay.width - bounceLogo.width
                        bounceLogo.vx = -Math.abs(bounceLogo.vx)
                    } else if (bounceLogo.x < 0) {
                        bounceLogo.x = 0
                        bounceLogo.vx = Math.abs(bounceLogo.vx)
                    }

                    if (bounceLogo.y + bounceLogo.height > screenSaverOverlay.height) {
                        bounceLogo.y = screenSaverOverlay.height - bounceLogo.height
                        bounceLogo.vy = -Math.abs(bounceLogo.vy)
                    } else if (bounceLogo.y < 0) {
                        bounceLogo.y = 0
                        bounceLogo.vy = Math.abs(bounceLogo.vy)
                    }
                }
            }
        }

        // Capture any keypress to dismiss — consumes the event so the
        // underlying view never sees it, preventing accidental navigation.
        // Ctrl+Q still quits (moduleLoader's handler is a sibling, so it
        // can't see keys focused here — handle the chord directly).
        Keys.onPressed: (event) => {
            event.accepted = true
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Q) {
                Qt.quit()
                return
            }
            screenSaverActive = false
            moduleLoader.forceActiveFocus()
        }
    }
}
