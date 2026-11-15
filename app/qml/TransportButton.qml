import QtQuick
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Controls.ToolButton {
    id: root

    // "prev", "play", "pause" or "next".
    property string kind: "play"
    property color iconColor: Kirigami.Theme.textColor

    implicitWidth: Kirigami.Units.gridUnit * 2
    implicitHeight: Kirigami.Units.gridUnit * 2

    contentItem: Item {
        implicitWidth: Kirigami.Units.iconSizes.smallMedium + 2
        implicitHeight: Kirigami.Units.iconSizes.smallMedium + 2

        Canvas {
            id: canvas
            anchors.centerIn: parent
            width: Kirigami.Units.iconSizes.smallMedium + 2
            height: Kirigami.Units.iconSizes.smallMedium + 2

            function triangle(ctx, x1, y1, x2, y2, x3, y3) {
                ctx.beginPath();
                ctx.moveTo(x1, y1);
                ctx.lineTo(x2, y2);
                ctx.lineTo(x3, y3);
                ctx.closePath();
                ctx.fill();
            }

            onPaint: {
                var ctx = getContext("2d");
                var w = width;
                var h = height;
                ctx.clearRect(0, 0, w, h);
                ctx.fillStyle = root.iconColor;

                if (root.kind === "prev") {
                    ctx.fillRect(w * 0.18, h * 0.2, w * 0.11, h * 0.6);
                    triangle(ctx, w * 0.80, h * 0.2, w * 0.80, h * 0.8,
                             w * 0.31, h * 0.5);
                } else if (root.kind === "next") {
                    triangle(ctx, w * 0.20, h * 0.2, w * 0.20, h * 0.8,
                             w * 0.69, h * 0.5);
                    ctx.fillRect(w * 0.71, h * 0.2, w * 0.11, h * 0.6);
                } else if (root.kind === "pause") {
                    ctx.fillRect(w * 0.27, h * 0.2, w * 0.15, h * 0.6);
                    ctx.fillRect(w * 0.58, h * 0.2, w * 0.15, h * 0.6);
                } else if (root.kind === "wave") {
                    ctx.strokeStyle = root.iconColor;
                    ctx.lineWidth = Math.max(2, w * 0.09);
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.moveTo(w * 0.12, h * 0.58);
                    ctx.bezierCurveTo(w * 0.28, h * 0.14,
                                      w * 0.44, h * 0.14,
                                      w * 0.52, h * 0.50);
                    ctx.bezierCurveTo(w * 0.60, h * 0.86,
                                      w * 0.76, h * 0.86,
                                      w * 0.88, h * 0.42);
                    ctx.stroke();
                } else {
                    triangle(ctx, w * 0.30, h * 0.17, w * 0.30, h * 0.83,
                             w * 0.82, h * 0.5);
                }
            }

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            Connections {
                target: root
                function onKindChanged() { canvas.requestPaint(); }
                function onIconColorChanged() { canvas.requestPaint(); }
            }
        }
    }
}
