import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import "p5m"

Item {
    id: dialog
    property alias header: headerLabel.text
    property alias title: brand.screen
    property alias buttonText: okButton.text
    property alias buttonEnabled: okButton.enabled
    property alias buttonVisible: okButton.visible
    property Item restoreFocusItem
    // Where focus lands when the dialog opens (default: first item).
    property Item initialFocusItem: null
    // Circle/Esc: return true when handled (e.g. leave a sub-page first).
    property var backHandler: null
    // Extra hints for the bottom bar, after Select / Back.
    property var extraHints: []
    default property Item mainItem: null

    signal accepted()
    signal rejected()

    function close() {
        root.closeDialog();
    }

    Keys.onEscapePressed: {
        if (backHandler && backHandler())
            return;
        close();
    }

    Keys.onMenuPressed: {
        if (okButton.enabled)
            okButton.clicked()
    }

    StackView.onDeactivating: {
        restoreFocusItem = Window.window.activeFocusItem;
    }

    StackView.onActivated: {
        if (!restoreFocusItem && initialFocusItem) {
            initialFocusItem.forceActiveFocus(Qt.TabFocusReason);
        } else if (!restoreFocusItem) {
            let item = mainItem.nextItemInFocusChain();
            if (item)
                item.forceActiveFocus(Qt.TabFocusReason);
        } else {
            restoreFocusItem.forceActiveFocus(Qt.TabFocusReason);
            restoreFocusItem = null;
        }
    }

    onMainItemChanged: {
        if (mainItem) {
            mainItem.parent = contentItem;
            mainItem.anchors.fill = contentItem;
        }
    }

    // P5M header: back, "P5M | Title", the confirm action on the right.
    Item {
        id: toolBar
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            leftMargin: Theme.gutter
            rightMargin: Theme.gutter
        }
        height: 80

        RowLayout {
            anchors.fill: parent
            spacing: 16

            Button {
                flat: true
                text: "❮"
                font.pixelSize: 26
                focusPolicy: Qt.NoFocus
                Material.roundedScale: Material.SmallScale
                onClicked: {
                    dialog.rejected();
                    dialog.close();
                }
            }

            BrandHeader {
                id: brand
            }

            Item { Layout.fillWidth: true }

            GlassButton {
                id: okButton
                focusPolicy: Qt.NoFocus
                glyph: "OPTIONS"
                // Lit when it can be used, so the confirm action stands out.
                selected: enabled
                onClicked: dialog.accepted()
            }
        }
    }

    // Kept for the dialogs that set it: a short note under the header.
    Text {
        id: headerLabel
        visible: false
    }
    Item {
        id: contentItem
        anchors {
            top: toolBar.bottom
            left: parent.left
            right: parent.right
            bottom: hintBar.top
        }
    }

    HintBar {
        id: hintBar
        anchors {
            left: parent.left
            bottom: parent.bottom
            leftMargin: Theme.gutter
            bottomMargin: 14
        }
        hints: [
            { button: "cross", key: "Return", text: qsTr("Select") },
            { button: "circle", key: "Esc", text: qsTr("Back") },
        ].concat(okButton.visible && okButton.text ? [{ button: "OPTIONS", key: "", text: okButton.text }] : [])
         .concat(dialog.extraHints)
    }
}
