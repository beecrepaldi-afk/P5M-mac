import QtQuick
import QtQuick.Layouts

// "[button] action" for the hint bar. Shows the keyboard key instead when
// no controller is connected.
RowLayout {
    property string button
    property string key
    property alias text: label.text
    property bool controller: true
    spacing: 8
    Glyph {
        button: parent.controller || !parent.key ? parent.button : parent.key
        size: 22
    }
    Text {
        id: label
        color: Theme.textMuted
        font.pixelSize: Theme.hintSize
    }
}
