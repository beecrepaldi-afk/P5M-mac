import QtQuick

// Progress ring for "hold a button" actions. progress: 0..1
Canvas {
    property real progress: 0
    property color color: Theme.circle
    implicitWidth: 28
    implicitHeight: 28
    onProgressChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        const c = width / 2;
        const r = c - 3;
        ctx.lineWidth = 3;
        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.15);
        ctx.beginPath();
        ctx.arc(c, c, r, 0, Math.PI * 2);
        ctx.stroke();
        if (progress > 0) {
            ctx.strokeStyle = color;
            ctx.beginPath();
            ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * progress);
            ctx.stroke();
        }
    }
}
