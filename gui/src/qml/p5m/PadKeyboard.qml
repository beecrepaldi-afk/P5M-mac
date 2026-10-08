import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// On-screen keyboard for the controller. D-pad moves, Cross types,
// Square deletes, Triangle switches case, Options (or Done) finishes,
// Circle closes.
Popup {
    id: kb
    property Item field: null
    property bool upper: false
    property int row: 1
    property int col: 0
    readonly property var rows: [
        "1234567890",
        "qwertyuiop",
        "asdfghjkl@",
        "zxcvbnm.-_",
    ]
    readonly property var bottom: [
        { id: "shift", label: "⇧" },
        { id: "space", label: qsTr("Space") },
        { id: "back", label: "⌫" },
        { id: "done", label: qsTr("Done") },
    ]
    readonly property int rowCount: rows.length + 1
    function rowLength(r) { return r < rows.length ? rows[r].length : bottom.length }
    function charAt(r, c) {
        const ch = rows[r][c];
        return upper ? ch.toUpperCase() : ch;
    }

    function openFor(item) {
        field = item;
        row = 1;
        col = 0;
        upper = false;
        open();
    }
    function type(text) {
        if (!field)
            return;
        if (field.maximumLength > 0 && field.text.length >= field.maximumLength)
            return;
        const readOnly = field.readOnly;
        field.readOnly = false;
        field.insert(field.cursorPosition, text);
        field.readOnly = readOnly;
    }
    function backspace() {
        if (!field || field.cursorPosition <= 0)
            return;
        const readOnly = field.readOnly;
        field.readOnly = false;
        field.remove(field.cursorPosition - 1, field.cursorPosition);
        field.readOnly = readOnly;
    }
    function finish() {
        close();
        if (field)
            field.editingFinished();
    }
    function press() {
        if (row < rows.length) {
            type(charAt(row, col));
            return;
        }
        switch (bottom[col].id) {
        case "shift": upper = !upper; break;
        case "space": type(" "); break;
        case "back": backspace(); break;
        case "done": finish(); break;
        }
    }

    parent: Overlay.overlay
    modal: true
    focus: true
    x: Math.round((parent.width - width) / 2)
    y: Math.round(parent.height - height - 30)
    padding: 22
    closePolicy: Popup.NoAutoClose
    onClosed: if (field) field.forceActiveFocus(Qt.TabFocusReason)

    background: Rectangle {
        radius: 30
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 60 / 255)
        gradient: Gradient {
            GradientStop { position: 0; color: Theme.panelTop }
            GradientStop { position: 1; color: Theme.panelBottom }
        }
    }

    contentItem: FocusScope {
        focus: true
        implicitWidth: keysColumn.implicitWidth
        implicitHeight: keysColumn.implicitHeight
        Keys.onUpPressed: { kb.row = Math.max(0, kb.row - 1); kb.col = Math.min(kb.col, kb.rowLength(kb.row) - 1) }
        Keys.onDownPressed: { kb.row = Math.min(kb.rowCount - 1, kb.row + 1); kb.col = Math.min(kb.col, kb.rowLength(kb.row) - 1) }
        Keys.onLeftPressed: kb.col = (kb.col + kb.rowLength(kb.row) - 1) % kb.rowLength(kb.row)
        Keys.onRightPressed: kb.col = (kb.col + 1) % kb.rowLength(kb.row)
        Keys.onReturnPressed: kb.press()
        Keys.onEnterPressed: kb.press()
        Keys.onNoPressed: kb.backspace()
        Keys.onYesPressed: kb.upper = !kb.upper
        Keys.onMenuPressed: kb.finish()
        Keys.onEscapePressed: kb.finish()
        // A real keyboard still types.
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Backspace) {
                kb.backspace();
                event.accepted = true;
            } else if (event.text.length === 1 && event.text >= " " && !event.modifiers) {
                kb.type(event.text);
                event.accepted = true;
            }
        }

        ColumnLayout {
            id: keysColumn
            spacing: 10

            // What is being typed.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 52
                radius: 14
                color: Qt.rgba(1, 1, 1, 0.08)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.2)
                Text {
                    anchors {
                        fill: parent
                        leftMargin: 16
                        rightMargin: 16
                    }
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideLeft
                    text: kb.field ? (kb.field.echoMode === TextInput.Normal ? kb.field.text : "•".repeat(kb.field.text.length)) + "▏" : ""
                    color: Theme.text
                    font.pixelSize: 22
                }
            }

            Repeater {
                model: kb.rows.length
                RowLayout {
                    required property int index
                    readonly property int r: index
                    spacing: 8
                    Repeater {
                        model: kb.rows[parent.r].length
                        Rectangle {
                            required property int index
                            readonly property bool current: kb.row === parent.r && kb.col === index
                            implicitWidth: 56
                            implicitHeight: 52
                            radius: 12
                            color: current ? "#FFFFFF" : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.18)
                            Text {
                                anchors.centerIn: parent
                                text: kb.charAt(parent.parent.r, parent.index)
                                color: parent.current ? "#000000" : Theme.text
                                font.pixelSize: 22
                                font.weight: Font.Medium
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { kb.row = parent.parent.r; kb.col = parent.index; kb.press() }
                            }
                        }
                    }
                }
            }

            RowLayout {
                spacing: 8
                Repeater {
                    model: kb.bottom
                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool current: kb.row === kb.rows.length && kb.col === index
                        Layout.fillWidth: modelData.id === "space"
                        implicitWidth: modelData.id === "space" ? 260 : 96
                        implicitHeight: 52
                        radius: 12
                        color: current ? "#FFFFFF" : modelData.id === "done" ? Theme.accent
                             : (modelData.id === "shift" && kb.upper) ? Theme.highlightBg : Qt.rgba(1, 1, 1, 0.1)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.18)
                        Text {
                            anchors.centerIn: parent
                            text: parent.modelData.label
                            color: parent.current ? "#000000" : Theme.text
                            font.pixelSize: 20
                            font.weight: Font.Medium
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: { kb.row = kb.rows.length; kb.col = parent.index; kb.press() }
                        }
                    }
                }
            }

            HintBar {
                Layout.topMargin: 4
                hints: [
                    { button: "cross", key: "", text: qsTr("Type") },
                    { button: "square", key: "", text: qsTr("Delete") },
                    { button: "triangle", key: "", text: qsTr("Shift") },
                    { button: "OPTIONS", key: "", text: qsTr("Done") },
                ]
            }
        }
    }
}
