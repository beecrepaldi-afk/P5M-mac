import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A row of the P5M menus: glass card, label on the left, value or the
// controller button that triggers it on the right. Focus = white outline.
Button {
    id: control
    property bool selected: false
    property string glyph: ""
    property string value: ""
    property color valueColor: Theme.active
    font.pixelSize: Theme.itemSize
    font.weight: Font.Medium
    leftPadding: 18
    rightPadding: 18
    topPadding: 14
    bottomPadding: 14
    implicitHeight: Math.max(Theme.rowHeight, implicitContentHeight + topPadding + bottomPadding)
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    contentItem: RowLayout {
        spacing: 12
        Text {
            Layout.fillWidth: true
            text: control.text
            font: control.font
            elide: Text.ElideRight
            color: control.enabled ? (control.selected || control.visualFocus ? Theme.text : Theme.textSecondary) : Theme.textMuted
        }
        Text {
            visible: control.value
            text: control.value
            font: control.font
            color: control.enabled ? control.valueColor : Theme.textMuted
        }
        Glyph {
            visible: control.glyph
            button: control.glyph
            size: 22
        }
    }
    background: Glass {
        level: control.visualFocus || control.down || control.hovered || control.selected ? 2 : 1
        FocusFrame { shown: control.visualFocus }
    }
}
