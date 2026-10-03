import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Near-Earth asteroid radar.
//
// Data: JPL's close-approach API lists what passes within ~20 lunar distances
// over the coming week; JPL Horizons then supplies each object's geocentric
// position vectors around its approach, plus the Moon's orbit and the Sun's
// direction for context. Everything is fetched in one background pass every
// few hours and cached, and positions in between are interpolated locally,
// so an open panel makes no network calls at all.
//
// Drawing: a hand-rolled projection (Model.project) feeding Shape strokes and
// plain items — no QtQuick3D dependency, so the plugin runs on a stock
// Omarchy install.
Panel {
  id: root
  moduleName: "mechurisr.asteroid-radar"
  ipcTarget: "mechurisr.asteroid-radar"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------ settings

  readonly property int refreshHours: Math.max(1, parseInt(setting("refreshHours", 6), 10) || 6)
  readonly property real maxDistLd: Math.max(2, Math.min(80, parseFloat(setting("maxDistanceLd", 20)) || 20))
  readonly property int maxObjects: Math.max(1, Math.min(30, parseInt(setting("maxObjects", 15), 10) || 15))

  // ------------------------------------------------------------ state

  property var asteroids: []        // parsed CAD rows, each with .path
  property var moonPath: []
  property var sunDir: null
  property double fetchedAt: 0
  property bool loading: false
  property string lastError: ""

  property double now: Date.now()
  property double timeOffset: 0     // time scrub, ms
  readonly property double viewTime: now + timeOffset

  property int selected: 0
  property real yaw: -0.6
  property real pitch: 1.05
  property real zoom: 1.0
  property bool logScale: true
  property bool autoRotate: true

  readonly property var byTime: {
    var list = asteroids.slice()
    list.sort(function(a, b) { return a.approachAt - b.approachAt })
    return list
  }

  readonly property var selectedItem: byTime.length > 0
    ? byTime[Math.max(0, Math.min(selected, byTime.length - 1))] : null

  readonly property var nextApproach: {
    for (var i = 0; i < byTime.length; i++)
      if (byTime[i].approachAt > now) return byTime[i]
    return null
  }

  // Anything inside the Moon's orbit within the next two days.
  readonly property bool alert: {
    for (var i = 0; i < byTime.length; i++) {
      var a = byTime[i]
      if (a.distLd < 1 && a.approachAt > now - Model.HOUR_MS && a.approachAt < now + 2 * Model.DAY_MS) return true
    }
    return false
  }

  // Nerd Font fae-comet. The Unicode comet (U+2604) falls back to the colour
  // emoji font, and Qt ignores the U+FE0E text-presentation selector.
  readonly property string glyph: "\uE26D"

  readonly property string label: {
    if (asteroids.length === 0) return loading ? glyph + " …" : (lastError ? glyph + " —" : glyph)
    if (!nextApproach) return glyph + " " + asteroids.length
    return glyph + " " + nextApproach.distLd.toFixed(1) + "LD"
  }

  // ------------------------------------------------------ panel lifecycle

  function open() { openFromHotkey() }

  function openFromHotkey() {
    root.controller.show()
    now = Date.now()
    if (isStale()) refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function isStale() {
    return Date.now() - fetchedAt > refreshHours * Model.HOUR_MS
  }

  function moveSelection(delta) {
    if (byTime.length === 0) return
    selected = (selected + delta + byTime.length) % byTime.length
    radar.requestPaint()
  }

  function resetView() {
    timeOffset = 0
    zoom = 1.0
    yaw = -0.6
    pitch = 1.05
    radar.requestPaint()
  }

  // ------------------------------------------------------------ fetching

  function isoDate(ms) {
    return new Date(ms).toISOString().slice(0, 10)
  }

  function refresh() {
    if (loading) return
    loading = true
    lastError = ""
    var t = Date.now()
    cadProc.command = ["curl", "-fsS", "--max-time", "20",
      "https://ssd-api.jpl.nasa.gov/cad.api?date-min=" + isoDate(t - Model.DAY_MS)
        + "&date-max=" + isoDate(t + 8 * Model.DAY_MS)
        + "&dist-max=" + (maxDistLd / Model.AU_LD).toFixed(4)
        + "&sort=dist&fullname=true&diameter=true"]
    cadProc.running = true
  }

  function fail(message) {
    loading = false
    lastError = message
  }

  // "key|command|startJD|stopJD|intervals" per argument. Horizons asks for
  // sequential rather than parallel requests, so the loop is serial.
  readonly property string horizonsScript:
    'for spec in "$@"; do\n' +
    '  key=${spec%%|*}; rest=${spec#*|}\n' +
    '  cmd=${rest%%|*}; rest=${rest#*|}\n' +
    '  start=${rest%%|*}; rest=${rest#*|}\n' +
    '  stop=${rest%%|*}; steps=${rest#*|}\n' +
    '  printf "===%s===\\n" "$key"\n' +
    '  curl -fsS --max-time 20 -G "https://ssd.jpl.nasa.gov/api/horizons.api" \\\n' +
    '    --data-urlencode "format=json" --data-urlencode "COMMAND=\'$cmd\'" \\\n' +
    '    --data-urlencode "OBJ_DATA=NO" --data-urlencode "MAKE_EPHEM=YES" \\\n' +
    '    --data-urlencode "EPHEM_TYPE=VECTORS" --data-urlencode "CENTER=\'500@399\'" \\\n' +
    '    --data-urlencode "START_TIME=\'JD$start\'" --data-urlencode "STOP_TIME=\'JD$stop\'" \\\n' +
    '    --data-urlencode "STEP_SIZE=\'$steps\'" --data-urlencode "VEC_TABLE=1" \\\n' +
    '    --data-urlencode "REF_PLANE=ECLIPTIC" --data-urlencode "OUT_UNITS=AU-D" \\\n' +
    '    --data-urlencode "CSV_FORMAT=YES" --data-urlencode "VEC_LABELS=NO"\n' +
    '  printf "\\n"\n' +
    'done\n'

  property var pendingAsteroids: []

  function fetchVectors(list) {
    var t = Date.now()
    var specs = []
    var jd = function(ms) { return Model.msToJd(ms).toFixed(5) }
    specs.push("moon|301|" + jd(t - 14 * Model.DAY_MS) + "|" + jd(t + 14 * Model.DAY_MS) + "|120")
    specs.push("sun|10|" + jd(t) + "|" + jd(t + Model.DAY_MS) + "|1")
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      // Cover now, the approach itself, and enough either side to read the
      // shape of the pass, plus margin for the cache's lifetime.
      var from = Math.min(t, a.approachAt) - 1.5 * Model.DAY_MS
      var to = Math.max(t, a.approachAt) + 1.5 * Model.DAY_MS
      specs.push("a" + i + "|DES=" + a.des + ";|" + jd(from) + "|" + jd(to) + "|160")
    }
    pendingAsteroids = list
    horizonsProc.command = ["sh", "-c", horizonsScript, "omarchy-asteroid-radar"].concat(specs)
    horizonsProc.running = true
  }

  function applyVectors(text) {
    var sections = Model.splitSections(text)
    var list = pendingAsteroids
    for (var i = 0; i < list.length; i++)
      list[i].path = Model.parseHorizons(sections["a" + i] || "")
    var moon = Model.parseHorizons(sections["moon"] || "")
    var sun = Model.parseHorizons(sections["sun"] || "")
    if (moon.length === 0 && list.every(function(a) { return a.path.length === 0 })) {
      fail("Horizons returned no vectors")
      return
    }
    asteroids = list
    moonPath = moon
    sunDir = sun.length > 0 ? sun[0] : null
    fetchedAt = Date.now()
    loading = false
    selected = defaultSelection()
    cacheFile.setText(JSON.stringify({
      version: 1, fetchedAt: fetchedAt, asteroids: asteroids, moonPath: moonPath, sunDir: sunDir
    }))
    radar.requestPaint()
  }

  // Open on the next object still to come, which is what you want to see.
  function defaultSelection() {
    var list = byTime
    for (var i = 0; i < list.length; i++)
      if (list[i].approachAt > Date.now()) return i
    return 0
  }

  Process {
    id: cadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list
        try {
          list = Model.parseCad(String(text || ""))
        } catch (e) {
          root.fail("close-approach API unreachable")
          return
        }
        list.sort(function(a, b) { return a.distLd - b.distLd })
        list = list.slice(0, root.maxObjects)
        if (list.length === 0) {
          root.asteroids = []
          root.fetchedAt = Date.now()
          root.loading = false
          return
        }
        root.fetchVectors(list)
      }
    }
  }

  Process {
    id: horizonsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyVectors(String(text || ""))
    }
  }

  FileView {
    id: cacheFile
    path: Quickshell.env("HOME") + "/.cache/omarchy-asteroid-radar.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (data.version === 1) {
          root.asteroids = data.asteroids || []
          root.moonPath = data.moonPath || []
          root.sunDir = data.sunDir || null
          root.fetchedAt = data.fetchedAt || 0
          root.selected = root.defaultSelection()
        }
      } catch (e) {}
      if (root.isStale()) root.refresh()
    }
    onLoadFailed: root.refresh()
  }

  // Seconds while the panel is open, minutes otherwise (the bar label only
  // needs to notice an approach passing).
  Timer {
    interval: root.opened ? 1000 : 60000
    running: true
    repeat: true
    onTriggered: {
      root.now = Date.now()
      if (!root.opened && root.isStale()) root.refresh()
      radar.requestPaint()
    }
  }

  // Auto-rotation runs for a while after the panel opens or is touched, then
  // rests: every frame re-projects the scene, and a panel left open should not
  // keep a core busy.
  property bool spinAwake: false

  function wake() {
    spinAwake = true
    spinIdle.restart()
  }

  onOpenedChanged: if (opened) wake()

  Timer {
    id: spinIdle
    interval: 20000
    onTriggered: root.spinAwake = false
  }

  Timer {
    interval: 50
    running: root.opened && root.autoRotate && root.spinAwake && !dragArea.pressed
    repeat: true
    onTriggered: {
      root.yaw += 0.0045
      radar.requestPaint()
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function spin(mode: string): string {
      root.autoRotate = mode === "on" ? true : mode === "off" ? false : !root.autoRotate
      root.wake()
      return root.autoRotate ? "on" : "off"
    }
    function status(): string {
      if (root.asteroids.length === 0) return root.loading ? "loading" : (root.lastError || "no close approaches")
      var n = root.nextApproach
      if (!n) return root.asteroids.length + " objects, all passed"
      return n.name + " " + Model.fmtLd(n.distLd) + " " + Model.fmtRelative(n.approachAt, Date.now())
    }
  }

  // ------------------------------------------------------------ the panel

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.6)
  readonly property color accent: Color.accent
  readonly property color warn: Color.urgent

  // Approach list column widths, shared by the heading row and each row.
  readonly property real colName: Style.space(110)
  readonly property real colTime: Style.space(150)
  readonly property real colWhen: Style.space(100)
  readonly property real colDist: Style.space(90)
  readonly property real colSize: Style.space(70)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(600))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: { root.autoRotate = !root.autoRotate; root.wake() }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
        if (dx !== 0) { root.yaw += dx * 0.15; radar.requestPaint() }
      }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "s") { root.logScale = !root.logScale; radar.requestPaint() }
        else if (text === "]") { root.timeOffset += 3 * Model.HOUR_MS; radar.requestPaint() }
        else if (text === "[") { root.timeOffset -= 3 * Model.HOUR_MS; radar.requestPaint() }
        else if (text === "0") root.resetView()
        else if (text === "+" || text === "=") { root.zoom = Math.min(4, root.zoom * 1.2); radar.requestPaint() }
        else if (text === "-") { root.zoom = Math.max(0.5, root.zoom / 1.2); radar.requestPaint() }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---------------------------------------------------- header

        Item {
          width: parent.width
          height: title.implicitHeight

          Text {
            id: title
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            text: "NEAR-EARTH ASTEROIDS"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1.5
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: title.verticalCenter
            color: root.lastError ? root.warn : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: root.loading ? "fetching from JPL…"
              : root.lastError ? root.lastError
              : root.fetchedAt > 0 ? "JPL · updated " + Model.fmtRelative(root.fetchedAt, root.now)
              : ""
          }
        }

        // ---------------------------------------------------- radar

        Item {
          width: parent.width
          height: Math.round(width * 0.72)

          // GPU-drawn: lines are Shape strokes, dots and labels are plain
          // items. A Canvas repaints its whole bitmap on the CPU every frame,
          // which cost ~20 ms a frame at this size while spinning.
          Item {
            id: radar
            anchors.fill: parent
            clip: true

            // Screen positions of the last frame's dots, for hover picking.
            property var hits: []
            property int hovered: -1
            property var frame: root.emptyFrame
            property bool _pending: false

            function requestPaint() {
              if (_pending) return
              _pending = true
              Qt.callLater(function() {
                radar._pending = false
                if (root.opened && radar.width > 0) radar.frame = root.computeFrame(radar.width, radar.height)
              })
            }

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Connections {
              target: root
              function onOpenedChanged() { radar.requestPaint() }
            }

            Shape {
              anchors.fill: parent
              preferredRendererType: Shape.CurveRenderer
              z: -10

              ShapePath {
                strokeColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.rings }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.sun }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.moon }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.16)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.dimPast }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.38)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.dimFuture }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.warn.r, root.warn.g, root.warn.b, 0.3)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.warnPast }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.warn.r, root.warn.g, root.warn.b, 0.75)
                strokeWidth: 1
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.warnFuture }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
                strokeWidth: 2
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.hiPast }
              }
              ShapePath {
                strokeColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.95)
                strokeWidth: 2
                fillColor: "transparent"
                PathMultiline { paths: radar.frame.hiFuture }
              }
            }

            // Distance-ring labels.
            Repeater {
              model: radar.frame.ringLabels.length
              Text {
                required property int index
                readonly property var l: radar.frame.ringLabels[index]
                x: l ? l.x + 3 : 0
                y: l ? l.y - height - 1 : 0
                text: l ? l.text : ""
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              visible: radar.frame.sunLabel !== null
              x: visible ? radar.frame.sunLabel.x + 4 : 0
              y: visible ? radar.frame.sunLabel.y - height / 2 : 0
              text: "☉ Sun"
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Closest-approach markers.
            Repeater {
              model: root.byTime.length
              Rectangle {
                required property int index
                readonly property var c: radar.frame.approaches[index] || null
                visible: c !== null
                x: c ? c.x - width / 2 : 0
                y: c ? c.y - height / 2 : 0
                width: 7; height: 7; radius: 3.5
                color: "transparent"
                border.width: 1
                border.color: c ? Qt.rgba(c.color.r, c.color.g, c.color.b, c.hi ? 0.9 : 0.45) : "transparent"
                z: -5
              }
            }

            // Earth sits at depth 0: dots with negative depth draw behind it.
            Rectangle {
              readonly property real r: Math.max(4, 5 * root.zoom)
              x: radar.width / 2 - r
              y: radar.height / 2 - r
              width: r * 2; height: r * 2; radius: r
              color: root.accent
              border.width: 1
              border.color: Qt.lighter(root.accent, 1.4)
              z: 0
            }

            Item {
              visible: radar.frame.moonDot !== null
              x: visible ? radar.frame.moonDot.x : 0
              y: visible ? radar.frame.moonDot.y : 0
              z: visible ? radar.frame.moonDot.depth : 0

              Rectangle {
                x: -2.5; y: -2.5; width: 5; height: 5; radius: 2.5
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.8)
              }
              Text {
                x: 5; y: -height / 2
                text: "Moon"
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: root.byTime.length
              Item {
                required property int index
                readonly property var d: radar.frame.dots[index] || null
                readonly property bool hi: d !== null && (d.sel || d.hov)
                visible: d !== null
                x: d ? d.x : 0
                y: d ? d.y : 0
                z: d ? d.depth : 0

                Rectangle {
                  readonly property real s: parent.d ? parent.d.size : 2
                  x: -s; y: -s; width: s * 2; height: s * 2; radius: s
                  color: parent.d ? parent.d.color : "transparent"
                  opacity: parent.hi ? 1 : 0.85
                }
                Rectangle {
                  visible: parent.hi
                  readonly property real s: (parent.d ? parent.d.size : 2) + 4
                  x: -s; y: -s; width: s * 2; height: s * 2; radius: s
                  color: "transparent"
                  border.width: 1
                  border.color: parent.d ? Qt.rgba(parent.d.color.r, parent.d.color.g, parent.d.color.b, 0.6) : "transparent"
                }
                Column {
                  visible: parent.hi
                  x: (parent.d ? parent.d.size : 2) + 6
                  y: -height / 2
                  Text {
                    text: parent.parent.d ? parent.parent.d.name : ""
                    // Names come from the JPL API; never parse them as rich text.
                    textFormat: Text.PlainText
                    color: parent.parent.d ? parent.parent.d.color : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    text: parent.parent.d ? Model.fmtLd(parent.parent.d.dist) : ""
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.7)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          MouseArea {
            id: dragArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            property real lastX: 0
            property real lastY: 0
            property bool moved: false
            cursorShape: radar.hovered >= 0 ? Qt.PointingHandCursor : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

            onPressed: function(m) { lastX = m.x; lastY = m.y; moved = false; root.wake() }
            onPositionChanged: function(m) {
              if (pressed) {
                var dx = m.x - lastX, dy = m.y - lastY
                if (Math.abs(dx) + Math.abs(dy) > 2) moved = true
                root.yaw += dx * 0.008
                root.pitch = Math.max(0, Math.min(Math.PI, root.pitch - dy * 0.008))
                lastX = m.x; lastY = m.y
                radar.requestPaint()
              } else {
                var h = root.hitAt(m.x, m.y)
                if (h !== radar.hovered) { radar.hovered = h; radar.requestPaint() }
              }
            }
            onExited: { radar.hovered = -1; radar.requestPaint() }
            onClicked: function(m) {
              if (moved) return
              var h = root.hitAt(m.x, m.y)
              if (h >= 0) { root.selected = h; radar.requestPaint() }
            }
            onWheel: function(w) {
              root.zoom = Math.max(0.5, Math.min(4, root.zoom * (w.angleDelta.y > 0 ? 1.12 : 1 / 1.12)))
              radar.requestPaint()
            }
          }

          Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(4)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: (root.timeOffset !== 0 ? "T" + (root.timeOffset > 0 ? "+" : "−")
                    + Math.abs(root.timeOffset / Model.HOUR_MS) + "h · " : "")
              + Model.fmtLocal(root.viewTime) + " · " + (root.logScale ? "log scale" : "linear scale")
          }

          // Legend-style card for the selected object, over the radar's
          // bottom-right corner. No MouseArea, so drags pass through it.
          Rectangle {
            id: infoCard
            readonly property var a: root.selectedItem
            readonly property var cur: a ? Model.positionAt(a.path, root.viewTime) : null
            visible: a !== null
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(6)
            width: infoColumn.implicitWidth + Style.space(20)
            height: infoColumn.implicitHeight + Style.space(14)
            radius: Style.space(6)
            color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.78)
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)

            Column {
              id: infoColumn
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                text: infoCard.a ? infoCard.a.name : ""
                // Names come from the JPL API; never parse them as rich text.
                textFormat: Text.PlainText
                color: infoCard.a && infoCard.a.distLd < 1 ? root.warn : root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Grid {
                columns: 2
                columnSpacing: Style.space(12)
                rowSpacing: Style.space(2)

                Repeater {
                  model: infoCard.a ? [
                    "min", Model.fmtLd(infoCard.a.distLd),
                    "", Model.fmtKm(infoCard.a.distLd * Model.LD_KM),
                    "speed", infoCard.a.velocity.toFixed(1) + " km/s",
                    "size", Model.fmtSize(infoCard.a.diameterKm),
                    "now", infoCard.cur && infoCard.cur.inRange ? Model.fmtLd(Model.length3(infoCard.cur)) : "—"
                  ] : []

                  Text {
                    required property var modelData
                    required property int index
                    readonly property bool isLabel: index % 2 === 0
                    // Grid skips zero-width items, which would shift every
                    // later cell; the blank label under "min" needs a size.
                    width: Math.max(implicitWidth, 1)
                    text: modelData
                    color: isLabel ? root.dim : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        // ---------------------------------------------------- list

        Column {
          width: parent.width
          spacing: 0

          // Column headings; widths are shared with the rows below.
          Row {
            visible: root.byTime.length > 0
            leftPadding: Style.space(4)
            bottomPadding: Style.space(4)
            spacing: Style.space(8)

            Repeater {
              model: [
                { text: "OBJECT", width: root.colName, right: false },
                { text: "CLOSEST APPROACH", width: root.colTime, right: false },
                { text: "WHEN", width: root.colWhen, right: false },
                { text: "MIN DISTANCE", width: root.colDist, right: true },
                { text: "EST. SIZE", width: root.colSize, right: true }
              ]
              Text {
                required property var modelData
                width: modelData.width
                horizontalAlignment: modelData.right ? Text.AlignRight : Text.AlignLeft
                text: modelData.text
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
            }
          }

          Text {
            visible: root.asteroids.length === 0 && !root.loading
            leftPadding: Style.space(4)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: root.lastError ? "No data — press r to retry" : "Nothing passes within " + root.maxDistLd + " LD this week"
          }

          Repeater {
            model: root.byTime

            Rectangle {
              required property var modelData
              required property int index
              readonly property bool isSelected: index === root.selected
              readonly property bool passed: modelData.approachAt < root.now
              width: column.width
              height: rowText.implicitHeight + Style.space(6)
              radius: Style.space(4)
              color: isSelected ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent"

              Row {
                id: rowText
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                spacing: Style.space(8)
                opacity: passed ? 0.5 : 1

                Text {
                  width: root.colName
                  elide: Text.ElideRight
                  text: modelData.name
                  // Names come from the JPL API; never parse them as rich text.
                  textFormat: Text.PlainText
                  color: modelData.distLd < 1 ? root.warn : (isSelected ? root.accent : root.fg)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: isSelected
                }
                Text {
                  width: root.colTime
                  text: Model.fmtLocal(modelData.approachAt)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: root.colWhen
                  text: Model.fmtRelative(modelData.approachAt, root.now)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: root.colDist
                  horizontalAlignment: Text.AlignRight
                  text: Model.fmtLd(modelData.distLd)
                  color: modelData.distLd < 1 ? root.warn : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: root.colSize
                  horizontalAlignment: Text.AlignRight
                  text: Model.fmtSize(modelData.diameterKm)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                anchors.fill: parent
                onClicked: { root.selected = index; radar.requestPaint() }
              }
            }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: "drag rotate · wheel zoom · j k select · [ ] time · s scale · space spin · 0 reset · r refresh"
        }
      }
    }
  }

  // ------------------------------------------------------------ drawing

  readonly property var emptyFrame: ({
    rings: [], ringLabels: [], sun: [], sunLabel: null, moon: [], moonDot: null,
    dimPast: [], dimFuture: [], warnPast: [], warnFuture: [], hiPast: [], hiFuture: [],
    approaches: [], dots: []
  })

  function hitAt(x, y) {
    var best = -1, bestD = 12 * 12
    var hits = radar.hits
    for (var i = 0; i < hits.length; i++) {
      var dx = hits[i].x - x, dy = hits[i].y - y
      var d = dx * dx + dy * dy
      if (d < bestD) { bestD = d; best = hits[i].index }
    }
    return best
  }

  // Log-scaled geometry depends only on the data and the scale mode, so it is
  // built once and reused every frame; per frame only the rotation runs.
  property var _geom: null

  onAsteroidsChanged: _geom = null
  onMoonPathChanged: _geom = null
  onLogScaleChanged: _geom = null
  onMaxDistLdChanged: _geom = null

  function scaledPath(path, step) {
    var out = []
    for (var i = 0; i < path.length; i += step) {
      var s = Model.scalePoint(path[i], logScale, maxDistLd)
      out.push({ t: path[i].t, x: s.x, y: s.y, z: s.z })
    }
    // Always keep the final sample so the pass reaches its end.
    if (path.length > 0 && (path.length - 1) % step !== 0) {
      var e = Model.scalePoint(path[path.length - 1], logScale, maxDistLd)
      out.push({ t: path[path.length - 1].t, x: e.x, y: e.y, z: e.z })
    }
    return out
  }

  function geometry() {
    if (_geom) return _geom
    var rings = []
    var radii = logScale ? [2, 5, 10, 20, 40] : [5, 10, 20, 40]
    for (var ri = 0; ri < radii.length; ri++) {
      if (radii[ri] > maxDistLd * 1.01) break
      rings.push({ ld: radii[ri], r: Model.scaleRadius(radii[ri], logScale, maxDistLd) })
    }
    var paths = []
    var list = byTime
    for (var i = 0; i < list.length; i++) paths.push(scaledPath(list[i].path || [], 3))
    _geom = { rings: rings, paths: paths, moon: scaledPath(moonPath, 3) }
    return _geom
  }

  // Projects the scene for the current camera and time into flat screen
  // geometry for the Shape and item layers.
  function computeFrame(w, h) {
    var g = geometry()
    var f = {
      rings: [], ringLabels: [], sun: [], sunLabel: null, moon: [], moonDot: null,
      dimPast: [], dimFuture: [], warnPast: [], warnFuture: [], hiPast: [], hiFuture: [],
      approaches: [], dots: []
    }
    var cx = w / 2, cy = h / 2
    var R = Math.min(w, h) * 0.46 * zoom
    var persp = 0.25
    var maxLd = maxDistLd
    var t = viewTime
    var cyw = Math.cos(yaw), syw = Math.sin(yaw)
    var cp = Math.cos(pitch), sp = Math.sin(pitch)

    // Same maths as Model.project, inlined for the hot loops; points here are
    // already radially scaled.
    var X = 0, Y = 0, D = 0, F = 1
    function proj(x, y, z) {
      var x1 = x * cyw - y * syw
      var y1 = x * syw + y * cyw
      var y2 = y1 * cp - z * sp
      var z2 = y1 * sp + z * cp
      F = 1 / (1 + y2 * persp)
      X = cx + x1 * R * F
      Y = cy - z2 * R * F
      D = -y2
    }
    function P(p) {
      var s = Model.scalePoint(p, logScale, maxLd)
      proj(s.x, s.y, s.z)
      return { x: X, y: Y, depth: D, f: F }
    }
    function line(pts, from, to) {
      var out = []
      for (var i = from; i <= to; i++) {
        proj(pts[i].x, pts[i].y, pts[i].z)
        out.push(Qt.point(X, Y))
      }
      return out
    }

    for (var ri = 0; ri < g.rings.length; ri++) {
      var rr = g.rings[ri].r
      var ring = []
      for (var k = 0; k <= 48; k++) {
        var ang = k / 48 * 2 * Math.PI
        proj(rr * Math.cos(ang), rr * Math.sin(ang), 0)
        ring.push(Qt.point(X, Y))
      }
      f.rings.push(ring)
      proj(rr * Math.cos(-yaw - 0.3), rr * Math.sin(-yaw - 0.3), 0)
      f.ringLabels.push({ x: X, y: Y, text: g.rings[ri].ld + " LD" })
    }

    // Sun direction: a dashed spoke to the edge of the map, built from short
    // segments so it does not depend on renderer dash support.
    if (sunDir) {
      var sl = Model.length3(sunDir)
      var edge = Model.scaleRadius(maxLd * 1.15, logScale, maxLd)
      proj(sunDir.x / sl * edge, sunDir.y / sl * edge, sunDir.z / sl * edge)
      var ex = X, ey = Y
      var len = Math.sqrt((ex - cx) * (ex - cx) + (ey - cy) * (ey - cy))
      var n = Math.floor(len / 7)
      for (var si = 0; si < n; si++) {
        var a0 = si / n, a1 = (si + 0.45) / n
        f.sun.push([Qt.point(cx + (ex - cx) * a0, cy + (ey - cy) * a0), Qt.point(cx + (ex - cx) * a1, cy + (ey - cy) * a1)])
      }
      f.sunLabel = { x: ex, y: ey }
    }

    if (g.moon.length > 1) f.moon.push(line(g.moon, 0, g.moon.length - 1))
    var moonNow = Model.positionAt(moonPath, t)
    if (moonNow) f.moonDot = P(moonNow)

    var list = byTime
    var hits = []
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      var pts = g.paths[i]
      f.approaches.push(null)
      f.dots.push(null)
      if (!pts || pts.length < 2) continue
      var isSel = i === selected
      var isHov = i === radar.hovered
      var hi = isSel || isHov
      var isWarn = a.distLd < 1
      var col = hi ? accent : (isWarn ? warn : fg)

      // First sample at or after the view time; the two halves share the
      // samples either side of it so the line has no gap.
      var split = 0
      while (split < pts.length && pts[split].t < t) split++
      var pastEnd = Math.min(split, pts.length - 1)
      var futureStart = Math.max(split - 1, 0)
      var past = hi ? f.hiPast : isWarn ? f.warnPast : f.dimPast
      var future = hi ? f.hiFuture : isWarn ? f.warnFuture : f.dimFuture
      if (pastEnd > 0) past.push(line(pts, 0, pastEnd))
      if (futureStart < pts.length - 1) future.push(line(pts, futureStart, pts.length - 1))

      var ca = Model.positionAt(a.path, a.approachAt)
      if (ca) {
        var cs = P(ca)
        f.approaches[i] = { x: cs.x, y: cs.y, color: col, hi: hi }
      }

      var cur = Model.positionAt(a.path, t)
      if (cur && cur.inRange) {
        var ps = P(cur)
        var size = isNaN(a.diameterKm) ? 2 : Math.max(1.5, Math.min(6, 1.5 + Math.log(1 + a.diameterKm * 1000 / 10)))
        f.dots[i] = {
          x: ps.x, y: ps.y, depth: ps.depth, size: size * (0.8 + 0.4 * ps.f),
          color: col, sel: isSel, hov: isHov, name: a.name, dist: Model.length3(cur)
        }
        hits.push({ x: ps.x, y: ps.y, index: i })
      }
    }
    radar.hits = hits
    return f
  }
}
