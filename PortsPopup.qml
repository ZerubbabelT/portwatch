import QtQuick
import Quickshell
import Quickshell.Hyprland

// Floating popup listing local listening ports. Loaded implicitly as a
// sibling type by Widget.qml (same-directory QML files need no import).
PopupWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property var ports: []
  property string armedKey: ""
  property string busyKey: ""
  property string errorKey: ""
  property string errorText: ""

  signal killRequested(var p)
  signal refreshRequested()

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property color fg: bar ? bar.foreground : "white"
  readonly property color bg: bar ? bar.background : "#1e1e2e"
  readonly property string fontFamily: bar ? bar.fontFamily : "monospace"

  readonly property int margin: 10
  readonly property int cardPadding: 12

  implicitWidth: 340
  implicitHeight: Math.min(420, Math.max(120, content.implicitHeight + cardPadding * 2))

  visible: open || card.opacity > 0
  color: "transparent"

  function close() { root.open = false }

  onOpenChanged: {
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  HyprlandFocusGrab {
    active: root.open
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    id: popupAnchor
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.bar || !root.anchorWindow) return

      var target = root.anchorItem
      var w = root.implicitWidth
      var h = root.implicitHeight
      var localX = target.width / 2 - w / 2
      var localY = target.height + root.margin

      if (root.bar.position === "bottom") {
        localY = -h - root.margin
      } else if (root.bar.position === "left") {
        localX = target.width + root.margin
        localY = target.height / 2 - h / 2
      } else if (root.bar.position === "right") {
        localX = -w - root.margin
        localY = target.height / 2 - h / 2
      }

      var point = root.anchorWindow.contentItem.mapFromItem(target, localX, localY)

      if (root.bar.position === "top" || root.bar.position === "bottom") {
        point.x = Math.max(root.margin, Math.min(point.x, root.anchorWindow.width - w - root.margin))
      } else {
        point.y = Math.max(root.margin, Math.min(point.y, root.anchorWindow.height - h - root.margin))
      }

      popupAnchor.rect.x = Math.round(point.x)
      popupAnchor.rect.y = Math.round(point.y)
    }
  }

  Rectangle {
    id: card
    anchors.fill: parent
    radius: 12
    color: root.bg
    border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)
    border.width: 2
    opacity: root.open ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }

    Column {
      id: content
      anchors.fill: parent
      anchors.margins: root.cardPadding
      spacing: 8

      Row {
        width: parent.width
        height: Math.max(titleText.implicitHeight, refreshBtn.height)

        Text {
          id: titleText
          text: "Listening Ports"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: 14
          font.bold: true
          width: parent.width - refreshBtn.width
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          id: refreshBtn
          width: 22
          height: 22
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 13
            opacity: refreshArea.containsMouse ? 1 : 0.6
          }

          MouseArea {
            id: refreshArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.refreshRequested()
          }
        }
      }

      Text {
        visible: root.ports.length === 0
        text: "No listening ports found"
        color: Qt.darker(root.fg, 1.3)
        font.family: root.fontFamily
        font.pixelSize: 12
      }

      Flickable {
        id: flick
        width: parent.width
        height: Math.min(320, listCol.implicitHeight)
        contentWidth: width
        contentHeight: listCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: listCol
          width: flick.width
          spacing: 6

          Repeater {
            model: root.ports

            delegate: Rectangle {
              id: rowDelegate
              required property var modelData
              width: listCol.width
              height: 44
              radius: 8
              color: rowHover.hovered ? Qt.lighter(root.bg, 1.25) : "transparent"

              readonly property string rowKey: modelData.proto + ":" + modelData.port + ":" + modelData.pid
              readonly property bool armed: root.armedKey === rowKey
              readonly property bool busy: root.busyKey === rowKey
              readonly property bool errored: root.errorKey === rowKey

              HoverHandler { id: rowHover }

              Row {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: killBtn.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Rectangle {
                  width: 6
                  height: 6
                  radius: 3
                  anchors.verticalCenter: parent.verticalCenter
                  color: modelData.proto === "tcp" ? "#4ade80" : "#60a5fa"
                }

                Column {
                  spacing: 1
                  width: 220

                  Text {
                    text: ":" + modelData.port
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    font.bold: true
                  }

                  Text {
                    text: rowDelegate.errored
                      ? root.errorText
                      : (modelData.process ? modelData.process + " · pid " + modelData.pid : "unknown process")
                    color: rowDelegate.errored ? "#f87171" : Qt.darker(root.fg, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }
              }

              Rectangle {
                id: killBtn
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: killLabel.implicitWidth + 16
                height: 24
                radius: 6
                visible: modelData.pid > 0
                color: rowDelegate.armed
                  ? "#dc2626"
                  : (killArea.containsMouse ? Qt.rgba(0.9, 0.3, 0.3, 0.25) : Qt.rgba(0.9, 0.3, 0.3, 0.12))

                Text {
                  id: killLabel
                  anchors.centerIn: parent
                  text: rowDelegate.busy ? "…" : (rowDelegate.armed ? "Confirm" : "Kill")
                  color: rowDelegate.armed ? "white" : "#f87171"
                  font.family: root.fontFamily
                  font.pixelSize: 11
                  font.bold: true
                }

                MouseArea {
                  id: killArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !rowDelegate.busy
                  onClicked: root.killRequested(rowDelegate.modelData)
                }
              }
            }
          }
        }
      }
    }
  }
}
