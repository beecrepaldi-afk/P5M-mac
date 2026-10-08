import QtQuick

// Translucent white "glass" surface. level: 0 dim, 1 rest, 2 lit (focus,
// hover, pressed or selected).
Rectangle {
    property int level: 1
    readonly property real topAlpha: [14, 30, 62][level] / 255
    readonly property real bottomAlpha: [6, 12, 30][level] / 255
    radius: Theme.radius
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, [26, 46, 110][level] / 255)
    gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(1, 1, 1, topAlpha) }
        GradientStop { position: 1; color: Qt.rgba(1, 1, 1, bottomAlpha) }
    }
}
