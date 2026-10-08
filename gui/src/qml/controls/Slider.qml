import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

import "../p5m"

Slider {
    property bool firstInFocusChain: false
    property bool lastInFocusChain: false
    property bool sendOutput: false

    Keys.onPressed: (event) => {
        // Keys this control does not handle (Circle/Esc, L1/R1...) go on
        // to the dialog.
        event.accepted = false;
        switch (event.key) {
        case Qt.Key_Up:
            if (!firstInFocusChain) {
                let item = nextItemInFocusChain(false);
                if (item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                if(!sendOutput)
                    event.accepted = true;
            }
            break;
        case Qt.Key_Down:
            if (!lastInFocusChain) {
                let item = nextItemInFocusChain();
                if (item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                if(!sendOutput)
                    event.accepted = true;
            }
            break;
        }
    }

    // The P5M focus marker, same as everywhere else.
    FocusFrame {
        radius: 10
        shown: parent.visualFocus
    }
}
