import QtQuick

// The wall clock in the corner of the screen. A VCR always shows the time, so it
// is instantiated once in Main.qml over every screen rather than being something
// a view has to remember to draw.
//
// Minutes, not seconds: a per-second repaint on a Pi buys nothing. The tick
// still runs every second so the display turns over on the minute.
Text {
    id: clock

    // 12-hour when the app says so — see AppCore::twelve_hour_clock(). Bound
    // through root rather than appCore, the same teardown-safety rule the rest
    // of the shared components follow.
    property bool twelveHour: root.twelveHour

    function _pad(n) { return n < 10 ? "0" + n : "" + n }

    function _tick() {
        var now = new Date()
        var h = now.getHours()
        if (twelveHour) {
            var suffix = h < 12 ? " AM" : " PM"
            h = h % 12
            if (h === 0) h = 12
            text = h + ":" + _pad(now.getMinutes()) + suffix
        } else {
            text = _pad(h) + ":" + _pad(now.getMinutes())
        }
    }

    onTwelveHourChanged: _tick()
    Component.onCompleted: _tick()

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: clock._tick()
    }

    color: root.secondaryColor
    font.family: root.globalFont
    // Matches the clock the playback OSD draws (scripts/mpv-osc.lua), so the time
    // does not change size when the OSD comes up over a video.
    font.pixelSize: root.sh * 0.0333333 //16
}
