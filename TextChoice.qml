import QtQuick
import qs.Commons

// A plain-text choice: muted until selected, a short rule under the selected one.
Text {
  id: root
  property bool selected: false
  property bool ruled: true
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  signal activated()

  color: selected || area.containsMouse || activeFocus ? foreground : Qt.darker(foreground, 1.6)
  font.family: fontFamily
  font.pixelSize: fontSize
  bottomPadding: Style.space(4)
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: text
  Keys.onReturnPressed: activated()
  Keys.onSpacePressed: activated()

  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: Style.space(2)
    color: root.accent
    visible: root.ruled && root.selected || root.activeFocus
    opacity: root.selected ? 1 : 0.5
  }
  MouseArea {
    id: area
    anchors.fill: parent
    anchors.margins: -Style.space(3)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
