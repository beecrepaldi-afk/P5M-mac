import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

import "../p5m"

import org.streetpea.chiaking

TextField {
    property bool firstInFocusChain: false
    property bool lastInFocusChain: false
    property bool sendOutput: false
    readOnly: true

    onActiveFocusChanged: {
        if (!activeFocus)
            readOnly = true;
    }

    Keys.onPressed: (event) => {
        // Keys this control does not handle (Circle/Esc, L1/R1...) go on
        // to the dialog.
        event.accepted = false;
        switch (event.key) {
        case Qt.Key_Up:
            if (!firstInFocusChain && readOnly) {
                let item = nextItemInFocusChain(false);
                if (item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                if(!sendOutput)
                    event.accepted = true;
            }
            break;
        case Qt.Key_Down:
            if (!lastInFocusChain && readOnly) {
                let item = nextItemInFocusChain();
                if (item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                if(!sendOutput)
                    event.accepted = true;
            }
            break;
        case Qt.Key_Return:
            if (readOnly && Chiaki.controllers.length > 0 && typeof root !== "undefined" && root.openKeyboard) {
                // With a controller there is no keyboard at hand: P5M's own.
                root.openKeyboard(this);
                event.accepted = true;
            } else if (readOnly) {
                readOnly = false;
                Qt.inputMethod.show();
                event.accepted = true;
            } else {
                readOnly = true;
                event.accepted = true;
            }
            break;
        case Qt.Key_Escape:
            if (!readOnly) {
                readOnly = true;
                editingFinished();
                event.accepted = true;
            }
            break;
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: parent.readOnly
        onClicked: {
            parent.forceActiveFocus(Qt.TabFocusReason);
            parent.readOnly = false;
            Qt.inputMethod.show();
        }
    }

    // The P5M focus marker, same as everywhere else.
    FocusFrame {
        radius: 10
        shown: parent.activeFocus && parent.focusReason !== Qt.MouseFocusReason
    }
}
