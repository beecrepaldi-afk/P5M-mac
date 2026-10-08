import QtQuick
import QtQuick.Controls

import org.streetpea.chiaking

import "p5m"

// Waking the console and waiting for it, in the P5M waiting panel (same
// words as the Quest app).
Item {
    id: view
    property bool allowClose: false
    readonly property string consoleName: Chiaki.connectingConsole() || qsTr("your PS5")

    function stop() {
        Chiaki.stopAutoConnect();
        root.showMainView();
    }

    function cancel() {
        if (!allowClose)
            return;
        allowClose = false;
        panel.cancelable = false;
        panel.status = qsTr("Cancelling…");
        failTimer.start();
    }

    Keys.onEscapePressed: {
        if (panel.failed)
            view.stop();
        else
            view.cancel();
    }

    ConnectingScreen {
        id: panel
        anchors.fill: parent
        section: qsTr("Wake up")
        title: qsTr("Waking up %1").arg(view.consoleName)
        status: qsTr("Waiting for it to answer. It connects on its own as soon as it is awake.")
        cancelable: false
        failText: qsTr("On the PS5, open Settings › System › Power Saving › Features Available in Rest Mode, and turn on \"Stay Connected to the Internet\" and \"Enable Turning On PS5 from Network\".")
        onCancelRequested: view.cancel()
        onCloseRequested: view.stop()
    }

    Timer {
        interval: 1500
        running: true
        onTriggered: {
            view.allowClose = true;
            panel.cancelable = true;
        }
    }

    Timer {
        id: failTimer
        interval: 1200
        onTriggered: view.stop()
    }

    Connections {
        target: Chiaki

        function onWakeupStartFailed() {
            panel.title = qsTr("%1 didn't wake up").arg(view.consoleName);
            panel.failed = true;
        }
    }
}
