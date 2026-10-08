import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Window

import org.streetpea.chiaking

import "controls" as C
import "p5m"

Item {
    id: view

    readonly property var hostWindow: view.Window.window
    property bool sessionError: false
    property bool sessionLoading: true
    property list<Item> restoreFocusItems
    readonly property bool useSeparateMenuWindow: Chiaki.window.runtimeRendererBackend === 1
    readonly property int streamMenuHeight: 200
    readonly property bool streamStatsVisible: Chiaki.settings.showStreamStats && Chiaki.session && !(menuController.open || menuController.closing) && !sessionLoading && !sessionError && !(Chiaki.settings.audioVideoDisabled & 0x02)
    property int separateMenuX: 0
    property int separateMenuY: 0
    property int separateMenuWidth: 0
    property int separateStatsX: 0
    property int separateStatsY: 0
    property int separateStatsWidth: 0
    property int separateStatsHeight: 0
    property int separateDialogX: 0
    property int separateDialogY: 0
    property bool sessionStopDialogActive: false
    property bool sessionPinDialogActive: false

    function grabInput(item) {
        Chiaki.window.grabInput();
        restoreFocusItems.push(hostWindow ? hostWindow.activeFocusItem : null);
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function releaseInput() {
        Chiaki.window.releaseInput();
        let item = restoreFocusItems.pop();
        if (item && item.visible)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function updateSeparateMenuGeometry() {
        if (!hostWindow)
            return;
        const topLeft = view.mapToGlobal(0, 0);
        if (useSeparateMenuWindow) {
            separateMenuX = Math.round(topLeft.x);
            separateMenuY = Math.round(topLeft.y + view.height - streamMenuHeight);
            separateMenuWidth = Math.round(view.width);
            separateStatsX = Math.round(topLeft.x);
            separateStatsY = Math.round(topLeft.y);
            separateStatsWidth = Math.round(view.width);
            separateStatsHeight = Math.round(view.height);
        }
    }

    function updateSeparateDialogGeometry(width, height) {
        if (!useSeparateMenuWindow || !hostWindow)
            return;
        separateDialogX = Math.round(hostWindow.x + (hostWindow.width - width) / 2);
        separateDialogY = Math.round(hostWindow.y + (hostWindow.height - height) / 2);
    }

    function updateOverlayInteractionActive() {
        Chiaki.window.setOverlayInteractionActive(
            menuController.open ||
            menuController.closing ||
            sessionStopDialogActive ||
            separateSessionStopWindow.visible ||
            sessionPinDialogActive ||
            separateSessionPinWindow.visible
        );
    }

    StackView.onActivating: {
        Chiaki.window.keepVideo = true;
        sessionError = false;
        errorTitleLabel.text = "";
        errorTextLabel.text = "";
        sessionLoading = !(Chiaki.window.loadingTransitionComplete || (Chiaki.settings.audioVideoDisabled & 0x02));
    }
    StackView.onDeactivated: Chiaki.window.keepVideo = false

    Component.onCompleted: {
        updateSeparateMenuGeometry();
        updateOverlayInteractionActive();
        Chiaki.window.setStatsOverlayActive(streamStatsVisible);
    }
    onStreamStatsVisibleChanged: {
        if (Chiaki.window)
            Chiaki.window.setStatsOverlayActive(streamStatsVisible);
    }
    onWidthChanged: updateSeparateMenuGeometry()
    onHeightChanged: updateSeparateMenuGeometry()
    onUseSeparateMenuWindowChanged: updateSeparateMenuGeometry()

    Connections {
        target: view.hostWindow
        function onXChanged() { view.updateSeparateMenuGeometry() }
        function onYChanged() { view.updateSeparateMenuGeometry() }
        function onWidthChanged() { view.updateSeparateMenuGeometry() }
        function onHeightChanged() { view.updateSeparateMenuGeometry() }
        function onVisibilityChanged() { view.updateSeparateMenuGeometry() }
    }

    QtObject {
        id: menuController
        property bool closing: false
        property bool open: false

        property real lastToggleTime: 0
        function toggle() {
            var now = Date.now();
            if (now - lastToggleTime < 200)
                return;
            lastToggleTime = now;
            if (open)
                close();
            else {
                if (useSeparateMenuWindow) {
                    view.updateSeparateMenuGeometry();
                    view.grabInput(null);
                }
                open = true;
            }
            view.updateOverlayInteractionActive();
        }

        function close() {
            if (!open || closing)
                return;
            closing = true;
            open = false;
            view.releaseInput();
            view.updateOverlayInteractionActive();
        }
    }

    Rectangle {
        id: loadingView
        anchors.fill: parent
        color: "black"
        opacity: sessionError || sessionLoading || (Chiaki.settings.audioVideoDisabled & 0x02) ? 1.0 : 0.0
        visible: opacity

        Behavior on opacity { NumberAnimation { duration: 250 } }

        Item {
            anchors {
                top: parent.verticalCenter
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }

            // Anchor for the labels below (the P5M panel does the waiting).
            Item {
                id: spinner
                anchors.centerIn: parent
                width: 70
                height: width
            }

            Label {
                id: audioVideoDisabledTitleLabel
                anchors {
                    bottom: spinner.top
                    horizontalCenter: spinner.horizontalCenter
                }
                text: (Chiaki.settings.audioVideoDisabled & 0x01) ? qsTr("Audio and Video Disabled") : qsTr("Video Disabled")
                font.pixelSize: 24
                visible: !sessionLoading && !sessionError && (Chiaki.settings.audioVideoDisabled & 0x02)
            }

            Label {
                id: audioVideoDisabledTextLabel
                anchors {
                    top: audioVideoDisabledTitleLabel.bottom
                    horizontalCenter: audioVideoDisabledTitleLabel.horizontalCenter
                    topMargin: 10
                }
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 20
                text: (Chiaki.settings.audioVideoDisabled & 0x01) ? qsTr("You have disabled audio and video in your settings.\nTo re-enable change Audio/Video to Audio and Video Enabled in the General tab of the settings.") : qsTr("You have disabled video in your settings.\nTo re-enable change Audio/Video to Audio and Video Enabled in the General tab of the settings.")
                visible: !sessionLoading && !sessionError && (Chiaki.settings.audioVideoDisabled & 0x02)
            }

            Label {
                id: errorTitleLabel
                anchors {
                    bottom: spinner.top
                    horizontalCenter: spinner.horizontalCenter
                }
                font.pixelSize: 24
                visible: text
                opacity: 0 // shown by the P5M panel; kept for the focus
                onVisibleChanged: if (visible) view.grabInput(errorTitleLabel)
                Keys.onReturnPressed: root.showMainView()
                Keys.onEscapePressed: root.showMainView()
            }

            Label {
                id: errorTextLabel
                anchors {
                    top: errorTitleLabel.bottom
                    horizontalCenter: errorTitleLabel.horizontalCenter
                    topMargin: 10
                }
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 20
                visible: text
                opacity: 0
            }
        }

        // Starting the stream, or why it failed, in the P5M waiting panel.
        ConnectingScreen {
            anchors.fill: parent
            visible: view.sessionLoading || view.sessionError
            section: view.sessionError ? qsTr("Stream") : qsTr("Starting")
            title: view.sessionError ? (errorTitleLabel.text || qsTr("The stream stopped"))
                 : Chiaki.session ? qsTr("Connecting to %1").arg(Chiaki.settings.streamerMode ? qsTr("your PS5") : (Chiaki.connectingConsole() || Chiaki.session.host))
                 : qsTr("Connecting")
            status: qsTr("Starting the stream. While playing, %1 opens the menu.")
                .arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : "⌘O")
            failed: view.sessionError
            failText: errorTextLabel.text
            cancelable: false
            onCloseRequested: root.showMainView()
            Keys.onEscapePressed: if (view.sessionError) root.showMainView()
        }
    }

    ColumnLayout {
        id: cantDisplayMessage
        anchors.centerIn: parent
        opacity: Chiaki.window.hasVideo && Chiaki.session && Chiaki.session.cantDisplay ? 1.0 : 0.0
        visible: opacity
        spacing: 30

        Behavior on opacity { NumberAnimation { duration: 250 } }

        onVisibleChanged: {
            if (visible) {
                menuController.close();
                view.grabInput(goToHomeButton);
            } else {
                view.releaseInput();
            }
        }

        Label {
            Layout.alignment: Qt.AlignCenter
            text: qsTr("The screen contains content that can't be displayed using Remote Play.")
        }

        Button {
            id: goToHomeButton
            Layout.alignment: Qt.AlignCenter
            Layout.preferredHeight: 60
            text: qsTr("Go to Home Screen")
            Material.background: activeFocus ? parent.Material.accent : undefined
            Material.roundedScale: Material.SmallScale
            onClicked: Chiaki.sessionGoHome()
            Keys.onReturnPressed: clicked()
            Keys.onEscapePressed: clicked()
        }
    }

    RoundButton {
        anchors {
            right: parent.right
            top: parent.top
            margins: 40
        }
        icon.source: "qrc:/icons/discover-off-24px.svg"
        icon.width: 50
        icon.height: 50
        padding: 20
        checked: true
        opacity: networkIndicatorTimer.running ? 0.7 : 0.0
        visible: opacity
        Material.background: Material.accent

        Behavior on opacity { NumberAnimation { duration: 400 } }

        Timer {
            id: networkIndicatorTimer
            running: Chiaki.session?.averagePacketLoss > (Chiaki.settings.wifiDroppedNotif * 0.01)
            interval: 400
        }
    }

    Component {
        id: streamStatsContent
        Item {
            id: streamStatsContentRoot
            anchors.fill: parent
            ColumnLayout {
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    rightMargin: 5
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: "Mbps"
                    font.pixelSize: 18
                    visible: Chiaki.session ? true : false

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.session.measuredBitrate.toFixed(1) : ""
                        color: Material.accent
                        font.bold: true
                        font.pixelSize: 28
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("queue depth avg")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.window.queueDepthAverage.toFixed(1) : ""
                        font.bold: true
                        color: "#90caf9"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("pending frame age")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? qsTr("%1 ms").arg((Chiaki.window.pendingFrameAge * 1000.0).toFixed(0)) : ""
                        font.bold: true
                        color: "#90caf9"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    id: statsPacketLossLabel
                    text: qsTr("packet loss")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? "%1<font size=\"1\">%</font>".arg((((Chiaki.session && isFinite(Chiaki.session.averagePacketLoss)) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1)) : ""
                        font.bold: true
                        color: "#ef9a9a"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("dropped frames")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        id: statsDroppedFramesLabel
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.window.droppedFrames : ""
                        color: "#ef9a9a"
                        font.bold: true
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("lost frames")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? ((Chiaki.session && isFinite(Chiaki.session.framesLost)) ? Chiaki.session.framesLost : 0) : ""
                        color: "#ef9a9a"
                        font.bold: true
                        font.pixelSize: 18
                    }
                }
            }
        }
    }

    // The stream panel (P5M style): settings on the left, live numbers on
    // the right. Circle resumes; holding Circle ends the session.
    Component {
        id: menuContentComponent

        FocusScope {
            id: panelRoot
            property Item initialFocusItem: pictureRow
            anchors.fill: parent

            readonly property bool metal: Chiaki.window.runtimeRendererBackend === 2
            // From fit (Picture: Fit) towards filling the whole panel.
            readonly property var zoomSteps: [0.25, 0.5, 0.75, 1]
            function zoomIndex() {
                const z = Chiaki.window.ZoomFactor === -1 ? 1 : Chiaki.window.ZoomFactor;
                let best = 0;
                for (let i = 1; i < zoomSteps.length; ++i)
                    if (Math.abs(zoomSteps[i] - z) < Math.abs(zoomSteps[best] - z))
                        best = i;
                return best;
            }
            function endSession() {
                if (Chiaki.session)
                    Chiaki.window.close();
                else
                    root.showMainView();
            }

            // Hold Circle: a tap resumes, a full second ends the session.
            property bool holdFired: false
            function cancelHold() {
                holdTimer.stop();
                holdProgress.stop();
                endRing.progress = 0;
            }
            // O release pode ir ao jogo se o painel fechar durante o hold.
            // Cancelar pela perda do painel evita encerrar uma sessão retomada.
            onActiveFocusChanged: {
                if (!activeFocus)
                    cancelHold();
            }
            Connections {
                target: menuController
                function onOpenChanged() {
                    if (!menuController.open)
                        panelRoot.cancelHold();
                }
            }
            Timer {
                id: holdTimer
                interval: 1000
                onTriggered: {
                    if (!menuController.open || !panelRoot.activeFocus) {
                        panelRoot.cancelHold();
                        return;
                    }
                    panelRoot.holdFired = true;
                    holdProgress.stop();
                    panelRoot.endSession();
                }
            }
            NumberAnimation {
                id: holdProgress
                target: endRing
                property: "progress"
                from: 0
                to: 1
                duration: holdTimer.interval
            }
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Escape) {
                    if (!event.isAutoRepeat && !holdTimer.running) {
                        holdFired = false;
                        holdTimer.start();
                        holdProgress.start();
                    }
                    event.accepted = true;
                } else if (event.key === Qt.Key_Menu) {
                    menuController.close();
                    event.accepted = true;
                }
            }
            Keys.onReleased: (event) => {
                if (event.key !== Qt.Key_Escape || event.isAutoRepeat)
                    return;
                event.accepted = true;
                if (holdTimer.running) {
                    cancelHold();
                    menuController.close();
                }
            }

            // Fade the picture under the panel.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0.35) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
                }
            }

            Rectangle {
                id: panel
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    bottom: parent.bottom
                    bottomMargin: 24
                }
                width: Math.min(parent.width - 48, 1180)
                height: panelColumn.implicitHeight + 44
                radius: 36
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 60 / 255)
                gradient: Gradient {
                    GradientStop { position: 0; color: Theme.panelTop }
                    GradientStop { position: 1; color: Theme.panelBottom }
                }
                // Glass sheen on the top half.
                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 1
                    }
                    height: parent.height / 2
                    radius: parent.radius
                    color: Qt.rgba(1, 1, 1, 26 / 255)
                }

                ColumnLayout {
                    id: panelColumn
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 22
                        leftMargin: 28
                        rightMargin: 28
                    }
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 22
                        BrandHeader { screen: qsTr("Stream") }
                        Text {
                            text: qsTr("The game gets no input while this is open")
                            color: Theme.warning
                            font.pixelSize: Theme.hintSize
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: !Chiaki.session ? ""
                                : Chiaki.settings.streamerMode ? qsTr("Connected")
                                : Chiaki.session.connected ? qsTr("Connected to %1").arg(Chiaki.session.host)
                                : qsTr("Connecting to %1").arg(Chiaki.session.host)
                            color: Theme.textSecondary
                            font.pixelSize: Theme.hintSize
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 22

                        // SCREEN
                        ColumnLayout {
                            Layout.preferredWidth: 360
                            Layout.alignment: Qt.AlignTop
                            spacing: 8
                            SectionLabel { text: qsTr("Screen") }

                            StepRow {
                                id: pictureRow
                                Layout.fillWidth: true
                                text: qsTr("Picture")
                                readonly property var modes: [ChiakiWindow.VideoMode.Normal, ChiakiWindow.VideoMode.Zoom, ChiakiWindow.VideoMode.Stretch]
                                readonly property var names: [qsTr("Fit"), qsTr("Zoom"), qsTr("Stretch")]
                                position: Math.max(0, modes.indexOf(Chiaki.window.videoMode))
                                steps: 3
                                value: names[position]
                                onStepped: (delta) => Chiaki.window.videoMode = modes[(position + delta + 3) % 3]
                                KeyNavigation.down: zoomRow.visible ? zoomRow : fullscreenRow
                            }
                            StepRow {
                                id: zoomRow
                                Layout.fillWidth: true
                                visible: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                                text: qsTr("Zoom")
                                steps: panelRoot.zoomSteps.length
                                position: panelRoot.zoomIndex()
                                value: {
                                    const z = panelRoot.zoomSteps[position];
                                    return z >= 1 ? qsTr("Fill screen") : qsTr("%1%").arg(Math.round(z * 100));
                                }
                                onStepped: (delta) => {
                                    const i = Math.max(0, Math.min(panelRoot.zoomSteps.length - 1, position + delta));
                                    Chiaki.window.ZoomFactor = panelRoot.zoomSteps[i];
                                    Chiaki.settings.sZoomFactor = panelRoot.zoomSteps[i];
                                }
                                KeyNavigation.up: pictureRow
                                KeyNavigation.down: fullscreenRow
                            }
                            StepRow {
                                id: fullscreenRow
                                Layout.fillWidth: true
                                text: qsTr("Full screen")
                                readonly property bool on: Chiaki.window.fullscreen
                                value: on ? qsTr("On") : qsTr("Off")
                                valueColor: on ? Theme.active : Theme.textSecondary
                                onStepped: Chiaki.window.toggleFullscreen()
                                KeyNavigation.up: zoomRow.visible ? zoomRow : pictureRow
                                KeyNavigation.down: notchRow.visible ? notchRow : presetRow.visible ? presetRow : volumeRow
                            }
                            // The strip around the camera: only a borderless
                            // fullscreen can draw there, and it is composited
                            // (about 10 ms more than the native one).
                            StepRow {
                                id: notchRow
                                Layout.fillWidth: true
                                visible: Qt.platform.os === "osx"
                                text: qsTr("Around the camera")
                                value: Chiaki.window.notchFill ? qsTr("Fill (slower)") : qsTr("Black (fastest)")
                                valueColor: Chiaki.window.notchFill ? Theme.warning : Theme.active
                                onStepped: Chiaki.window.notchFill = !Chiaki.window.notchFill
                                KeyNavigation.up: fullscreenRow
                                KeyNavigation.down: presetRow.visible ? presetRow : volumeRow
                            }
                            StepRow {
                                id: presetRow
                                Layout.fillWidth: true
                                visible: !panelRoot.metal
                                text: qsTr("Picture quality")
                                readonly property var presets: [ChiakiWindow.VideoPreset.Default, ChiakiWindow.VideoPreset.HighQuality, ChiakiWindow.VideoPreset.HighQualitySpatial, ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial]
                                readonly property var names: [qsTr("Default"), qsTr("High"), qsTr("High + upscaling"), qsTr("High + advanced upscaling")]
                                steps: 4
                                position: Math.max(0, presets.indexOf(Chiaki.window.videoPreset))
                                value: names[position]
                                onStepped: (delta) => {
                                    const p = presets[(position + delta + 4) % 4];
                                    Chiaki.window.videoPreset = p;
                                    Chiaki.settings.videoPreset = p;
                                }
                                KeyNavigation.up: notchRow.visible ? notchRow : fullscreenRow
                                KeyNavigation.down: volumeRow
                            }
                        }

                        // SOUND and SESSION
                        ColumnLayout {
                            Layout.preferredWidth: 360
                            Layout.alignment: Qt.AlignTop
                            spacing: 8
                            SectionLabel { text: qsTr("Sound") }

                            StepRow {
                                id: volumeRow
                                Layout.fillWidth: true
                                text: qsTr("Volume")
                                steps: 11
                                position: Math.round(Chiaki.settings.audioVolume / 128 * 10)
                                value: qsTr("%1%").arg(position * 10)
                                onStepped: (delta) => Chiaki.settings.audioVolume = Math.round(Math.max(0, Math.min(10, position + delta)) * 12.8)
                                KeyNavigation.up: presetRow.visible ? presetRow : notchRow.visible ? notchRow : fullscreenRow
                                KeyNavigation.down: micRow
                            }
                            StepRow {
                                id: micRow
                                Layout.fillWidth: true
                                text: qsTr("Microphone")
                                enabled: Chiaki.session && Chiaki.session.connected
                                readonly property bool on: Chiaki.session && !Chiaki.session.muted
                                value: on ? qsTr("On") : qsTr("Off")
                                valueColor: on ? Theme.active : Theme.textSecondary
                                onStepped: if (Chiaki.session) Chiaki.session.muted = !Chiaki.session.muted
                                KeyNavigation.up: volumeRow
                                KeyNavigation.down: endRow
                            }

                            SectionLabel { text: qsTr("Session") }
                            GlassButton {
                                id: endRow
                                Layout.fillWidth: true
                                text: Chiaki.session ? qsTr("End session") : qsTr("Back to consoles")
                                onClicked: panelRoot.endSession()
                                KeyNavigation.up: micRow
                                HoldRing {
                                    id: endRing
                                    anchors {
                                        right: parent.right
                                        rightMargin: 16
                                        verticalCenter: parent.verticalCenter
                                    }
                                    width: 26
                                    height: 26
                                    Glyph {
                                        anchors.centerIn: parent
                                        button: "circle"
                                        size: 16
                                    }
                                }
                            }
                        }

                        // LIVE: what the stream is doing right now.
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            spacing: 10
                            SectionLabel { text: qsTr("Live") }

                            Meter {
                                Layout.fillWidth: true
                                visible: Chiaki.session
                                label: qsTr("Bitrate")
                                value: Chiaki.session ? qsTr("%1 Mbps").arg(Chiaki.session.measuredBitrate.toFixed(1)) : ""
                                dot: Theme.active
                            }
                            Meter {
                                Layout.fillWidth: true
                                visible: Chiaki.session
                                readonly property real loss: Chiaki.session && isFinite(Chiaki.session.averagePacketLoss) ? Chiaki.session.averagePacketLoss * 100 : 0
                                label: qsTr("Packet loss")
                                value: qsTr("%1%").arg(loss.toFixed(1))
                                dot: loss < 1 ? Theme.good : loss < 3 ? Theme.fair : Theme.bad
                            }
                            Meter {
                                Layout.fillWidth: true
                                label: qsTr("Dropped frames")
                                value: Chiaki.window.droppedFrames
                                dot: Chiaki.window.droppedFrames < 5 ? Theme.good : Chiaki.window.droppedFrames < 30 ? Theme.fair : Theme.bad
                            }
                            Meter {
                                Layout.fillWidth: true
                                visible: Chiaki.session
                                readonly property int lost: Chiaki.session && isFinite(Chiaki.session.framesLost) ? Chiaki.session.framesLost : 0
                                label: qsTr("Lost frames")
                                value: lost
                                dot: lost < 5 ? Theme.good : lost < 30 ? Theme.fair : Theme.bad
                            }
                        }
                    }

                    HintBar {
                        Layout.topMargin: 10
                        hints: [
                            { button: "cross", key: "Return", text: qsTr("Select") },
                            { button: "◀ ▶", key: "← →", text: qsTr("Change") },
                            { button: "circle", key: "Esc", text: qsTr("Resume") },
                            { button: "circle", key: "Esc", text: qsTr("Hold: end session") },
                        ]
                    }
                }
            }
        }
    }

    Item {
        id: menuView
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: Math.min(parent.height, 520)
        y: menuController.open ? parent.height - height : parent.height
        visible: !useSeparateMenuWindow && (menuController.open || menuController.closing)
        enabled: !useSeparateMenuWindow && menuController.open
        onVisibleChanged: {
            if (visible)
                view.grabInput(inlineMenuContent.item ? inlineMenuContent.item.initialFocusItem : null);
        }

        Behavior on y {
            NumberAnimation {
                id: inlineMenuAnimation
                duration: 250
                onRunningChanged: {
                    if (!running && !menuController.open) {
                        menuController.closing = false;
                        view.updateOverlayInteractionActive();
                    }
                }
            }
        }

        Loader {
            id: inlineMenuContent
            anchors.fill: parent
            active: !useSeparateMenuWindow
            sourceComponent: menuContentComponent
        }
    }

    StreamMenuWindow {
        id: separateMenuWindow
        transientParent: view.hostWindow
        x: separateMenuX
        y: menuController.open ? separateMenuY : separateMenuY + streamMenuHeight
        width: separateMenuWidth > 0 ? separateMenuWidth : view.width
        height: streamMenuHeight
        open: useSeparateMenuWindow && menuController.open
        closing: useSeparateMenuWindow && menuController.closing
        onCloseRequested: menuController.close()
        onDisplaySettingsRequested: {
            menuController.close();
            root.openDisplaySettings();
        }
        onPlaceboSettingsRequested: {
            menuController.close();
            root.openPlaceboSettings();
        }
        onMainViewRequested: root.showMainView()
        onCloseAnimationFinished: {
            if (view.hostWindow)
                view.hostWindow.requestActivate();
            menuController.closing = false;
            view.updateOverlayInteractionActive();
        }
    }

    Popup {
        id: sessionStopDialog
        background: Rectangle {
            radius: 30
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 60 / 255)
            gradient: Gradient {
                GradientStop { position: 0; color: Theme.panelTop }
                GradientStop { position: 1; color: Theme.panelBottom }
            }
        }
        property int closeAction: 0
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        modal: true
        padding: 30
        onAboutToShow: {
            closeAction = 0;
            sessionStopDialogActive = true;
            view.updateOverlayInteractionActive();
        }
        onClosed: {
            view.releaseInput();
            sessionStopDialogActive = false;
            view.updateOverlayInteractionActive();
            if (closeAction)
                Chiaki.stopSession(closeAction == 1);
        }

        ColumnLayout {
            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Disconnect Session")
                font.bold: true
                font.pixelSize: 24
            }

            Label {
                Layout.topMargin: 10
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Do you want the Console to go into sleep mode?")
                font.pixelSize: 20
            }

            RowLayout {
                Layout.topMargin: 30
                Layout.alignment: Qt.AlignCenter
                spacing: 30

                Button {
                    id: sleepButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Sleep")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.right: noButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: sessionStopDialog.close()
                    onVisibleChanged: if (visible) view.grabInput(sleepButton)
                    onClicked: {
                        sessionStopDialog.closeAction = 1;
                        sessionStopDialog.close();
                    }
                }

                Button {
                    id: noButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("No")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.left: sleepButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: sessionStopDialog.close()
                    onClicked: {
                        sessionStopDialog.closeAction = 2;
                        sessionStopDialog.close();
                    }
                }
            }
        }
    }

    Window {
        id: separateSessionStopWindow
        property int closeAction: 0
        readonly property int dialogWidth: 700
        readonly property int dialogHeight: 260
        visible: false
        flags: Qt.Dialog | Qt.FramelessWindowHint
        color: "transparent"
        transientParent: view.hostWindow
        modality: Qt.ApplicationModal
        x: separateDialogX
        y: separateDialogY
        width: dialogWidth
        height: dialogHeight

        onVisibleChanged: {
            if (visible) {
                closeAction = 0;
                view.updateSeparateDialogGeometry(width, height);
                requestActivate();
                view.grabInput(separateSleepButton);
            } else {
                view.releaseInput();
                if (closeAction)
                    Chiaki.stopSession(closeAction === 1);
            }
            view.updateOverlayInteractionActive();
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Material.background
            border.color: "#666666"
            border.width: 1
        }

        ColumnLayout {
            anchors.centerIn: parent

            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Disconnect Session")
                font.bold: true
                font.pixelSize: 24
            }

            Label {
                Layout.topMargin: 10
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Do you want the Console to go into sleep mode?")
                font.pixelSize: 20
            }

            RowLayout {
                Layout.topMargin: 30
                Layout.alignment: Qt.AlignCenter
                spacing: 30

                Button {
                    id: separateSleepButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Sleep")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.right: separateNoButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: separateSessionStopWindow.visible = false
                    onClicked: {
                        separateSessionStopWindow.closeAction = 1;
                        separateSessionStopWindow.visible = false;
                    }
                }

                Button {
                    id: separateNoButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("No")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.left: separateSleepButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: separateSessionStopWindow.visible = false
                    onClicked: {
                        separateSessionStopWindow.closeAction = 2;
                        separateSessionStopWindow.visible = false;
                    }
                }
            }
        }
    }

    Dialog {
        id: sessionPinDialog
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        title: qsTr("Console Login PIN")
        modal: true
        closePolicy: Popup.NoAutoClose
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAboutToShow: {
            standardButton(Dialog.Ok).enabled = Qt.binding(function() {
                return pinField.acceptableInput;
            });
            view.grabInput(pinField);
            sessionPinDialogActive = true;
            view.updateOverlayInteractionActive();
        }
        onClosed: {
            view.releaseInput();
            sessionPinDialogActive = false;
            view.updateOverlayInteractionActive();
        }
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

    Window {
        id: separateSessionPinWindow
        readonly property int dialogWidth: 360
        readonly property int dialogHeight: 220
        visible: false
        flags: Qt.Dialog | Qt.FramelessWindowHint
        color: "transparent"
        transientParent: view.hostWindow
        modality: Qt.ApplicationModal
        x: separateDialogX
        y: separateDialogY
        width: dialogWidth
        height: dialogHeight

        onVisibleChanged: {
            if (visible) {
                separatePinField.text = "";
                view.updateSeparateDialogGeometry(width, height);
                requestActivate();
                view.grabInput(separatePinField);
            } else {
                view.releaseInput();
            }
            view.updateOverlayInteractionActive();
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Material.background
            border.color: "#666666"
            border.width: 1
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 24
            }

            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Console Login PIN")
                font.bold: true
                font.pixelSize: 24
            }

            TextField {
                id: separatePinField
                Layout.topMargin: 20
                Layout.fillWidth: true
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
                Keys.onReturnPressed: if (acceptableInput) separatePinOkButton.clicked()
                Keys.onEscapePressed: separateSessionPinWindow.visible = false
            }

            RowLayout {
                Layout.topMargin: 20
                Layout.alignment: Qt.AlignRight
                spacing: 16

                Button {
                    text: qsTr("Cancel")
                    Keys.onReturnPressed: clicked()
                    onClicked: {
                        separateSessionPinWindow.visible = false;
                        Chiaki.stopSession(false);
                    }
                }

                Button {
                    id: separatePinOkButton
                    text: qsTr("OK")
                    enabled: separatePinField.acceptableInput
                    Keys.onReturnPressed: clicked()
                    onClicked: {
                        const pin = separatePinField.text;
                        separateSessionPinWindow.visible = false;
                        Chiaki.enterPin(pin);
                    }
                }
            }
        }
    }

    Timer {
        id: closeTimer
        interval: 2000
        onTriggered: root.showMainView()
    }

    Connections {
        target: Chiaki

        function onSessionChanged() {
            if (!Chiaki.session) {
                if (errorTitleLabel.text)
                    closeTimer.start();
                else
                    root.showMainView();
            } else {
                sessionError = false;
                errorTitleLabel.text = "";
                errorTextLabel.text = "";
                sessionLoading = !(Chiaki.window.loadingTransitionComplete || (Chiaki.settings.audioVideoDisabled & 0x02));
            }
        }

        function onSessionError(title, text) {
            sessionError = true;
            sessionLoading = false;
            errorTitleLabel.text = title;
            errorTextLabel.text = text;
            closeTimer.start();
        }

        function onSessionPinDialogRequested() {
            if (sessionPinDialog.opened || separateSessionPinWindow.visible)
                return;
            menuController.close();
            if (useSeparateMenuWindow)
                separateSessionPinWindow.visible = true;
            else
                sessionPinDialog.open();
            Chiaki.window.requestOverlayUpdate();
        }

        function onSessionStopDialogRequested() {
            if (sessionStopDialog.opened || separateSessionStopWindow.visible)
                return;
            menuController.close();
            if (useSeparateMenuWindow)
                separateSessionStopWindow.visible = true;
            else
                sessionStopDialog.open();
            Chiaki.window.requestOverlayUpdate();
        }
    }

    Connections {
        target: Chiaki.window

        function onLoadingTransitionCompleteChanged() {
            if (Chiaki.window.loadingTransitionComplete) {
                sessionLoading = false;
                Chiaki.window.noteLoadingTransitionComplete();
                Chiaki.window.requestOverlayUpdate();
            } else if (Chiaki.session) {
                sessionLoading = !(Chiaki.settings.audioVideoDisabled & 0x02);
            }
        }

        function onMenuRequested() {
            if (sessionPinDialog.opened || sessionStopDialog.opened || separateSessionPinWindow.visible || separateSessionStopWindow.visible)
                return;
            menuController.toggle();
            Chiaki.window.requestOverlayUpdate();
        }
    }
    Connections {
        target: Chiaki

        function onSessionChanged() {
            if (!Chiaki.session)
                menuController.close();
        }
    }
    Connections {
        target: Chiaki.session

        function onConnectedChanged() {
            if (Chiaki.settings.audioVideoDisabled & 0x02)
                sessionLoading = false;
        }
    }
}
