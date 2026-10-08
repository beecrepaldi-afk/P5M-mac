import QtQuick
import QtQuick.Layouts

// A live number for the stream panel: status dot, label, big value.
RowLayout {
    property string label
    property string value
    property color dot: Theme.good
    spacing: 10
    Rectangle {
        implicitWidth: 10
        implicitHeight: 10
        radius: 5
        color: parent.dot
    }
    Text {
        Layout.fillWidth: true
        text: parent.label
        color: Theme.textSecondary
        font.pixelSize: Theme.bodySize
    }
    Text {
        text: parent.value
        color: Theme.text
        font.pixelSize: 22
        font.bold: true
    }
}
