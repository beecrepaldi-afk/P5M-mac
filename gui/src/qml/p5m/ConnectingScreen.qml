import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

// The P5M waiting panel, as on the Quest (AcordarConsole.kt): a floating
// navy panel over the backdrop with "P5M | <what>", a title, a status line
// with the seconds that went by and what comes next, a thin progress bar,
// and real buttons (Cancel; on failure Try again / Close with what to fix).
Item {
    id: screen
    property string section: qsTr("Connecting")
    property string title
    property string status
    property int stepCount: 0        // >0: the bar shows step progress
    property int step: 0
    property bool failed: false
    property string failText
    property bool cancelable: true
    property bool canRetry: false
    property bool showSeconds: true
    signal cancelRequested()
    signal retryRequested()
    signal closeRequested()

    property int seconds: 0
    function restartClock() { seconds = 0; clock.restart(); }
    Timer {
        id: clock
        interval: 1000
        repeat: true
        running: screen.visible && !screen.failed
        onTriggered: screen.seconds++
    }

    Backdrop {
        anchors.fill: parent
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * Theme.gutter, 600)
        height: body.implicitHeight + 56
        radius: Theme.radius + 6
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 70 / 255)
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(20 / 255, 34 / 255, 64 / 255, 240 / 255) }
            GradientStop { position: 1; color: Qt.rgba(5 / 255, 7 / 255, 13 / 255, 242 / 255) }
        }

        ColumnLayout {
            id: body
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                leftMargin: 32
                rightMargin: 32
                topMargin: 28
            }
            spacing: 0

            BrandHeader {
                screen: screen.section
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: 18
                wrapMode: Text.WordWrap
                text: screen.title
                color: Theme.text
                font.pixelSize: Theme.titleSize
                font.weight: Font.Light
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: 10
                wrapMode: Text.WordWrap
                color: screen.failed ? Theme.textSecondary : Theme.textSecondary
                font.pixelSize: Theme.bodySize + 1
                lineHeight: 1.15
                text: screen.failed ? screen.failText
                    : screen.status + (screen.showSeconds && screen.seconds > 2 ? qsTr(" · %1 s").arg(screen.seconds) : "")
            }

            // Thin progress bar: steps when known, a moving band otherwise.
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 18
                visible: !screen.failed
                implicitHeight: 6
                radius: 3
                color: Qt.rgba(1, 1, 1, 60 / 255)
                clip: true
                Rectangle {
                    visible: screen.stepCount > 0
                    height: parent.height
                    radius: 3
                    color: Theme.highlight
                    width: parent.width * Math.min(1, (screen.step + 0.5) / Math.max(1, screen.stepCount))
                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
                Rectangle {
                    id: band
                    visible: screen.stepCount === 0
                    height: parent.height
                    width: parent.width * 0.3
                    radius: 3
                    color: Theme.highlight
                    NumberAnimation on x {
                        running: band.visible && screen.visible
                        loops: Animation.Infinite
                        from: -band.width
                        to: band.parent.width
                        duration: 1400
                        easing.type: Easing.InOutSine
                    }
                }
            }

            RowLayout {
                Layout.topMargin: 24
                spacing: 12
                visible: screen.failed || screen.cancelable

                PrimaryButton {
                    id: retryButton
                    visible: screen.failed && screen.canRetry
                    text: qsTr("Try again")
                    onClicked: screen.retryRequested()
                    KeyNavigation.right: closeButton
                }
                GlassButton {
                    id: closeButton
                    visible: screen.failed
                    text: qsTr("Close")
                    glyph: "circle"
                    onClicked: screen.closeRequested()
                    KeyNavigation.left: retryButton
                }
                GlassButton {
                    id: cancelButton
                    visible: !screen.failed && screen.cancelable
                    text: qsTr("Cancel")
                    glyph: "circle"
                    onClicked: screen.cancelRequested()
                }
            }
        }
    }

    // Focus the button that matters (Cross acts on it, Circle cancels).
    function focusButton() {
        if (failed)
            (canRetry ? retryButton : closeButton).forceActiveFocus(Qt.TabFocusReason);
        else if (cancelable)
            cancelButton.forceActiveFocus(Qt.TabFocusReason);
    }
    onFailedChanged: Qt.callLater(focusButton)
    onCancelableChanged: Qt.callLater(focusButton)
    onVisibleChanged: if (visible) Qt.callLater(focusButton)
}
