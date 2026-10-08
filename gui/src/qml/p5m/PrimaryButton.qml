import QtQuick
import QtQuick.Controls

// The main action of a screen: PlayStation-blue pill, white when focused.
Button {
    id: control
    property string glyph: "cross"
    font.pixelSize: Theme.primarySize
    font.weight: Font.Medium
    leftPadding: 28
    rightPadding: 28
    topPadding: 16
    bottomPadding: 16
    implicitWidth: Math.max(200, implicitContentWidth + leftPadding + rightPadding)
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    contentItem: Row {
        spacing: 12
        Glyph {
            anchors.verticalCenter: parent.verticalCenter
            button: control.glyph
            size: 24
            visible: control.glyph && control.visualFocus
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: control.text
            font: control.font
            color: control.visualFocus || control.hovered ? "#000000" : Theme.text
        }
    }
    background: Rectangle {
        radius: Theme.pillRadius
        color: control.down ? "#DDE3EC" : (control.visualFocus || control.hovered) ? "#FFFFFF" : Theme.accent
    }
}
