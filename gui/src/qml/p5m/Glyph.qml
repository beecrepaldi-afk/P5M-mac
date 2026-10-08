import QtQuick

// A controller button as drawn on the pad: colored PlayStation shapes for
// the face buttons, a pill with the name for the rest (L1, R1, Options...).
Item {
    id: glyph
    property string button: "cross"
    property int size: 24
    readonly property bool face: ["cross", "circle", "square", "triangle"].indexOf(button) >= 0
    implicitWidth: face ? size : pill.implicitWidth
    implicitHeight: size

    Canvas {
        id: canvas
        anchors.fill: parent
        visible: glyph.face
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const s = Math.min(width, height);
            const c = s / 2;
            const colors = { cross: Theme.cross, circle: Theme.circle, square: Theme.square, triangle: Theme.triangle };
            ctx.strokeStyle = colors[glyph.button];
            ctx.lineWidth = Math.max(2, s * 0.12);
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            const k = s * 0.28;
            ctx.beginPath();
            if (glyph.button === "cross") {
                ctx.moveTo(c - k, c - k); ctx.lineTo(c + k, c + k);
                ctx.moveTo(c + k, c - k); ctx.lineTo(c - k, c + k);
            } else if (glyph.button === "circle") {
                ctx.arc(c, c, k * 1.05, 0, Math.PI * 2);
            } else if (glyph.button === "square") {
                ctx.rect(c - k, c - k, 2 * k, 2 * k);
            } else {
                ctx.moveTo(c, c - k * 1.15); ctx.lineTo(c + k * 1.15, c + k * 0.85); ctx.lineTo(c - k * 1.15, c + k * 0.85);
                ctx.closePath();
            }
            ctx.stroke();
        }
        Component.onCompleted: requestPaint()
        Connections {
            target: glyph
            function onButtonChanged() { canvas.requestPaint() }
        }
    }

    Rectangle {
        id: pill
        visible: !glyph.face
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: pillText.implicitWidth + 14
        width: implicitWidth
        height: glyph.size * 0.86
        radius: height / 2
        color: "transparent"
        border.width: 1.5
        border.color: Theme.textSecondary
        Text {
            id: pillText
            anchors.centerIn: parent
            text: glyph.button
            color: Theme.text
            font.pixelSize: glyph.size * 0.48
            font.weight: Font.DemiBold
            font.letterSpacing: 0.5
        }
    }
}
