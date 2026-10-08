import QtQuick
import QtQuick.Controls

import org.streetpea.chiaking

import "p5m"

// P5M: the settings most people need, built for the controller like the Quest
// app's menu. Every option is the same kind of row in one list, so Up/Down
// always reach the next row (no hand-made focus chain to break): Left/Right
// or Cross change the value, Square steps back, Circle returns to the
// categories. The full dialog stays one row away ("Advanced options").
DialogView {
    id: dialog
    // Opened from a home category: "screen", "stream", "controller", "general".
    property string initialPage: ""
    title: qsTr("Settings")
    buttonVisible: false
    initialFocusItem: categoryList
    extraHints: [{ button: "square", key: "", text: qsTr("Previous value") },
                 { button: "L1/R1", key: "", text: qsTr("Category") }]
    backHandler: function() {
        if (categoryList.activeFocus)
            return false;
        categoryList.forceActiveFocus(Qt.TabFocusReason);
        return true;
    }

    readonly property var categoryKeys: ["screen", "stream", "controller", "general"]
    readonly property var categoryTitles: [qsTr("Screen"), qsTr("Stream"), qsTr("Controller"), qsTr("General")]
    Component.onCompleted: {
        const i = categoryKeys.indexOf(initialPage);
        categoryList.currentIndex = i >= 0 ? i : 0;
    }

    // The rows. kind "choice": options + get() (index) + set(index);
    // kind "link": action(). Optional shown() hides a row that does not apply.
    function wrap(index, count) {
        return ((index % count) + count) % count;
    }
    function rowsFor(category) {
        switch (category) {
        case "screen": return [
            { kind: "choice", label: qsTr("Vertical sync"),
              hint: qsTr("On: no tearing. Off: about one frame less latency, with tearing kept away from the middle of the screen."),
              options: [qsTr("Off"), qsTr("On")],
              get: () => Chiaki.settings.vSyncEnabled ? 1 : 0,
              set: (i) => {
                  Chiaki.settings.vSyncEnabled = i === 1;
                  if (Chiaki.window.runtimeRendererBackend === 1 && Chiaki.settings.restartApplication())
                      Qt.quit();
              } },
            { kind: "choice", label: qsTr("HDR (experimental)"),
              hint: qsTr("Experimental, not tested yet. Uses the display's available extended brightness. Displays without extra headroom use SDR tone mapping. On also asks the PS5 for HDR (H265 HDR codec). Menus keep their look, so nothing switches between menu and game."),
              shown: () => Qt.platform.os === "osx" && Chiaki.settings.rendererBackend === 2,
              options: [qsTr("Off"), qsTr("On")],
              get: () => Chiaki.settings.hdrOutput ? 1 : 0,
              set: (i) => {
                  const on = i === 1;
                  Chiaki.settings.hdrOutput = on;
                  // The PS5 sends HDR only with the HDR codec.
                  if (on) {
                      Chiaki.settings.codecLocalPS5 = 2;
                      Chiaki.settings.codecRemotePS5 = 2;
                  } else {
                      if (Chiaki.settings.codecLocalPS5 === 2)
                          Chiaki.settings.codecLocalPS5 = 1;
                      if (Chiaki.settings.codecRemotePS5 === 2)
                          Chiaki.settings.codecRemotePS5 = 1;
                  }
              } },
            { kind: "choice", label: qsTr("Stream stats"),
              hint: qsTr("Shows bitrate, latency and lost frames over the game."),
              options: [qsTr("Hidden"), qsTr("Shown")],
              get: () => Chiaki.settings.showStreamStats ? 1 : 0,
              set: (i) => Chiaki.settings.showStreamStats = i === 1 },
        ];
        case "stream": return [
            { kind: "choice", label: qsTr("Resolution at home"),
              hint: qsTr("PS5 on the same network. The bitrate is learned for each network on its own."),
              options: ["360p", "540p", "720p", "1080p"],
              get: () => Chiaki.settings.resolutionLocalPS5 - 1,
              set: (i) => { Chiaki.settings.resolutionLocalPS5 = i + 1; Chiaki.settings.bitrateLocalPS5 = 0; } },
            { kind: "choice", label: qsTr("Resolution away"),
              hint: qsTr("PS5 over the internet (PSN)."),
              options: ["360p", "540p", "720p", "1080p"],
              get: () => Chiaki.settings.resolutionRemotePS5 - 1,
              set: (i) => { Chiaki.settings.resolutionRemotePS5 = i + 1; Chiaki.settings.bitrateRemotePS5 = 0; } },
            { kind: "choice", label: qsTr("Spatial audio"),
              hint: qsTr("Ready for surround streams with a verified channel layout. Current PS5 streams support mono or stereo and play directly; surround reception is not verified yet. With compatible surround input, headphones and built-in speakers use Apple's spatial processing while HDMI keeps multichannel output. Changes apply to the next session."),
              shown: () => Qt.platform.os === "osx",
              options: [qsTr("Off"), qsTr("On")],
              get: () => Chiaki.settings.macSpatialAudio ? 1 : 0,
              set: (i) => Chiaki.settings.macSpatialAudio = i === 1 },
            { kind: "choice", label: qsTr("Head tracking"),
              hint: qsTr("Optional for compatible surround input, spatial audio and supported headphones. Current mono and stereo streams play directly without head tracking. If tracking is unavailable, surround playback stays fixed. Changes apply to the next session."),
              shown: () => Qt.platform.os === "osx",
              options: [qsTr("Off"), qsTr("On")],
              get: () => Chiaki.settings.macHeadTracking ? 1 : 0,
              set: (i) => Chiaki.settings.macHeadTracking = i === 1 },
        ];
        case "controller": return [
            { kind: "choice", label: qsTr("Haptics over Bluetooth"),
              hint: qsTr("Raw track: the console's real haptics, delayed by how slowly macOS sends them. Apple Core Haptics: instant, only strength and tone. Over USB the real haptics are always used."),
              shown: () => Qt.platform.os === "osx",
              options: [qsTr("Raw track"), qsTr("Apple Core Haptics"), qsTr("Rumble only")],
              get: () => Chiaki.settings.macBluetoothHaptics,
              set: (i) => Chiaki.settings.macBluetoothHaptics = i },
        ];
        case "general": return [
            { kind: "choice", label: qsTr("When the stream ends"),
              hint: qsTr("What happens to the PS5 when you leave the stream."),
              options: [qsTr("Leave it on"), qsTr("Rest mode"), qsTr("Ask")],
              get: () => Chiaki.settings.disconnectAction,
              set: (i) => Chiaki.settings.disconnectAction = i },
            { kind: "link", label: qsTr("Consoles"),
              hint: qsTr("Register a PS5 or manage the registered ones."),
              action: () => root.showAdvancedSettingsDialog("consoles") },
            { kind: "link", label: qsTr("Remote play (PSN)"),
              hint: qsTr("Sign in to PSN to play away from home."),
              action: () => root.showAdvancedSettingsDialog("remote") },
            { kind: "link", label: qsTr("Session diagnostics & Shortcuts"),
              shown: () => Qt.platform.os === "osx",
              hint: qsTr("Review the last session, request a local explanation and learn about Siri and Shortcuts actions."),
              action: () => root.showSystemDiagnostics() },
            { kind: "link", label: qsTr("Advanced options"),
              hint: qsTr("Every option, for tinkering: frame rate, codec and HDR, bitrate, window, renderer, audio, keyboard, profiles..."),
              action: () => root.showAdvancedSettingsDialog(dialog.categoryKeys[categoryList.currentIndex]) },
        ];
        }
        return [];
    }

    // Set when L1/R1 switch category from inside the rows: the new rows take
    // focus once they exist (the old ones are gone by then).
    property bool rowsWanted: false
    function focusRows() {
        if (rows.count === 0)
            return;
        if (rows.currentIndex < 0 || rows.currentIndex >= rows.count)
            rows.currentIndex = 0;
        rows.focusCurrent();
    }

    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            // L1/R1: previous/next category, staying in the rows if there.
            const inRows = !categoryList.activeFocus;
            const next = categoryList.currentIndex + (event.key === Qt.Key_PageUp ? -1 : 1);
            if (next >= 0 && next < categoryKeys.length) {
                dialog.rowsWanted = inRows;
                categoryList.currentIndex = next;
            }
            event.accepted = true;
        }
    }

    Item {
        ListView {
            id: categoryList
            anchors {
                top: parent.top
                left: parent.left
                bottom: parent.bottom
                leftMargin: Theme.gutter
                topMargin: 4
            }
            width: 260
            spacing: 8
            clip: true
            model: dialog.categoryTitles
            focus: true
            keyNavigationEnabled: true
            highlightFollowsCurrentItem: false
            onCurrentIndexChanged: rows.currentIndex = 0
            Keys.onRightPressed: dialog.focusRows()
            Keys.onReturnPressed: dialog.focusRows()
            delegate: GlassButton {
                required property string modelData
                required property int index
                width: ListView.view.width
                text: modelData
                focusPolicy: Qt.NoFocus
                selected: ListView.isCurrentItem
                FocusFrame {
                    anchors.fill: parent
                    shown: parent.ListView.isCurrentItem && categoryList.activeFocus
                }
                onClicked: {
                    categoryList.currentIndex = index;
                    dialog.focusRows();
                }
            }
        }

        // The rows: a plain column, focus moved only here (a ListView moves
        // focus on its own and fought this).
        Flickable {
            id: rows
            anchors {
                top: parent.top
                left: categoryList.right
                right: parent.right
                bottom: parent.bottom
                leftMargin: 24
                rightMargin: Theme.gutter
                topMargin: 4
                bottomMargin: 12
            }
            clip: true
            contentWidth: width
            contentHeight: column.height
            boundsBehavior: Flickable.StopAtBounds
            // Re-evaluated when a shown() condition changes.
            property var model: dialog.rowsFor(dialog.categoryKeys[categoryList.currentIndex])
                .filter(row => !row.shown || row.shown())
            property int currentIndex: 0
            readonly property int count: model.length

            function rowItem(i) {
                const box = repeater.itemAt(i);
                return box ? box.row : null;
            }
            function move(delta) {
                const next = currentIndex + delta;
                if (next < 0 || next >= count)
                    return;
                currentIndex = next;
                focusCurrent();
            }
            function focusCurrent() {
                const item = rowItem(currentIndex);
                if (!item)
                    return;
                item.forceActiveFocus(Qt.TabFocusReason);
                // Keep it in view.
                const box = repeater.itemAt(currentIndex);
                if (box.y < contentY)
                    contentY = box.y;
                else if (box.y + box.height > contentY + height)
                    contentY = box.y + box.height - height;
            }

            Column {
                id: column
                width: rows.width
                spacing: 8
                Text {
                    width: parent.width
                    visible: Qt.platform.os === "osx"
                        && dialog.categoryKeys[categoryList.currentIndex] === "stream"
                        && Chiaki.session !== null
                    text: Chiaki.session ? Chiaki.session.audioOutputStatus : ""
                    leftPadding: 18
                    rightPadding: 18
                    bottomPadding: 6
                    wrapMode: Text.WordWrap
                    color: Theme.highlight
                    font.pixelSize: Theme.itemSize - 1
                }
                Repeater {
                    id: repeater
                    model: rows.model
                    // The row, and under it what it does while it has focus
                    // (like the Quest menu).
                    delegate: Column {
                        id: rowBox
                        required property var modelData
                        required property int index
                        readonly property Item row: rowLoader.item
                        width: column.width
                        spacing: 6

                        Loader {
                            id: rowLoader
                            width: parent.width
                            sourceComponent: rowBox.modelData.kind === "link" ? linkRow : choiceRow
                            onLoaded: {
                                if (dialog.rowsWanted && rowBox.index === 0) {
                                    dialog.rowsWanted = false;
                                    item.forceActiveFocus(Qt.TabFocusReason);
                                }
                            }
                        }
                        Text {
                            width: parent.width
                            visible: rowBox.row !== null && rowBox.row.activeFocus && text !== ""
                            leftPadding: 18
                            rightPadding: 18
                            bottomPadding: 6
                            wrapMode: Text.WordWrap
                            text: rowBox.modelData.hint ?? ""
                            color: Theme.highlight
                            font.pixelSize: Theme.itemSize - 1
                        }

                        Component {
                            id: choiceRow
                            StepRow {
                                readonly property var row: rowBox.modelData
                                text: row.label
                                steps: row.options.length
                                position: row.get()
                                value: row.options[position] ?? ""
                                onStepped: (delta) => row.set(dialog.wrap(position + delta, row.options.length))
                                onActiveFocusChanged: if (activeFocus) rows.currentIndex = rowBox.index
                                Keys.onUpPressed: rows.move(-1)
                                Keys.onDownPressed: rows.move(1)
                            }
                        }
                        Component {
                            id: linkRow
                            GlassButton {
                                readonly property var row: rowBox.modelData
                                text: row.label
                                value: "›"
                                onActiveFocusChanged: if (activeFocus) rows.currentIndex = rowBox.index
                                Keys.onUpPressed: rows.move(-1)
                                Keys.onDownPressed: rows.move(1)
                                Keys.onRightPressed: clicked()
                                Keys.onLeftPressed: categoryList.forceActiveFocus(Qt.TabFocusReason)
                                onClicked: row.action()
                            }
                        }
                    }
                }
            }
        }
    }
}
