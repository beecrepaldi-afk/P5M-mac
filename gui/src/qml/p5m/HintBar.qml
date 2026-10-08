import QtQuick
import QtQuick.Layouts

import org.streetpea.chiaking

// Bottom line of controller hints. hints: [{ button, key, text }, ...]
RowLayout {
    property var hints: []
    readonly property bool controller: Chiaki.controllers.length > 0
    spacing: 26
    Repeater {
        model: parent.hints
        Hint {
            button: modelData.button
            key: modelData.key || ""
            text: modelData.text
            controller: parent.controller
        }
    }
}
