import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.streetpea.chiaking

DialogView {
    id: dialog
    title: qsTr("Session diagnostics")
    buttonVisible: false
    initialFocusItem: refreshButton

    StackView.onActivated: {
        Chiaki.refreshSystemModelStatus();
        Chiaki.setSystemDiagnosticContext(true);
        refreshButton.forceActiveFocus(Qt.TabFocusReason);
    }
    StackView.onDeactivating: Chiaki.setSystemDiagnosticContext(false)
    Component.onDestruction: {
        Chiaki.setSystemDiagnosticContext(false);
        root.systemDiagnosticsOpen = false;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 16
        Label {
            Layout.fillWidth: true
            text: Chiaki.systemModelStatus
            wrapMode: Text.WordWrap
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("Apple Intelligence explains only the measured summary, on this Mac and after the session. Your account, console identifiers and diary are not sent to the model.")
            wrapMode: Text.WordWrap
            opacity: 0.75
        }
        RowLayout {
            spacing: 16
            Button {
                id: refreshButton
                text: qsTr("Check availability")
                onClicked: Chiaki.refreshSystemModelStatus()
            }
            Button {
                text: Chiaki.systemExplanationBusy ? qsTr("Explaining...") : qsTr("Explain last session")
                enabled: !Chiaki.session && Chiaki.hasSessionSummary && !Chiaki.systemExplanationBusy
                onClicked: Chiaki.explainLastSession()
            }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            Label {
                width: parent.width
                text: Chiaki.sessionSummary + (Chiaki.sessionExplanation.length ? "\n\n" + Chiaki.sessionExplanation : "")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
            }
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("In Shortcuts, add a P5M action: Wake Console, Connect to Console, Open Session Diagnostics or Mute Microphone. Give the shortcut a name to run it with Siri. Wake requires the console to be reachable on your local network.")
            wrapMode: Text.WordWrap
            opacity: 0.75
        }
    }
}
