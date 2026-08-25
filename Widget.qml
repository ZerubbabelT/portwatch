import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  implicitWidth: row.implicitWidth + 14
  implicitHeight: bar ? bar.barSize : 26

  // Not every theme tunes bar.text for a light bar.background, so fall back
  // to a fixed dark tone rather than trust it blindly.
  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color iconColor: bar
    ? (luminance(bar.background) > 0.6 ? "#1a1a1a" : bar.foreground)
    : "white"

  property var ports: []
  // appPorts is only ever set from a real Hyprland window match (see isApp
  // below), never guessed from the process name.
  readonly property var ownPorts: root.ports.filter(function(p) { return p.pid > 0 && !p.isApp })
  readonly property var appPorts: root.ports.filter(function(p) { return p.pid > 0 && p.isApp })
  readonly property var systemPorts: root.ports.filter(function(p) { return p.pid === 0 })
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

  // The bar's own click/drag dispatcher only shows a pointer cursor and
  // routes clicks to widgets that expose this function (see WidgetButton).
  function triggerPress(button) { root.toggle() }

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

  // One round-trip: ss for the port/pid list, hyprctl clients -j for the
  // pid -> window map, and a per-pid /proc read for cmdline + cwd.
  readonly property string scanScript: [
    "ss -H -tulpn",
    "echo '===WIN==='",
    "hyprctl clients -j 2>/dev/null",
    "echo '===PROC==='",
    "for pid in $(ss -H -tulpn 2>/dev/null | grep -oP 'pid=\\K[0-9]+' | sort -u); do",
    "  cmd=$(tr '\\0' ' ' < /proc/$pid/cmdline 2>/dev/null)",
    "  cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null)",
    "  echo \"$pid<|>$cwd<|>$cmd\"",
    "done"
  ].join("\n")

  function parseWindowInfo(jsonText) {
    var map = ({})
    try {
      var clients = JSON.parse(jsonText || "[]")
      for (var i = 0; i < clients.length; i++) {
        var c = clients[i]
        if (c && c.pid && !(c.pid in map)) map[c.pid] = { klass: c.class || "" }
      }
    } catch (e) {}
    return map
  }

  function parseProcInfo(procText) {
    var map = ({})
    var lines = procText.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("<|>")
      if (parts.length < 3) continue
      map[parts[0]] = { cwd: parts[1], cmd: parts.slice(2).join("<|>") }
    }
    return map
  }

  function buildLabel(process, pid, win) {
    if (win) return (win.klass || process || "app") + " · pid " + pid
    return process ? process + " · pid " + pid : "unknown process"
  }

  // Empty when /proc couldn't be read (permission, or the process exited).
  function buildDetail(proc) {
    if (!proc || !proc.cwd) return ""
    var parts = proc.cwd.split("/").filter(function(s) { return s.length > 0 })
    var base = parts.length ? parts[parts.length - 1] : proc.cwd
    var cmd = (proc.cmd || "").trim().replace(/\s+/g, " ")
    if (cmd.length > 48) cmd = cmd.slice(0, 48) + "…"
    return cmd ? base + " — " + cmd : ""
  }

  function parsePorts(text, windowInfo, procInfo) {
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

      var win = pid > 0 ? windowInfo[pid] : undefined
      var proc = pid > 0 ? procInfo[pid] : undefined
      var isApp = !!win
      var label = root.buildLabel(process, pid, win)
      var detail = root.buildDetail(proc)

      out.push({ proto: proto, port: port, address: address, process: process, pid: pid, isApp: isApp, label: label, detail: detail })
    }

    out.sort(function(a, b) { return a.port - b.port })
    return out
  }

  Process {
    id: scanProc
    command: ["bash", "-c", root.scanScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var winMarker = "\n===WIN===\n"
        var procMarker = "\n===PROC===\n"
        var winIdx = text.indexOf(winMarker)
        var procIdx = text.indexOf(procMarker)
        var ssText = winIdx >= 0 ? text.slice(0, winIdx) : text
        var winText = (winIdx >= 0 && procIdx >= 0) ? text.slice(winIdx + winMarker.length, procIdx) : ""
        var procText = procIdx >= 0 ? text.slice(procIdx + procMarker.length) : ""

        var windowInfo = root.parseWindowInfo(winText)
        var procInfo = root.parseProcInfo(procText)
        root.ports = root.parsePorts(ssText, windowInfo, procInfo)
      }
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
      color: root.iconColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 14
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      visible: root.ownPorts.length > 0
      text: String(root.ownPorts.length)
      color: root.iconColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 11
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  PortsPopup {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    ownPorts: root.ownPorts
    appPorts: root.appPorts
    systemPorts: root.systemPorts
    armedKey: root.armedKey
    busyKey: root.busyKey
    errorKey: root.errorKey
    errorText: root.errorText
    onKillRequested: function(p) { root.requestKill(p) }
    onRefreshRequested: root.refresh()
  }

  Component.onCompleted: refresh()
}
