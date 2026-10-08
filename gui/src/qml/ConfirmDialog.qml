import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import "controls" as C
import "p5m"

Dialog {
    id: dialog
    property alias text: label.text
    property var callback
    property var rejectCallback
    property bool newDialogOpen: false
    property Item restoreFocusItem
    parent: Overlay.overlay
    x: Math.round((root.width - width) / 2)
    y: Math.round((root.height - height) / 2)
    modal: true
    Material.roundedScale: Material.MediumScale
    padding: 28
    background: Rectangle {
        radius: 30
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 60 / 255)
        gradient: Gradient {
            GradientStop { position: 0; color: Theme.panelTop }
            GradientStop { position: 1; color: Theme.panelBottom }
        }
    }
    onOpened: label.forceActiveFocus(Qt.TabFocusReason)
    onAccepted: {
        newDialogOpen = true;
        restoreFocus();
        callback();
    }
    onClosed: if(!newDialogOpen) { restoreFocus() }

    onRejected: {
        if(rejectCallback)
        {
            newDialogOpen = true;
            restoreFocus();
            rejectCallback();
        }
    }

    function restoreFocus() {
        if (restoreFocusItem)
            restoreFocusItem.forceActiveFocus(Qt.TabFocusReason);
        label.focus = false;
    }

    Component.onCompleted: {
        header.horizontalAlignment = Text.AlignHCenter;
        // Qt 6.6: Workaround dialog background becoming immediately transparent during close animation
        header.background = null;
    }

    ColumnLayout {
        spacing: 20

        Label {
            id: label
            Keys.onEscapePressed: dialog.reject()
            Keys.onReturnPressed: dialog.accept()
        }

        // Cross answers yes, Circle no (the label holds the focus).
        RowLayout {
            Layout.alignment: Qt.AlignCenter
            spacing: 16

            PrimaryButton {
                id: yesButton
                text: qsTr("Yes")
                focusPolicy: Qt.NoFocus
                font.pixelSize: Theme.itemSize
                onClicked: dialog.accept()
                contentItem: Row {
                    spacing: 10
                    Glyph { anchors.verticalCenter: parent.verticalCenter; button: "cross"; size: 22 }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Yes")
                        color: yesButton.hovered ? "#000000" : Theme.text
                        font.pixelSize: Theme.itemSize
                        font.weight: Font.Medium
                    }
                }
            }

            GlassButton {
                text: qsTr("No")
                glyph: "circle"
                focusPolicy: Qt.NoFocus
                implicitWidth: 160
                onClicked: dialog.reject()
            }
        }
    }
}
