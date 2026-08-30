import QtQuick

FocusScope {
    id: moduleRoot

    // Exit signal — emitted to leave the module entirely
    signal goBack()

    property var navParams: ({})

    // The module's manifest id — the single place it appears in this module's QML.
    // Child views reference it via moduleRoot.moduleId.
    property string moduleId: "com.240mp.plex"
    property var _moduleInfo: appCore.get_module_info(moduleId)
    property string moduleName: _moduleInfo.name || ""
    property string moduleIcon: _moduleInfo.icon || ""

    // Internal navigation state
    property var navStack: []
    property var currentParams: ({})

    function navigateTo(viewPath, params, fromState) {
        var resolved = Qt.resolvedUrl(viewPath)
        navStack.push({ source: internalLoader.source, params: currentParams, listState: fromState || {} })
        currentParams = params || {}
        internalLoader.setSource(resolved, { "navParams": params || {} })
    }

    function replaceWith(viewPath, params) {
        var resolved = Qt.resolvedUrl(viewPath)
        currentParams = params || {}
        internalLoader.setSource(resolved, { "navParams": params || {} })
    }

    // Repoint the BACK target after autoplay advances in place. The top of the
    // stack is the detail view the player was launched from; swap its item so
    // exiting the player returns to the now-playing episode's detail screen.
    function updateBackItem(item) {
        if (navStack.length === 0) return
        var top = navStack[navStack.length - 1]
        top.params = Object.assign({}, top.params, { item: item })
    }

    function navigateBack() {
        if (navStack.length === 0) {
            moduleRoot.goBack()
            return
        }
        var prev = navStack.pop()
        if (!prev.source || prev.source.toString() === "") {
            moduleRoot.goBack()
            return
        }
        var restored = Object.assign({}, prev.params)
        restored.navListState = prev.listState || {}
        currentParams = restored
        internalLoader.setSource(prev.source, { "navParams": restored })
    }

    // --- SERVER | PROFILE STATUS LINE ---
    // Drawn here rather than by each view: it belongs to the module, not to any
    // one screen, and this is the one place that outlives a view swap. See
    // StatusLine.qml for what it is for.
    property string activeServer: ""
    property string activeUser: ""
    property var switchableServers: []

    function refreshIdentity() {
        activeServer = plexBackend.get_active_server_name()
        activeUser = plexBackend.get_active_user_name()
        switchableServers = plexBackend.get_switchable_servers()
    }

    // The file name of whatever the loader is showing — the only thing this
    // level knows about the current view, and enough to keep the corner off the
    // screens it does not belong on.
    readonly property string currentView: {
        var s = internalLoader.source.toString()
        return s.substring(s.lastIndexOf("/") + 1)
    }

    // The players hand the screen to mpv, which draws its own OSD carrying the
    // clock and the now-playing block; a nav link into a profile switch has no
    // business over a video. The auth views have no identity to report yet.
    readonly property var _statusHiddenViews: ["Player.qml", "LivePlayer.qml",
                                               "CardPlay.qml", "PinAuth.qml"]
    readonly property bool statusVisible:
        activeServer !== "" && _statusHiddenViews.indexOf(currentView) === -1

    // A nav link only on the main menu. Deeper in, switching would throw away
    // the path that got you there, so the switch lives one BACK away at the top.
    // The selectors themselves are where the corner leads, so not on those
    // either — reading where you are is useful there, walking back in is not.
    readonly property bool statusNavigable:
        statusVisible && currentView === "Libraries.qml"

    // True while the corner holds the focus the content gave up. Views do not
    // read this — the loader below dims for them — but it is what that dimming
    // keys off.
    readonly property bool statusFocused: statusLine.activeFocus

    // Called by a view when a step upward runs off the top of its own content.
    // Returns whether the corner took the focus, so the view can fall back to
    // the wrap it has always done when there is nothing up there.
    function focusStatus() {
        if (!statusNavigable) return false
        statusLine.enter()
        return true
    }

    function returnFocusToView() {
        if (internalLoader.item) internalLoader.item.forceActiveFocus()
    }

    // Anything on the stack belongs to the server (or profile) being left, so it
    // is dropped for a single Libraries entry: `switching` sends the selector
    // back there on success, and backing out of it lands there too — rather than
    // on a detail screen for a library the new server may not even have.
    function _quickSwitch(viewPath, params) {
        navStack = [{ source: Qt.resolvedUrl("Libraries.qml"), params: {}, listState: {} }]
        currentParams = params
        internalLoader.setSource(Qt.resolvedUrl(viewPath), { "navParams": params })
    }

    function switchServer() {
        _quickSwitch("ServerSelect.qml", {
            servers: plexBackend.get_switchable_servers(),
            switching: true
        })
    }

    function switchUser() {
        // No cache load here — UserSelect asks for its own list when it arrives
        // with none, and doing it first would emit usersLoaded before it exists.
        _quickSwitch("UserSelect.qml", { reauth: true, switching: true })
    }

    Loader {
        id: internalLoader
        anchors.fill: parent
        focus: true
        // Steps back while the corner has the focus. Every view here draws its
        // selection from a currentIndex rather than from focus, so without this
        // two things read as selected at once — the same dimming the A-Z panel
        // already does to the list beside it.
        opacity: moduleRoot.statusFocused ? 0.3 : 1
        onLoaded: { if (item) item.forceActiveFocus() }

        Connections {
            target: internalLoader.item
            ignoreUnknownSignals: true
            function onNavigateTo(path, params, listState) { moduleRoot.navigateTo(path, params, listState) }
            function onReplaceWith(path, params) { moduleRoot.replaceWith(path, params) }
            function onGoBack() { moduleRoot.navigateBack() }
            function onUpdateBackItem(item) { moduleRoot.updateBackItem(item) }
        }
    }

    StatusLine {
        id: statusLine
        visible: moduleRoot.statusVisible
        serverName: moduleRoot.activeServer
        userName: moduleRoot.activeUser
        navigable: moduleRoot.statusNavigable
        canSwitchServer: moduleRoot.switchableServers.length > 1

        // In the top row's corner. The shell owns both measurements (Main.qml:
        // statusMargin, cornerCenterY) so anything else on that line lines up.
        anchors.right: parent.right
        anchors.rightMargin: root.statusMargin
        y: root.cornerCenterY - height / 2

        onExited: moduleRoot.returnFocusToView()
        onServerActivated: moduleRoot.switchServer()
        onUserActivated: moduleRoot.switchUser()
    }

    // Claims the corner width from the shell so the AppBar on every Plex screen
    // shrinks for this line instead of running under it. A Binding rather than
    // an assignment: it releases the claim when the module unloads, which an
    // assignment would leave behind for the app's own screens.
    Binding {
        target: root
        property: "statusReserve"
        value: statusLine.visible ? statusLine.width : 0
        restoreMode: Binding.RestoreValue
    }

    // Handle logout signal from backend: clear stack and go to auth
    Connections {
        target: plexBackend
        function onLogoutComplete() {
            moduleRoot.navStack = []
            moduleRoot.navigateTo("PinAuth.qml", {})
        }
        function onAuthRevoked() {
            moduleRoot.navStack = []
            moduleRoot.navigateTo("PinAuth.qml", {})
        }
        // A completed sign-in or switch is the only thing that changes what the
        // corner reads, so it is asked again here rather than polled.
        function onAuthSuccess() { moduleRoot.refreshIdentity() }
        function onAuthStateChanged() { moduleRoot.refreshIdentity() }
    }

    Component.onCompleted: {
        plexBackend.reset_device_check()
        refreshIdentity()
        var state = plexBackend.get_auth_state()

        // NFC card deep-link. Deliberately ahead of — and exclusive of — the
        // auth/user gate below: a card arrives already signed in as somebody, and
        // falling through the gate would land a tap on UserSelect whenever
        // auto_sign_in is off. CardPlay offers a profile switch of its own, so
        // nothing is lost by skipping this one — and its switch goes through the
        // same PIN gate every other switch does. A pending PIN or a missing
        // sign-in is surfaced by CardPlay as an error, not a prompt.
        if (navParams.cardRef) {
            navigateTo("CardPlay.qml", {
                cardRef:   navParams.cardRef,
                cardMode:  navParams.cardMode  || "",
                cardTitle: navParams.cardTitle || "",
                authState: state,
                pendingPin: plexBackend.pending_pin_user()
            })
            return
        }

        // A user picked in the app Settings screen whose switch was refused for
        // want of a PIN. Settings has no Plex view to prompt from, so the prompt
        // is deferred to here — ahead of auto_sign_in, which would otherwise walk
        // straight past it into Libraries with the previous user still active.
        var pendingPin = plexBackend.pending_pin_user()
        if (state === "authed" && pendingPin !== "") {
            navigateTo("ProfilePin.qml", { userId: pendingPin, reauth: true })
        } else if (state === "authed") {
            var autoSignIn = appCore.get_setting(moduleId, "auto_sign_in")
            if (autoSignIn !== true && autoSignIn !== "ON") {
                plexBackend.load_users_from_cache()
                navigateTo("UserSelect.qml", { reauth: true })
            } else {
                navigateTo("Libraries.qml", {})
            }
        } else if (state === "needs_user") {
            // Have token but no server selected yet — show user list
            plexBackend.load_users_from_cache()
            navigateTo("UserSelect.qml", {})
        } else {
            navigateTo("PinAuth.qml", {})
        }
    }
}
