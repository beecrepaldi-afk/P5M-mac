import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C
import "p5m"

// Connecting the PlayStation account (play away from home), as a guided
// three-step flow: sign in on Sony's page in the browser, copy the address it
// lands on, come back. The copied address is picked up from the clipboard on
// its own when the app comes back to the front; pasting by hand still works.
DialogView {
    id: dialog
    property var psnurl
    property var expired
    // idle, working, done, failed
    property string status: "idle"
    property string statusText: ""
    property bool signInOpened: false

    title: expired ? qsTr("Reconnect to PSN") : qsTr("Play away from home")
    buttonVisible: false
    initialFocusItem: openButton

    StackView.onActivated: Chiaki.settings.remotePlayAsk = true

    function openSignIn() {
        psnurl = Chiaki.openPsnLink();
        signInOpened = true;
        status = "idle";
        statusText = "";
    }

    function copySignInLink() {
        if (!psnurl)
            psnurl = Chiaki.openPsnLink();
        linkCopy.text = psnurl;
        linkCopy.selectAll();
        linkCopy.copy();
        signInOpened = true;
        statusText = qsTr("Sign-in link copied: paste it into any browser.");
    }

    // Looks at the clipboard; true when it holds Sony's final address.
    function takeFromClipboard() {
        probe.text = "";
        probe.paste();
        const text = probe.text.trim();
        if (!Chiaki.checkPsnRedirectURL(text))
            return false;
        urlField.text = text;
        return true;
    }

    function connect() {
        const text = urlField.text.trim();
        if (!text || status === "working")
            return;
        status = "working";
        statusText = qsTr("Connecting to PlayStation Network…");
        Chiaki.initPsnAuth(text, function(msg, ok, done) {
            const clean = msg.replace(/^\[[A-Z]\]\s*/, "");
            if (!done) {
                statusText = clean;
                return;
            }
            if (ok) {
                Chiaki.settings.remotePlayAsk = false;
                status = "done";
                statusText = "";
                doneButton.forceActiveFocus(Qt.TabFocusReason);
            } else {
                status = "failed";
                statusText = clean;
                retryButton.forceActiveFocus(Qt.TabFocusReason);
            }
        });
    }

    Item {
        Connections {
            target: Qt.application
            function onStateChanged() {
                if (Qt.application.state !== Qt.ApplicationActive || !dialog.signInOpened || dialog.status !== "idle")
                    return;
                if (dialog.takeFromClipboard()) {
                    dialog.statusText = qsTr("Found the address you copied.");
                    dialog.connect();
                }
            }
        }

        // Helpers for the clipboard (never shown).
        TextField { id: probe; visible: false }
        TextField { id: linkCopy; visible: false }

        Flickable {
            anchors {
                fill: parent
                leftMargin: Theme.gutter
                rightMargin: Theme.gutter
            }
            contentHeight: column.implicitHeight + 40
            clip: true

            ColumnLayout {
                id: column
                width: Math.min(parent.width, 860)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 14

                Text {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 6
                    wrapMode: Text.WordWrap
                    color: Theme.textSecondary
                    font.pixelSize: Theme.bodySize + 1
                    text: qsTr("Connect your PlayStation account once and play your PS5 from anywhere. At home, leave the PS5 in rest mode with \"Stay connected to the internet\" turned on.")
                }

                // 1. Sign in
                Glass {
                    Layout.fillWidth: true
                    implicitHeight: step1.implicitHeight + 36
                    level: dialog.signInOpened ? 0 : 1
                    ColumnLayout {
                        id: step1
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 18
                        }
                        spacing: 8
                        SectionLabel { text: qsTr("Step 1"); topPadding: 0; bottomPadding: 0 }
                        Text {
                            text: qsTr("Sign in to PlayStation")
                            color: Theme.text
                            font.pixelSize: 20
                            font.weight: Font.Medium
                        }
                        Text {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: Theme.textSecondary
                            font.pixelSize: Theme.bodySize
                            text: qsTr("Sony's sign-in page opens in your browser. Use the account that owns the PS5.")
                        }
                        RowLayout {
                            Layout.topMargin: 6
                            spacing: 12
                            PrimaryButton {
                                id: openButton
                                text: dialog.signInOpened ? qsTr("Open again") : qsTr("Open sign-in page")
                                onClicked: dialog.openSignIn()
                                KeyNavigation.right: copyButton
                                KeyNavigation.down: urlField
                            }
                            GlassButton {
                                id: copyButton
                                text: qsTr("Copy the link instead")
                                onClicked: dialog.copySignInLink()
                                KeyNavigation.left: openButton
                                KeyNavigation.down: urlField
                            }
                        }
                    }
                }

                // 2. Copy the final address
                Glass {
                    Layout.fillWidth: true
                    implicitHeight: step2.implicitHeight + 36
                    level: 1
                    ColumnLayout {
                        id: step2
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 18
                        }
                        spacing: 8
                        SectionLabel { text: qsTr("Step 2"); topPadding: 0; bottomPadding: 0 }
                        Text {
                            text: qsTr("Copy the address of the last page")
                            color: Theme.text
                            font.pixelSize: 20
                            font.weight: Font.Medium
                        }
                        Text {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: Theme.textSecondary
                            font.pixelSize: Theme.bodySize
                            text: qsTr("After you sign in, the browser lands on a page that may look blank or show an error. That is expected. Copy the whole address from the address bar: ⌘L, then ⌘C.")
                        }
                    }
                }

                // 3. Back here
                Glass {
                    Layout.fillWidth: true
                    implicitHeight: step3.implicitHeight + 36
                    level: dialog.signInOpened ? 2 : 1
                    ColumnLayout {
                        id: step3
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 18
                        }
                        spacing: 8
                        SectionLabel { text: qsTr("Step 3"); topPadding: 0; bottomPadding: 0 }
                        Text {
                            text: qsTr("Come back to P5M")
                            color: Theme.text
                            font.pixelSize: 20
                            font.weight: Font.Medium
                        }
                        Text {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: Theme.textSecondary
                            font.pixelSize: Theme.bodySize
                            text: qsTr("P5M picks up the copied address by itself. If it does not, paste it here.")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            spacing: 12
                            C.TextField {
                                id: urlField
                                Layout.fillWidth: true
                                placeholderText: qsTr("https://remoteplay.dl.playstation.net/…")
                                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                                KeyNavigation.up: openButton
                                KeyNavigation.right: pasteButton
                                onAccepted: dialog.connect()
                            }
                            GlassButton {
                                id: pasteButton
                                text: qsTr("Paste")
                                onClicked: {
                                    // The field only edits after Cross/click.
                                    const readOnly = urlField.readOnly;
                                    urlField.readOnly = false;
                                    urlField.text = "";
                                    urlField.paste();
                                    urlField.readOnly = readOnly;
                                }
                                KeyNavigation.left: urlField
                                KeyNavigation.right: connectButton
                                KeyNavigation.up: openButton
                            }
                            PrimaryButton {
                                id: connectButton
                                text: qsTr("Connect")
                                enabled: urlField.text.trim() && dialog.status !== "working"
                                opacity: enabled ? 1 : 0.45
                                onClicked: dialog.connect()
                                KeyNavigation.left: pasteButton
                                KeyNavigation.up: openButton
                            }
                        }
                    }
                }

                // What is happening.
                Rectangle {
                    Layout.fillWidth: true
                    visible: dialog.status !== "idle" || dialog.statusText
                    implicitHeight: statusColumn.implicitHeight + 32
                    radius: Theme.radius
                    color: dialog.status === "failed" ? Theme.errorBg
                         : dialog.status === "done" ? Qt.rgba(95 / 255, 211 / 255, 141 / 255, 0.18)
                         : Theme.highlightBg
                    ColumnLayout {
                        id: statusColumn
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 16
                        }
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            BusyIndicator {
                                visible: dialog.status === "working"
                                running: visible
                                implicitWidth: 28
                                implicitHeight: 28
                            }
                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: dialog.status === "failed" ? Theme.error : dialog.status === "done" ? Theme.good : Theme.text
                                font.pixelSize: Theme.itemSize
                                font.weight: Font.Medium
                                text: dialog.status === "done"
                                    ? qsTr("All set! Your PS5 now shows on the home screen as \"Remote, through PSN\".")
                                    : dialog.status === "failed" ? qsTr("That did not work")
                                    : dialog.statusText
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: dialog.status === "failed"
                            wrapMode: Text.WordWrap
                            color: Theme.textSecondary
                            font.pixelSize: Theme.bodySize
                            text: dialog.statusText + "\n" + qsTr("Open the sign-in page again and copy the address right after signing in: it is only valid for a few minutes.")
                        }
                        PrimaryButton {
                            id: doneButton
                            visible: dialog.status === "done"
                            text: qsTr("Back to consoles")
                            onClicked: root.showMainView()
                        }
                        PrimaryButton {
                            id: retryButton
                            visible: dialog.status === "failed"
                            text: qsTr("Start again")
                            onClicked: {
                                dialog.status = "idle";
                                dialog.statusText = "";
                                urlField.text = "";
                                dialog.openSignIn();
                            }
                        }
                    }
                }
            }
        }
    }
}
