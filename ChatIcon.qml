import QtQuick
import qs.Commons

// Speech-bubble mark drawn from plain primitives instead of a Nerd Font
// glyph — same reasoning as LockIcon.qml/TailscaleIcon.qml: glyph rendering
// in this bar's tiny icon slot has shown color fringing before, and a
// hand-drawn shape sidesteps it entirely while staying trivially tintable.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real bubbleWidth: iconSize * 0.86
  readonly property real bubbleHeight: iconSize * 0.6

  Rectangle {
    id: bubble
    width: root.bubbleWidth
    height: root.bubbleHeight
    radius: height * 0.34
    color: root.color
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.iconSize * 0.05
  }

  // Tail: a small square rotated 45° and half-clipped under the bubble's
  // left side, the same trick LockIcon uses for its shackle clip.
  Item {
    width: root.iconSize * 0.22
    height: root.iconSize * 0.22
    clip: true
    anchors.top: bubble.bottom
    anchors.topMargin: -root.iconSize * 0.11
    x: bubble.x + root.bubbleWidth * 0.14

    Rectangle {
      width: parent.width * 1.3
      height: parent.height * 1.3
      color: root.color
      rotation: 45
      anchors.centerIn: parent
    }
  }

  Row {
    anchors.centerIn: bubble
    spacing: Math.max(1, root.iconSize * 0.08)

    Repeater {
      model: 3
      delegate: Rectangle {
        width: Math.max(1.4, root.iconSize * 0.1)
        height: width
        radius: width / 2
        color: Qt.darker(root.color, 1.9)
      }
    }
  }
}
