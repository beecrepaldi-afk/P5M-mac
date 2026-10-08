import QtQuick
import QtQuick.Layouts

// A P5M setting row with steps: Left/Right (or Cross) change it, Square
// steps back. Dots show where the value sits when there are few steps.
GlassButton {
    id: row
    property int steps: 0          // number of positions, for the dots
    property int position: 0
    signal stepped(int delta)

    Keys.onLeftPressed: stepped(-1)
    Keys.onRightPressed: stepped(1)
    Keys.onNoPressed: stepped(-1)
    onClicked: stepped(1)

    contentItem: RowLayout {
        spacing: 12
        Text {
            Layout.fillWidth: true
            text: row.text
            font: row.font
            elide: Text.ElideRight
            color: row.enabled ? (row.visualFocus ? Theme.text : Theme.textSecondary) : Theme.textMuted
        }
        Text {
            text: "‹"
            visible: row.visualFocus
            color: Theme.textSecondary
            font.pixelSize: row.font.pixelSize
        }
        ColumnLayout {
            spacing: 4
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: row.value
                font: row.font
                color: row.enabled ? row.valueColor : Theme.textMuted
            }
            Row {
                Layout.alignment: Qt.AlignHCenter
                visible: row.steps > 1 && row.steps <= 12
                spacing: 5
                Repeater {
                    model: row.steps
                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: index <= row.position ? Theme.active : Qt.rgba(1, 1, 1, 60 / 255)
                    }
                }
            }
        }
        Text {
            text: "›"
            visible: row.visualFocus
            color: Theme.textSecondary
            font.pixelSize: row.font.pixelSize
        }
    }
}
