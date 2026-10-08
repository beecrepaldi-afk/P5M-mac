import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "p5m"

// Connecting over PSN (or registering through it), in the P5M waiting panel:
// four steps on the bar, plain words for each, and a clear way out on errors.
Item {
    id: view
    property bool allowClose: false
    property bool cancelling: false
    property bool registOnly: false
    property list<Item> restoreFocusItems
    readonly property string consoleName: Chiaki.connectingConsole() || qsTr("your PS5")

    function stop() {
        if (!allowClose)
            return;
        allowClose = false;
        cancelling = true;
        panel.cancelable = false;
        panel.status = qsTr("Cancelling…");
        Chiaki.psnCancel(false);
    }

    function fail(title, text) {
        panel.title = title;
        panel.failText = text;
        panel.failed = true;
    }

    function grabInput(item) {
        Chiaki.window.grabInput();
        restoreFocusItems.push(Window.window.activeFocusItem);
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function releaseInput() {
        Chiaki.window.releaseInput();
        let item = restoreFocusItems.pop();
        if (item && item.visible)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    Keys.onEscapePressed: {
        if (panel.failed)
            root.showMainView();
        else
            view.stop();
    }

    ConnectingScreen {
        id: panel
        anchors.fill: parent
        section: view.registOnly ? qsTr("Register") : qsTr("Remote play")
        title: view.registOnly ? qsTr("Registering %1").arg(view.consoleName)
                               : qsTr("Connecting to %1").arg(view.consoleName)
        status: qsTr("Reaching PlayStation Network…")
        stepCount: 4
        step: 0
        cancelable: false
        onCancelRequested: view.stop()
        onCloseRequested: root.showMainView()
    }

    Timer {
        id: closeTimer
        interval: 1500
        running: true
        onTriggered: {
            view.allowClose = true;
            panel.cancelable = !view.cancelling && !panel.failed;
        }
    }

    Timer {
        id: doneTimer
        interval: 2000
        onTriggered: root.showMainView()
    }

    Dialog {
        id: sessionPinDialog
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        title: qsTr("Console login PIN")
        modal: true
        closePolicy: Popup.NoAutoClose
        standardButtons: Dialog.Ok | Dialog.Cancel
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
        onAboutToShow: {
            standardButton(Dialog.Ok).enabled = Qt.binding(function() {
                return pinField.acceptableInput;
            });
            view.grabInput(pinField);
        }
        onClosed: view.releaseInput()
        onAccepted: Chiaki.enterPin(pinField.text)
        onRejected: Chiaki.stopSession(false)
        Material.roundedScale: Material.MediumScale

        TextField {
            id: pinField
            echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
            implicitWidth: 200
            validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
            Keys.onReturnPressed: {
                if(sessionPinDialog.standardButton(Dialog.Ok).enabled)
                    sessionPinDialog.standardButton(Dialog.Ok).clicked()
            }
        }
    }

    Connections {
        target: Chiaki

        function onConnectStateChanged()
        {
            switch(Chiaki.connectState)
            {
                case Chiaki.PsnConnectState.WaitingForInternet:
                    panel.status = qsTr("Waiting for an internet connection…");
                    panel.step = 0;
                    break
                case Chiaki.PsnConnectState.InitiatingConnection:
                    panel.status = qsTr("Reaching PlayStation Network…");
                    panel.step = 0;
                    break
                case Chiaki.PsnConnectState.LinkingConsole:
                    panel.status = view.registOnly ? qsTr("Registering this Mac with the PS5…")
                                                   : qsTr("Linking with %1 through PSN…").arg(view.consoleName);
                    panel.step = 1;
                    view.allowClose = false;
                    panel.cancelable = false;
                    break
                case Chiaki.PsnConnectState.RegisteringConsole:
                    view.registOnly = true;
                    break
                case Chiaki.PsnConnectState.RegistrationFinished:
                    panel.status = qsTr("Registered. You can play now.");
                    panel.step = 4;
                    doneTimer.restart();
                    break
                case Chiaki.PsnConnectState.DataConnectionStart:
                    panel.status = qsTr("Opening the video connection. Away from home this can take a few seconds.");
                    panel.step = 2;
                    view.allowClose = true;
                    panel.cancelable = true;
                    break
                case Chiaki.PsnConnectState.DataConnectionFinished:
                    panel.status = qsTr("Starting the picture…");
                    panel.step = 3;
                    view.allowClose = false;
                    panel.cancelable = false;
                    break
                case Chiaki.PsnConnectState.ConnectFailed:
                    if(!view.cancelling)
                        view.fail(qsTr("Couldn't connect to %1").arg(view.consoleName),
                                  qsTr("The connection over PSN dropped. Check the internet here and try again."));
                    else
                        doneTimer.restart();
                    break
                case Chiaki.PsnConnectState.ConnectFailedStart:
                    if(!view.cancelling)
                        view.fail(qsTr("Couldn't reach %1").arg(view.consoleName),
                                  qsTr("PlayStation Network couldn't reach the PS5. It must be in rest mode with \"Stay Connected to the Internet\" turned on (Settings › System › Power Saving › Features Available in Rest Mode)."));
                    else
                        doneTimer.restart();
                    break
                case Chiaki.PsnConnectState.ConnectFailedConsoleUnreachable:
                    if(!view.cancelling)
                        view.fail(qsTr("This network blocks the connection"),
                                  qsTr("The PS5 answered through PSN, but this network doesn't let the direct connection through (common on hotel or work Wi-Fi). Try another network, or your phone's hotspot."));
                    else
                        doneTimer.restart();
                    break
            }
        }

        function onSessionChanged()
        {
            // Leave by ourselves only when nothing went wrong: an error stays
            // on screen until Close.
            if (!Chiaki.session && !panel.failed && !doneTimer.running)
                root.showMainView();
        }

        function onSessionError(title, text)
        {
            view.fail(title, text);
        }

        function onSessionPinDialogRequested()
        {
            if (sessionPinDialog.opened)
                return;
            sessionPinDialog.open();
        }
    }
}
