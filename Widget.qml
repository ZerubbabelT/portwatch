import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  // Bar.qml forces a vertical widget's slot width to bar.barSize regardless
  // of implicitWidth, so the cross-axis must follow bar.vertical the same
  // way BarIconButton's fixedWidth/fixedHeight do, or content gets clipped.
  readonly property bool vertical: bar ? bar.vertical : false
  implicitWidth: vertical ? (bar ? bar.barSize : 26) : row.implicitWidth + 14
  implicitHeight: vertical ? row.implicitHeight + 10 : (bar ? bar.barSize : 26)

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

  // Wildcard and loopback binds are reachable as localhost; a listener bound
  // to one specific address has to be visited at that address.
  function hostFor(address) {
    var a = String(address || "")
    if (a === "" || a === "*" || a === "0.0.0.0" || a === "[::]" || a === "::"
        || a === "127.0.0.1" || a === "[::1]" || a === "::1") return "localhost"
    // Anything else is only used verbatim when it looks like a plain host or
    // bracketed literal; an interface-scoped or otherwise odd address from ss
    // would make an unopenable url, so fall back to localhost.
    return /^[A-Za-z0-9.\-]+$|^\[[0-9A-Fa-f:.]+\]$/.test(a) ? a : "localhost"
  }

  // Handed to the default browser through the desktop handler rather than a
  // hardcoded binary, and detached the way the rest of the shell launches
  // things, so the browser does not stay a child of quickshell. The url is
  // built from an int port and a host matched against the fixed set above,
  // each passed as its own argv entry, so nothing from ss output reaches a
  // shell.
  function openInBrowser(p) {
    if (p.proto !== "tcp") return
    Quickshell.execDetached(["/usr/bin/xdg-open",
                             "http://" + root.hostFor(p.address) + ":" + p.port])
    root.close()
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

    // Without a start time there is nothing to pin the pid to, so decline
    // rather than signal a pid that may since have been reused.
    if (!p.startTime) {
      root.errorKey = key
      root.errorText = "Couldn't verify process; refresh"
      errorTimer.restart()
      root.refresh()
      return
    }

    root.busyKey = key
    killProc.targetKey = key
    killProc.command = ["/usr/bin/bash", "-c", root.killScript,
                        "portwatch-kill", String(p.pid), String(p.startTime)]
    killProc.running = true
  }

  // One round-trip: ss for the port/pid list, hyprctl clients -j for the
  // pid -> window map, and a per-pid /proc read for start time, cmdline, cwd.
  // Absolute paths throughout so a poisoned PATH can't substitute any of it.
  // StdioCollector has no size cap of its own, so the whole thing is piped
  // through head -c; a runaway producer gets SIGPIPE'd instead of growing
  // the collector's buffer without bound. The two commands that can block on
  // something outside this process (a socket dump on a busy host, a wedged
  // Hyprland IPC socket) each carry their own hard deadline, so the script
  // always reaches its end and never leaves a child behind for the watchdog
  // to have to clean up.
  readonly property string scanScript: [
    "{",
    "ports=$(/usr/bin/timeout -s KILL 5 /usr/bin/ss -H -tulpn 2>/dev/null | /usr/bin/head -n 500)",
    "printf '%s\\n' \"$ports\"",
    "echo '===WIN==='",
    "/usr/bin/timeout -s KILL 5 /usr/bin/hyprctl clients -j 2>/dev/null",
    "echo '===PROC==='",
    "for pid in $(printf '%s\\n' \"$ports\" | /usr/bin/grep -oP 'pid=\\K[0-9]+' | /usr/bin/sort -u | /usr/bin/head -n 300); do",
    "  cmd=$(/usr/bin/cat /proc/$pid/cmdline 2>/dev/null | /usr/bin/tr '\\0' ' ' | /usr/bin/head -c 200)",
    "  cwd=$(/usr/bin/readlink -f /proc/$pid/cwd 2>/dev/null | /usr/bin/head -c 200)",
    // Field 22 of /proc/PID/stat is the process start time in clock ticks.
    // It is fixed for the life of the process, so (pid, starttime) survives
    // PID reuse where the pid alone does not. Everything up to the last
    // ') ' is dropped first because comm may itself contain spaces and
    // parens, which would otherwise shift the field numbering.
    "  st=$(/usr/bin/cat /proc/$pid/stat 2>/dev/null)",
    "  st=${st##*') '}",
    "  start=$(printf '%s' \"$st\" | /usr/bin/cut -d' ' -f20)",
    "  echo \"$pid<|>$start<|>$cwd<|>$cmd\"",
    "done",
    "} | /usr/bin/head -c 1000000"
  ].join("\n")

  // Re-reads the start time and refuses to signal unless it still matches the
  // one shown in the row that was confirmed. Exit 3 = process already gone,
  // 4 = pid was reused by an unrelated process, anything else = kill failed.
  readonly property string killScript: [
    "p=$1",
    "want=$2",
    "s=$(/usr/bin/cat /proc/$p/stat 2>/dev/null) || exit 3",
    "s=${s##*') '}",
    "got=$(printf '%s' \"$s\" | /usr/bin/cut -d' ' -f20)",
    "[ -n \"$got\" ] || exit 3",
    "[ \"$got\" = \"$want\" ] || exit 4",
    "kill -TERM \"$p\""
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
      if (parts.length < 4) continue
      map[parts[0]] = { start: parts[1], cwd: parts[2], cmd: parts.slice(3).join("<|>") }
    }
    return map
  }

  // Every string below originates outside this widget (window classes, comm
  // names, cwds, cmdlines), so each is clamped before it reaches a delegate.
  function clamp(str, n) {
    var v = String(str || "")
    return v.length > n ? v.slice(0, n) + "…" : v
  }

  function buildLabel(process, pid, win) {
    if (win) return root.clamp(win.klass || process || "app", 64) + " · pid " + pid
    return process ? root.clamp(process, 64) + " · pid " + pid : "unknown process"
  }

  // Empty when /proc couldn't be read (permission, or the process exited).
  function buildDetail(proc) {
    if (!proc || !proc.cwd) return ""
    var parts = proc.cwd.split("/").filter(function(s) { return s.length > 0 })
    var base = root.clamp(parts.length ? parts[parts.length - 1] : proc.cwd, 40)
    var cmd = root.clamp((proc.cmd || "").trim().replace(/\s+/g, " "), 48)
    return cmd ? base + " — " + cmd : ""
  }

  readonly property int maxRows: 200

  function parsePorts(text, windowInfo, procInfo) {
    var lines = text.split("\n")
    var seen = ({})
    var out = []

    for (var i = 0; i < lines.length && out.length < root.maxRows; i++) {
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

      out.push({ proto: proto, port: port, address: address, process: process, pid: pid,
                 startTime: proc ? (proc.start || "") : "", isApp: isApp, label: label, detail: detail })
    }

    out.sort(function(a, b) { return a.port - b.port })
    return out
  }

  // A wedged hyprctl or ss would otherwise leave scanProc.running true
  // forever, and refresh() would silently no-op from then on. A full scan at
  // the 200-pid cap measures ~1.6s, so 10s is generous headroom for a loaded
  // machine while still landing inside the 15s idle refresh interval.
  Timer {
    id: scanWatchdog
    interval: 10000
    onTriggered: if (scanProc.running) scanProc.running = false
  }

  Process {
    id: scanProc
    command: ["/usr/bin/bash", "-c", root.scanScript]
    onRunningChanged: {
      if (running) scanWatchdog.restart()
      else scanWatchdog.stop()
    }
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

  // requestKill early-returns while killProc is running and busyKey is only
  // cleared on exit, so a wedged kill would disable every row's button for
  // the rest of the session.
  Timer {
    id: killWatchdog
    interval: 5000
    onTriggered: if (killProc.running) killProc.running = false
  }

  Process {
    id: killProc
    property string targetKey: ""
    onRunningChanged: {
      if (running) killWatchdog.restart()
      else killWatchdog.stop()
    }
    onExited: function(exitCode) {
      root.busyKey = ""
      if (exitCode !== 0) {
        root.errorKey = targetKey
        root.errorText = exitCode === 3 ? "Already gone"
          : exitCode === 4 ? "Process changed; refreshed"
          : "Couldn't stop it (permission?)"
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

  Grid {
    id: row
    anchors.centerIn: parent
    columns: root.vertical ? 1 : 2
    rowSpacing: 2
    columnSpacing: 4

    Text {
      text: ""
      color: root.iconColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 14
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      visible: root.ownPorts.length > 0
      text: String(root.ownPorts.length)
      color: root.iconColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 11
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
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
    onOpenRequested: function(p) { root.openInBrowser(p) }
    onRefreshRequested: root.refresh()
  }

  Component.onCompleted: refresh()
}
