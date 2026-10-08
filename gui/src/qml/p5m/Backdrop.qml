import QtQuick

// Full-screen P5M background: navy gradient with two soft glows. Drawn by a
// shader with dithering (no banding on the dark gradient); the Canvas below
// is the fallback when the shader is not built in.
Item {
    ShaderEffect {
        id: shader
        anchors.fill: parent
        property size viewSize: Qt.size(width, height)
        property color colorTop: Theme.bgTop
        property color colorBottom: Theme.bgBottom
        property color glowA: Qt.rgba(Theme.glowBlue.r, Theme.glowBlue.g, Theme.glowBlue.b, 1)
        property color glowB: Qt.rgba(Theme.glowPurple.r, Theme.glowPurple.g, Theme.glowPurple.b, 1)
        property real alphaA: Theme.glowBlue.a
        property real alphaB: Theme.glowPurple.a
        fragmentShader: "qrc:/shaders/backdrop.frag.qsb"
    }

    Canvas {
        anchors.fill: parent
        visible: shader.status !== ShaderEffect.Compiled
        onVisibleChanged: if (visible) requestPaint()
        onWidthChanged: if (visible) requestPaint()
        onHeightChanged: if (visible) requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            const g = ctx.createLinearGradient(0, 0, 0, height);
            g.addColorStop(0, Theme.bgTop);
            g.addColorStop(1, Theme.bgBottom);
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, width, height);
            const r = Math.max(width, height) * 0.7;
            function glow(x, y, c) {
                const rg = ctx.createRadialGradient(x, y, 0, x, y, r);
                rg.addColorStop(0, c);
                rg.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0));
                ctx.fillStyle = rg;
                ctx.fillRect(0, 0, width, height);
            }
            glow(width * 0.15, height * 0.05, Theme.glowBlue);
            glow(width * 0.9, height * 0.95, Theme.glowPurple);
        }
    }
}
