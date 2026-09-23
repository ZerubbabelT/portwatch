import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons

PopupWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property var ownPorts: []
  property var appPorts: []
  property var systemPorts: []
  property bool appsExpanded: false
  property bool systemExpanded: false
  property string armedKey: ""
  property string busyKey: ""
  property string errorKey: ""
  property string errorText: ""

  signal killRequested(var p)
  signal openRequested(var p)
  signal refreshRequested()

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border

  // WCAG relative luminance, not the 0.299/0.587/0.114 approximation: the
  // themes this has to survive differ mostly in the dark end, where the two
  // disagree most.
  function relLum(c) {
    function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
  }
  function contrast(a, b) {
    var la = relLum(a), lb = relLum(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  // Several shipped themes put their own muted and urgent nearly on top of
  // their popup background (matte-black muted is 1.5:1, miasma urgent 2.3:1),
  // so anything that would be unreadable is pulled away from the card first:
  // hued colors keep their hue and walk lighter/darker, muted just fades the
  // foreground into the background instead.
  function readable(c, on) {
    var up = contrast(Qt.rgba(1, 1, 1, 1), on) > contrast(Qt.rgba(0, 0, 0, 1), on)
    for (var i = 0; i < 8 && contrast(c, on) < 4.5; i++)
      c = up ? Qt.lighter(c, 1.2) : Qt.darker(c, 1.2)
    return c
  }

  readonly property color fg: readable(Color.popups.text, bg)
  readonly property color accent: readable(Color.accent, bg)
  readonly property color urgent: readable(Color.urgent, bg)
  readonly property color safeMuted: contrast(Color.muted, bg) >= 4.5
    ? Color.muted
    : Qt.tint(bg, Qt.rgba(fg.r, fg.g, fg.b, 0.7))
  readonly property string fontFamily: bar ? bar.fontFamily : "monospace"

  readonly property int margin: 10
  readonly property int cardPadding: 12

  implicitWidth: 380
  implicitHeight: Math.min(460, Math.max(120, content.implicitHeight + cardPadding * 2))

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
    radius: 0
    color: root.bg
    border.color: root.borderColor
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
            text: ""
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
        visible: root.ownPorts.length === 0
        text: "Nothing you're running right now"
        color: root.safeMuted
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
            model: root.ownPorts
            delegate: PortRow { width: listCol.width }
          }

          SectionToggle {
            width: listCol.width
            label: "Apps"
            count: root.appPorts.length
            expanded: root.appsExpanded
            onToggled: root.appsExpanded = !root.appsExpanded
          }

          Repeater {
            model: root.appsExpanded ? root.appPorts : []
            delegate: PortRow { width: listCol.width }
          }

          SectionToggle {
            width: listCol.width
            label: "System"
            count: root.systemPorts.length
            expanded: root.systemExpanded
            onToggled: root.systemExpanded = !root.systemExpanded
          }

          Repeater {
            model: root.systemExpanded ? root.systemPorts : []
            delegate: PortRow { width: listCol.width }
          }
        }
      }
    }
  }

  component SectionToggle: Item {
    id: toggle
    required property string label
    required property int count
    required property bool expanded
    signal toggled()

    height: toggleRow.implicitHeight + 4
    visible: count > 0

    Row {
      id: toggleRow
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6

      Text {
        text: toggle.expanded ? "▾" : "▸"
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 10
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: toggle.label + " (" + toggle.count + ")"
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 11
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: toggle.toggled()
    }
  }

  component PortRow: Rectangle {
    id: rowDelegate
    required property var modelData
    readonly property bool hasDetail: modelData.detail !== ""
    height: hasDetail ? 56 : 44
    radius: 8
    color: rowHover.hovered ? Style.hoverFillFor(root.fg, root.accent, root.urgent) : "transparent"

    readonly property string rowKey: modelData.proto + ":" + modelData.port + ":" + modelData.pid
    readonly property bool armed: root.armedKey === rowKey
    readonly property bool busy: root.busyKey === rowKey
    readonly property bool errored: root.errorKey === rowKey
    // Only a TCP listener can be reached over http://.
    readonly property bool openable: modelData.proto === "tcp"

    HoverHandler { id: rowHover }

    // Declared before killBtn so the Kill button, which overlaps it, stays on
    // top and keeps receiving its own clicks.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: rowDelegate.openable
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openRequested(rowDelegate.modelData)
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 8
      anchors.right: killBtn.left
      anchors.rightMargin: 8
      anchors.top: parent.top
      anchors.topMargin: 6
      spacing: 8

      Rectangle {
        width: 6
        height: 6
        radius: 3
        anchors.top: parent.top
        anchors.topMargin: 4
        color: modelData.proto === "tcp" ? root.accent : root.safeMuted
      }

      Column {
        spacing: 1
        width: 260

        Row {
          spacing: 5

          Text {
            text: ":" + modelData.port
            textFormat: Text.PlainText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 13
            font.bold: true
          }

          Text {
            visible: rowDelegate.openable && rowHover.hovered
            text: "󰖟 open"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: 10
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Process names, window classes and cmdlines are foreign text; the
        // Text default is AutoText, which would render markup in them as
        // rich text (<img> included).
        Text {
          text: rowDelegate.errored ? root.errorText : modelData.label
          textFormat: Text.PlainText
          color: rowDelegate.errored ? root.urgent : root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 10
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          visible: rowDelegate.hasDetail
          text: modelData.detail
          textFormat: Text.PlainText
          color: root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 9
          elide: Text.ElideMiddle
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
        ? root.urgent
        : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, killArea.containsMouse ? 0.25 : 0.12)

      Text {
        id: killLabel
        anchors.centerIn: parent
        text: rowDelegate.busy ? "…" : (rowDelegate.armed ? "Confirm" : "Kill")
        color: rowDelegate.armed ? root.bg : root.urgent
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
