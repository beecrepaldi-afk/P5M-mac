import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

import "../p5m"

ComboBox {
    property bool firstInFocusChain: false
    property bool lastInFocusChain: false
    implicitContentWidthPolicy: ComboBox.WidestText

    Keys.onPressed: (event) => {
        // Keys this control does not handle (Circle/Esc, L1/R1...) go on
        // to the dialog.
        event.accepted = false;
        switch (event.key) {
        case Qt.Key_Up:
            if (!popup.visible) {
                let item = nextItemInFocusChain(false);
                if (!firstInFocusChain && item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                event.accepted = true;
            }
            break;
        case Qt.Key_Down:
            if (!popup.visible) {
                let item = nextItemInFocusChain();
                if (!lastInFocusChain && item)
                    item.forceActiveFocus(Qt.TabFocusReason);
                event.accepted = true;
            }
            break;
        case Qt.Key_Return:
            if (popup.visible) {
                activated(highlightedIndex);
                popup.close();
            } else {
                popup.open();
            }
            event.accepted = true;
            break;
        }
    }

    Keys.onReleased: (event) => {
        if (event.key == Qt.Key_Return)
            event.accepted = true;
    }

    // The P5M focus marker, same as everywhere else.
    FocusFrame {
        radius: 10
        shown: parent.visualFocus
    }
}
