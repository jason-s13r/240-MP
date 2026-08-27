import QtQuick
import QtQuick.Effects

Row {
    id: appBar
    
    // Custom Properties
    property url iconSource: "../../assets/images/logo.svg"
    property string title: "240-MP"
    property string subtitle: ""

    // Which end of an over-long subtitle is dropped. A name reads from the left,
    // so its tail goes; a breadcrumb's tail says where you actually are, so it
    // keeps that and drops the path in front of it.
    property int subtitleElide: Text.ElideRight

    // Fits the standard screen gutter — 80px (root.sw * 0.125) on each side —
    // less whatever the top row's corner claims. The subtitle elides when it
    // would overflow this width.
    width: root.sw * 0.75 - root.cornerReserve //480 - corner

    spacing: root.sw * 0.025 //16
    Item {
        visible: appBar.iconSource !== ""
        width: iconImg.width
        anchors.verticalCenter: parent.verticalCenter
        height: root.sh * 0.05 //24
        Image {
            visible: false
            id: iconImg
            height: parent.height
            sourceSize.height: height
            source: appBar.iconSource
        }
        MultiEffect {
            anchors.fill: iconImg
            source: iconImg
            colorization: 1.0
            colorizationColor: root.accentColor
        }
    }

    Text {
        text: appBar.title
        color: root.primaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize: root.sh * 0.05 //24
    }

    Rectangle {
        visible: appBar.subtitle !== ""
        color: root.secondaryColor
        anchors.verticalCenter: parent.verticalCenter
        width: root.sw * 0.0015625 //1
        height: root.sh * 0.05 //24
    }

    Text {
        text: appBar.subtitle
        color: root.secondaryColor
        font.family: root.globalFont
        font.capitalization: Font.AllUppercase
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize: root.sh * 0.0333333 //16
        // x is this Text's Row position, i.e. everything before it (icon,
        // title, separator, spacings) — cap to the bar's remaining space.
        elide: appBar.subtitleElide
        width: Math.max(0, Math.min(implicitWidth, appBar.width - x))
    }
}
