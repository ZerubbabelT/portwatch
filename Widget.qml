import QtQuick
import Quickshell
import Quickshell.Io

// Bar widget: shows a plug icon + live count of local listening ports.
// Click opens PortsPopup.qml with the full list and a stop button per row.
Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  implicitWidth: row.implicitWidth + 14
  implicitHeight: bar ? bar.barSize : 26

  property var ports: []
  property string armedKey: ""
  property string busyKey: ""
  property string errorKey: ""
  property string errorText: ""

  function close() { popup.open = false }

  function open() {
    popup.open = true
    refresh()
  }

  function toggle() {
    if (popup.open) close()
    else open()
  }

  IpcHandler {
    target: "zeru.portwatch"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  function keyFor(p) { return p.proto + ":" + p.port + ":" + p.pid }

  function refresh() {
    if (!scanProc.running) scanProc.running = true
  }

  function requestKill(p) {
    var key = keyFor(p)
    if (killProc.running) return

    if (root.armedKey !== key) {
      root.armedKey = key
      armTimer.restart()
      return
    }

    armTimer.stop()
    root.armedKey = ""
    root.busyKey = key
    killProc.targetKey = key
    killProc.command = ["kill", "-TERM", String(p.pid)]
    killProc.running = true
  }

  function parsePorts(text) {
    var lines = text.split("\n")
    var seen = ({})
    var out = []

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue

      var m = line.match(/^(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s*(.*)$/)
      if (!m) continue

      var proto = m[1]
      var state = m[2]
      var local = m[5]
      var rest = m[7] || ""

      if (proto === "tcp" && state !== "LISTEN") continue
      if (proto !== "tcp" && proto !== "udp") continue

      var portMatch = local.match(/:(\d+)$/)
      if (!portMatch) continue
      var port = parseInt(portMatch[1], 10)
      var address = local.slice(0, local.length - portMatch[0].length) || "*"

      var procMatch = rest.match(/\(\"([^"]+)\",pid=(\d+)/)
      var process = procMatch ? procMatch[1].replace(/-MainThread$/, "") : ""
      var pid = procMatch ? parseInt(procMatch[2], 10) : 0

      var key = proto + ":" + port + ":" + pid
      if (seen[key]) continue
      seen[key] = true

      out.push({ proto: proto, port: port, address: address, process: process, pid: pid })
    }

    out.sort(function(a, b) { return a.port - b.port })
    return out
  }

  Process {
    id: scanProc
    command: ["ss", "-H", "-tulpn"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ports = root.parsePorts(text)
    }
  }

  Process {
    id: killProc
    property string targetKey: ""
    onExited: function(exitCode) {
      root.busyKey = ""
      if (exitCode !== 0) {
        root.errorKey = targetKey
        root.errorText = "Couldn't stop it (permission?)"
        errorTimer.restart()
      }
      root.refresh()
    }
  }

  Timer {
    id: armTimer
    interval: 3000
    onTriggered: root.armedKey = ""
  }

  Timer {
    id: errorTimer
    interval: 3500
    onTriggered: { root.errorKey = ""; root.errorText = "" }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 3000
    repeat: true
    running: popup.open
    onTriggered: root.refresh()
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 4

    Text {
      text: ""
      color: bar ? bar.foreground : "white"
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 14
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      visible: root.ports.length > 0
      text: String(root.ports.length)
      color: bar ? bar.foreground : "white"
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 11
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggle()
  }

  PortsPopup {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    ports: root.ports
    armedKey: root.armedKey
    busyKey: root.busyKey
    errorKey: root.errorKey
    errorText: root.errorText
    onKillRequested: function(p) { root.requestKill(p) }
    onRefreshRequested: root.refresh()
  }

  Component.onCompleted: refresh()
}
