pragma Singleton
import QtQuick

// The P5M look, shared with the Quest app (Estilo.kt there): PS5 navy with a
// touch of glass. One place for colors, type and metrics.
QtObject {
    // Background: vertical gradient plus a blue and a purple glow.
    readonly property color bgTop: "#0A1428"
    readonly property color bgBottom: "#05070D"
    readonly property color glowBlue: Qt.rgba(30 / 255, 90 / 255, 210 / 255, 110 / 255)
    readonly property color glowPurple: Qt.rgba(90 / 255, 60 / 255, 200 / 255, 70 / 255)
    // Floating panels (stream menu, dialogs).
    readonly property color panelTop: Qt.rgba(14 / 255, 26 / 255, 50 / 255, 240 / 255)
    readonly property color panelBottom: Qt.rgba(6 / 255, 9 / 255, 16 / 255, 240 / 255)

    readonly property color text: "#FFFFFF"
    readonly property color textSecondary: "#A9B1BF"
    readonly property color textMuted: "#8B95A6"

    readonly property color accent: "#0070D1"      // main action
    readonly property color focus: "#1A86E8"
    readonly property color active: "#6FB2FF"      // a value that is on
    readonly property color highlight: "#8CC4FF"
    readonly property color highlightBg: Qt.rgba(0, 112 / 255, 209 / 255, 80 / 255)
    readonly property color error: "#FF7A7A"
    readonly property color errorBg: Qt.rgba(180 / 255, 40 / 255, 60 / 255, 90 / 255)
    readonly property color warning: "#D9B870"

    readonly property color good: "#5FD38D"
    readonly property color fair: "#FFC766"
    readonly property color bad: "#FF6E6E"

    // PlayStation face buttons.
    readonly property color cross: "#7FB4EE"
    readonly property color circle: "#FF7A7A"
    readonly property color square: "#E690CF"
    readonly property color triangle: "#43D6B2"

    readonly property int radius: 18
    readonly property int pillRadius: 28
    readonly property int focusWidth: 3
    readonly property int rowHeight: 52
    readonly property int gutter: 24

    readonly property int brandSize: 30
    readonly property int titleSize: 28
    readonly property int itemSize: 18
    readonly property int bodySize: 15
    readonly property int sectionSize: 13
    readonly property int hintSize: 14
    readonly property int primarySize: 22
}
