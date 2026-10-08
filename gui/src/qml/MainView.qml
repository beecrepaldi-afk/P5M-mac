import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "p5m"

// Home: "Play". Categories on the left (like P5M on the Quest), consoles on
// the right. Everything is reachable with the D-pad; the face buttons are
// shortcuts, shown on the focused console.
Pane {
    id: consolePane
    padding: 0
    background: Item {}

    StackView.onActivated: {
        hostsView.forceActiveFocus(Qt.TabFocusReason);
        if(!Chiaki.autoConnect && !root.initialAsk && !Chiaki.window.directStream)
        {
            root.initialAsk = true;
            if(Chiaki.settings.addSteamShortcutAsk && (typeof Chiaki.createSteamShortcut === "function"))
                root.showRemindDialog(qsTr("Official Steam artwork + controller layout"), qsTr("Would you like to either create a new non-Steam game for chiaki-ng\nor update an existing non-Steam game with the official artwork and controller layout?") + "\n\n" + qsTr("(Note: If you select no now and want to do this later, click the button or press R3 from the main menu.)"), false, () => root.showSteamShortcutDialog(true));
            else if(Chiaki.settings.remotePlayAsk)
            {
                if(!Chiaki.settings.psnRefreshToken || !Chiaki.settings.psnAuthToken || !Chiaki.settings.psnAuthTokenExpiry || !Chiaki.settings.psnAccountId)
                    root.showRemindDialog(qsTr("Remote Play via PSN"), qsTr("Would you like to connect to PSN?\nThis enables:\n- Automatic registration\n- Playing outside of your home network without port forwarding?") + "\n\n" + qsTr("(Note: If you select no now and want to do this later, go to the Config section of the settings.)"), true, () => root.showPSNTokenDialog(false));
                else
                    Chiaki.settings.remotePlayAsk = false;
            }
        }
    }

    function confirmQuit() {
        root.showConfirmDialog(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit());
    }

    Keys.onMenuPressed: root.showSettingsDialog()

    Shortcut {
        sequence: "Ctrl+,"
        onActivated: root.showSettingsDialog()
    }
    Keys.onYesPressed: if (hostsView.currentItem) hostsView.currentItem.wakeUpHost()
    Keys.onNoPressed: if (hostsView.currentItem) hostsView.currentItem.deleteHost()
    Keys.onEscapePressed: confirmQuit()
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            if (hostsView.currentItem && hostsView.currentItem.registered) hostsView.currentItem.setConsolePin();
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            if (Chiaki.settings.psnAuthToken) Chiaki.refreshPsnToken();
            event.accepted = true;
            break;
        case Qt.Key_F1:
            if (typeof Chiaki.createSteamShortcut === "function") root.showSteamShortcutDialog(false);
            event.accepted = true;
            break;
        case Qt.Key_F2:
            root.showManualHostDialog();
            event.accepted = true;
            break;
        }
    }

    ColumnLayout {
        anchors {
            fill: parent
            leftMargin: Theme.gutter
            rightMargin: Theme.gutter
            topMargin: 20
            bottomMargin: 16
        }
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 18
            BrandHeader { screen: qsTr("Play") }
            Item { Layout.fillWidth: true }
            Text {
                text: Qt.application.version
                color: Theme.textMuted
                font.pixelSize: Theme.hintSize
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 28

            // Categories. Play is this screen; the rest open Settings there.
            ColumnLayout {
                id: nav
                Layout.preferredWidth: 230
                Layout.fillHeight: true
                spacing: 8

                GlassButton {
                    id: navPlay
                    Layout.fillWidth: true
                    text: qsTr("Play")
                    selected: true
                    onClicked: hostsView.forceActiveFocus(Qt.TabFocusReason)
                    KeyNavigation.down: navScreen
                    KeyNavigation.right: hostsView
                }
                GlassButton {
                    id: navScreen
                    Layout.fillWidth: true
                    text: qsTr("Screen")
                    onClicked: root.showSettingsDialog("screen")
                    KeyNavigation.up: navPlay
                    KeyNavigation.down: navStream
                    KeyNavigation.right: hostsView
                }
                GlassButton {
                    id: navStream
                    Layout.fillWidth: true
                    text: qsTr("Stream")
                    onClicked: root.showSettingsDialog("stream")
                    KeyNavigation.up: navScreen
                    KeyNavigation.down: navController
                    KeyNavigation.right: hostsView
                }
                GlassButton {
                    id: navController
                    Layout.fillWidth: true
                    text: qsTr("Controller")
                    onClicked: root.showSettingsDialog("controller")
                    KeyNavigation.up: navStream
                    KeyNavigation.down: navGeneral
                    KeyNavigation.right: hostsView
                }
                GlassButton {
                    id: navGeneral
                    Layout.fillWidth: true
                    text: qsTr("General")
                    glyph: "OPTIONS"
                    onClicked: root.showSettingsDialog("general")
                    KeyNavigation.up: navController
                    KeyNavigation.down: navQuit
                    KeyNavigation.right: hostsView
                }
                Item { Layout.fillHeight: true }
                GlassButton {
                    id: navQuit
                    Layout.fillWidth: true
                    text: qsTr("Quit")
                    glyph: "circle"
                    onClicked: consolePane.confirmQuit()
                    KeyNavigation.up: navGeneral
                    KeyNavigation.right: hostsView
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Text {
                    text: qsTr("Let's play")
                    color: Theme.text
                    font.pixelSize: Theme.titleSize
                    font.weight: Font.Light
                }
                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    Layout.bottomMargin: 16
                    text: hostsView.visibleCount
                        ? qsTr("Pick a console and press ✕. A PS5 in rest mode wakes up on its own.")
                        : qsTr("Looking for consoles on your network… Your PS5 must be on or in rest mode, on the same network as this Mac.")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.bodySize
                    wrapMode: Text.WordWrap
                }

                ListView {
                    id: hostsView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 10
                    focus: true
                    keyNavigationWraps: false
                    model: Chiaki.hosts
                    readonly property int visibleCount: {
                        let n = 0;
                        for (let i = 0; i < count; ++i)
                            if (model[i] && model[i].display)
                                n++;
                        return n;
                    }

                    function step(delta) {
                        let i = currentIndex;
                        for (let n = 0; n < count; ++n) {
                            i += delta;
                            if (i < 0 || i >= count)
                                return false;
                            if (model[i] && model[i].display) {
                                currentIndex = i;
                                return true;
                            }
                        }
                        return false;
                    }

                    onCountChanged: {
                        if (currentItem && currentItem.visible)
                            return;
                        currentIndex = -1;
                        step(1);
                    }

                    Keys.onUpPressed: step(-1)
                    Keys.onDownPressed: {
                        if (!step(1))
                            addButton.forceActiveFocus(Qt.TabFocusReason);
                    }
                    Keys.onLeftPressed: navPlay.forceActiveFocus(Qt.TabFocusReason)
                    Keys.onReturnPressed: if (currentItem) currentItem.connectToHost()

                    delegate: Item {
                        id: delegate
                        visible: modelData.display
                        width: ListView.view ? ListView.view.width : 0
                        height: modelData.display ? card.implicitHeight : 0
                        readonly property bool focused: ListView.isCurrentItem && hostsView.activeFocus
                        readonly property bool registered: modelData.registered
                        readonly property bool remote: modelData.duid && !modelData.discovered
                        readonly property bool canWake: modelData.registered && !modelData.duid && !modelData.discovered
                        readonly property bool canRemove: modelData.manual || (modelData.discovered && !modelData.registered)

                        function connectToHost() {
                            if(modelData.discovered)
                                Chiaki.connectToHost(index, modelData.name);
                            else
                                Chiaki.connectToHost(index);
                        }

                        function wakeUpHost() {
                            if(canWake)
                                Chiaki.wakeUpHost(index);
                        }

                        function deleteHost() {
                            if (modelData.manual)
                                root.showConfirmDialog(qsTr("Delete Console"), qsTr("Are you sure you want to delete this console?"), () => {Chiaki.deleteHost(index)});
                            else if (modelData.discovered && !modelData.registered)
                                root.showConfirmDialog(qsTr("Hide Console"), qsTr("Are you sure you want to hide this console?") + "\n\n" + qsTr("Note: You can unhide from the Consoles section of the Settings under Hidden Consoles"), () => Chiaki.hideHost(modelData.mac, modelData.name));
                        }

                        function setConsolePin() {
                            root.showConsolePinDialog(index);
                        }

                        Glass {
                            id: card
                            anchors.fill: parent
                            implicitHeight: cardRow.implicitHeight + 28
                            level: delegate.focused ? 2 : 1
                            FocusFrame { shown: delegate.focused }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    hostsView.currentIndex = index;
                                    hostsView.forceActiveFocus(Qt.MouseFocusReason);
                                    delegate.connectToHost();
                                }
                            }

                            RowLayout {
                                id: cardRow
                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 18
                                    rightMargin: 18
                                }
                                spacing: 20

                                Image {
                                    Layout.preferredWidth: 84
                                    Layout.preferredHeight: 84
                                    fillMode: Image.PreserveAspectFit
                                    source: "image://svg/console-ps" + (modelData.ps5 ? "5" : "4") + (modelData.state == "standby" ? "#light_standby" : "#light_on")
                                    sourceSize: Qt.size(width, height)
                                    opacity: modelData.state == "unknown" && !delegate.remote ? 0.5 : 1.0
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name || modelData.address
                                        color: Theme.text
                                        font.pixelSize: 20
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                    }
                                    RowLayout {
                                        spacing: 8
                                        Rectangle {
                                            implicitWidth: 9
                                            implicitHeight: 9
                                            radius: 4.5
                                            color: statusText.color
                                        }
                                        Text {
                                            id: statusText
                                            text: {
                                                if (delegate.remote)
                                                    return qsTr("Remote, through PSN");
                                                if (!modelData.registered)
                                                    return modelData.duid ? qsTr("Not registered yet: press ✕ to register automatically")
                                                                          : qsTr("Not registered yet: press ✕ to register");
                                                if (modelData.state == "ready")
                                                    return qsTr("Ready");
                                                if (modelData.state == "standby")
                                                    return qsTr("Rest mode");
                                                return qsTr("Not found on the network");
                                            }
                                            color: {
                                                if (delegate.remote)
                                                    return Theme.active;
                                                if (!modelData.registered)
                                                    return Theme.warning;
                                                if (modelData.state == "ready")
                                                    return Theme.good;
                                                if (modelData.state == "standby")
                                                    return Theme.fair;
                                                return Theme.textMuted;
                                            }
                                            font.pixelSize: Theme.bodySize
                                        }
                                    }
                                    Text {
                                        visible: text
                                        text: modelData.discovered && modelData.app ? qsTr("Playing %1").arg(modelData.app) : ""
                                        color: Theme.textSecondary
                                        font.pixelSize: Theme.bodySize
                                    }
                                    // Technical details only on the focused card.
                                    Text {
                                        visible: delegate.focused && text
                                        text: {
                                            let parts = [];
                                            if (modelData.address && modelData.address !== modelData.name)
                                                parts.push(Chiaki.settings.streamerMode ? qsTr("address hidden") : modelData.address);
                                            parts.push(modelData.ps5 ? "PS5" : "PS4");
                                            if (modelData.manual)
                                                parts.push(qsTr("added by hand"));
                                            return parts.join("  ·  ");
                                        }
                                        color: Theme.textMuted
                                        font.pixelSize: Theme.hintSize
                                    }
                                }

                                // What the face buttons do here.
                                ColumnLayout {
                                    visible: delegate.focused
                                    spacing: 6
                                    Hint {
                                        button: "cross"
                                        key: "Return"
                                        controller: Chiaki.controllers.length > 0
                                        text: modelData.registered || delegate.remote ? qsTr("Play") : qsTr("Register")
                                    }
                                    Hint {
                                        visible: delegate.canWake
                                        button: "triangle"
                                        controller: Chiaki.controllers.length > 0
                                        text: qsTr("Wake up")
                                    }
                                    Hint {
                                        visible: delegate.canRemove
                                        button: "square"
                                        controller: Chiaki.controllers.length > 0
                                        text: modelData.manual ? qsTr("Delete") : qsTr("Hide")
                                    }
                                    Hint {
                                        visible: modelData.registered
                                        button: "L1"
                                        controller: Chiaki.controllers.length > 0
                                        text: qsTr("Console PIN")
                                    }
                                }
                            }
                        }
                    }
                }

                // Console actions, all reachable from the list with Down.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    spacing: 10

                    GlassButton {
                        id: addButton
                        text: qsTr("Add console by address")
                        glyph: "R3"
                        onClicked: root.showManualHostDialog()
                        KeyNavigation.up: hostsView
                        KeyNavigation.left: navPlay
                        KeyNavigation.right: psnButton.visible ? psnButton : discoveryButton
                    }
                    GlassButton {
                        id: psnButton
                        visible: Chiaki.settings.psnAuthToken
                        text: qsTr("Refresh PSN consoles")
                        glyph: "R1"
                        onClicked: Chiaki.refreshPsnToken()
                        KeyNavigation.up: hostsView
                        KeyNavigation.left: addButton
                        KeyNavigation.right: discoveryButton
                    }
                    GlassButton {
                        id: discoveryButton
                        text: qsTr("Search the network")
                        value: Chiaki.discoveryEnabled ? qsTr("On") : qsTr("Off")
                        valueColor: Chiaki.discoveryEnabled ? Theme.active : Theme.textSecondary
                        onClicked: Chiaki.discoveryEnabled = !Chiaki.discoveryEnabled
                        KeyNavigation.up: hostsView
                        KeyNavigation.left: psnButton.visible ? psnButton : addButton
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        HintBar {
            Layout.topMargin: 14
            hints: [
                { button: "cross", key: "Return", text: qsTr("Select") },
                { button: "circle", key: "Esc", text: qsTr("Quit") },
                { button: "OPTIONS", key: "⌘,", text: qsTr("Settings") },
                { button: Chiaki.settings.stringForStreamMenuShortcut() || "R1+L3+R3", key: "⌘O", text: qsTr("Menu while playing") },
            ]
        }
    }
}
