import QtQuick
import QtQuick.Layouts

// "P5M | Screen name", as on every P5M screen.
RowLayout {
    property alias screen: screenLabel.text
    spacing: 14
    Text {
        text: "P5M"
        color: Theme.text
        font.pixelSize: Theme.brandSize
        font.bold: true
        font.letterSpacing: Theme.brandSize * 0.04
    }
    Rectangle {
        visible: screenLabel.text
        Layout.preferredWidth: 1.5
        Layout.preferredHeight: Theme.brandSize * 0.8
        color: Qt.rgba(1, 1, 1, 70 / 255)
    }
    Text {
        id: screenLabel
        color: Theme.textSecondary
        font.pixelSize: Theme.brandSize * 0.75
        font.weight: Font.Light
    }
}
