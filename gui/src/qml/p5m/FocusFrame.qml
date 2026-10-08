import QtQuick

// The one focus marker of the app: a white 3 px outline over the item.
// Drawn inside the item's edge with the card's own radius: outside, the
// lists clip it (one side thin, the other thick) and the corners miss.
Rectangle {
    property bool shown: parent && (parent.visualFocus !== undefined ? parent.visualFocus : parent.activeFocus)
    anchors.fill: parent
    radius: Theme.radius
    color: "transparent"
    border.width: Theme.focusWidth
    border.color: Theme.text
    visible: shown
    z: 100
}
