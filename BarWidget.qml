import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A mini-map of the windows on this monitor's active workspace, for the
// Hyprland scrolling layout only. Each window is a bracketed glyph drawn at
// full bar height, in the same order the layout shows them. The padding
// inside the brackets grows continuously with the window's size:
//
//   [x] .. [ x ] .. [  x  ]   tiled: narrow .. full monitor width
//   (x) .. ( x ) .. (  x  )   floating: small .. screen-filling
//
// Colour carries the viewport: the focused window is the theme accent,
// windows on screen are the foreground colour, scrolled-off windows are
// muted. Left-click a window to focus it, right-click for settings.
//
// Outside the scrolling layout the widget just says so and does nothing.
BarWidget {
  id: root
  moduleName: "jgarza.scrollmap"

  readonly property var cfg: Model.resolveSettings(settings)
  readonly property int maxExtent: cfg.maxWidth
  readonly property int gap: cfg.gap
  readonly property string iconMode: cfg.iconMode
  readonly property string focusAnimation: cfg.focusAnimation
  readonly property bool anyAnim: focusAnimation !== "none" || cfg.animUnfold || cfg.animFloatLift

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Theme colours ------------------------------------------------------
  // Read straight from colors.toml, re-read live on a theme switch.
  property var themeColors: ({})
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeColors = Model.parseThemeColors(text(), Model.THEME_COLOR_KEYS)
    onFileChanged: reload()
    onLoadFailed: root.themeColors = {}
  }

  readonly property string bgHex: themeColors["background"] || String(Color.background)
  readonly property string fgHex: themeColors["foreground"] || String(root.fg)
  readonly property color accentColor: themeColors["accent"] || Color.accent
  // Muted is lifted toward the foreground if a theme's value would vanish
  // against the bar.
  readonly property color mutedColor: Model.ensureContrast(
    themeColors["muted"] || String(Color.muted), bgHex, fgHex, 1.8)

  // Glyph colour per state.
  function stateColor(state) {
    if (state === "focused") return accentColor
    if (state === "onscreen") return root.fg
    return mutedColor
  }

  // ---- Sizing -------------------------------------------------------------
  // Brackets fill the bar height; labels sit just inside them.
  readonly property int glyphPx: Math.max(10, Math.round(barSize * 0.78))
  readonly property int labelPx: Math.max(9, Math.round(barSize * 0.7))
  readonly property int namePx: Math.max(8, Math.round(barSize * 0.52))
  // Nerd glyphs sit small in their em-box, so they get a larger size than
  // app icons to read at the same visual weight.
  readonly property int nerdPx: Math.max(10, Math.round(barSize * 0.92))

  FontMetrics {
    id: bracketMetrics
    font.family: root.fontFamily
    font.pixelSize: root.glyphPx
  }
  FontMetrics {
    id: nameMetrics
    font.family: root.fontFamily
    font.pixelSize: root.namePx
    font.bold: true
  }

  readonly property real spacePx: Math.max(2, bracketMetrics.advanceWidth(" ") * 0.6)
  readonly property real bracketPx: Math.max(3, bracketMetrics.advanceWidth("["))
  // Along-axis extent of the label box, fixed per mode so the strip width is
  // predictable (and fitPadding can work it out without measuring delegates).
  readonly property real labelBox: {
    if (iconMode === "none") return spacePx
    if (iconMode === "shortname" && !vertical)
      return Math.ceil(nameMetrics.advanceWidth("M".repeat(cfg.nameLength)))
    // Nerd glyphs run a little wider than their pixel size.
    if (iconMode === "nerdfont" && !vertical)
      return Math.ceil(nerdPx * 1.1)
    return labelPx
  }
  // Padding per side, in px, for a window as big as the monitor; smaller
  // windows get proportionally less.
  readonly property int padRange: cfg.padRange
  readonly property real padExponent: cfg.padCurve / 10
  // Window sizes after the curve, for fitPadding.
  readonly property var sizeList: rawSizes.map(function (f) { return Model.padCurve(f, padExponent) })
  property var rawSizes: []
  readonly property real paddingScale: Model.fitPadding(
    sizeList, padRange, 2 * bracketPx + labelBox, gap, maxExtent)

  // Bumped whenever live client/monitor geometry should be re-read.
  property int tick: 0
  property string layoutName: ""
  readonly property bool scrolling: layoutName === "scrolling"

  // ---- Settings popup -----------------------------------------------------
  property bool settingsOpen: false
  readonly property bool opened: settingsOpen
  function open() { settingsOpen = true }
  function close() { settingsOpen = false }
  function toggle() { settingsOpen = !settingsOpen }

  function previewSetting(key, value) {
    var next = Object.assign({}, settings || {})
    next[key] = value
    settings = next
  }
  function saveSetting(key, value) {
    previewSetting(key, value)
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }

  // ---- This bar's monitor and its active workspace -------------------------
  // The bar is built once per monitor; show that monitor's workspace rather
  // than wherever keyboard focus happens to be.
  readonly property string screenName: {
    var _dep = tick
    return String(Screen.name || "")
  }

  function monitorByName(name) {
    var ms = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < ms.length; i++)
      if (ms[i] && String(ms[i].name) === name)
        return ms[i]
    return null
  }

  readonly property var barMonitor: {
    var _dep = tick
    return monitorByName(screenName) || Hyprland.focusedMonitor || null
  }

  readonly property int barWorkspaceId: {
    var m = barMonitor
    if (m && m.activeWorkspace && isFinite(Number(m.activeWorkspace.id)))
      return Number(m.activeWorkspace.id)
    if (m && m.lastIpcObject && m.lastIpcObject.activeWorkspace
        && isFinite(Number(m.lastIpcObject.activeWorkspace.id)))
      return Number(m.lastIpcObject.activeWorkspace.id)
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  }

  // Monitor size in logical pixels, for sizing window padding.
  readonly property var monitorSize: {
    var m = barMonitor
    if (!m)
      return null
    var scale = Number(m.scale) || 1
    var w = Number(m.width) / scale
    var h = Number(m.height) / scale
    return w > 0 && h > 0 ? { width: w, height: h } : null
  }

  // The monitor's visible region in compositor coordinates, along the bar's
  // main axis. Clients whose geometry falls outside this are scrolled off.
  readonly property var viewportRange: {
    var m = barMonitor
    if (!m)
      return null
    var scale = Number(m.scale) || 1
    var mx = Number(m.x)
    var my = Number(m.y)
    var mw = Number(m.width) / scale
    var mh = Number(m.height) / scale
    if (!isFinite(mx) || !isFinite(my) || !(mw > 0) || !(mh > 0))
      return null
    return vertical ? { start: my, end: my + mh } : { start: mx, end: mx + mw }
  }

  // ---- Client list --------------------------------------------------------
  readonly property var clients: {
    var _dep = tick
    if (!scrolling || barWorkspaceId < 0)
      return []
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    return Model.eligibleClients(tops, barWorkspaceId, cfg.showFloating)
  }

  // address -> live client, so delegates can track viewport visibility every
  // tick without the row model being touched.
  readonly property var clientMap: {
    var map = ({})
    for (var i = 0; i < clients.length; i++)
      map[clients[i].address] = clients[i]
    return map
  }

  readonly property string activeAddr: Model.normalizeAddress(
    Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "")

  // Resolve an application icon from its window class. The shell's app library
  // does proper desktop-entry matching; fall back to a raw icon-theme lookup.
  function resolveIcon(cls) {
    var value = String(cls || "")
    if (!value)
      return ""
    if (bar && bar.shell && bar.shell.appLibrary)
      return bar.shell.appLibrary.iconSource(value)
    var direct = Quickshell.iconPath(value, true)
    return direct ? direct : Quickshell.iconPath(value.toLowerCase(), true)
  }

  // ---- Row model ------------------------------------------------------------
  // A ListModel reconciled in place (Model.syncOps) rather than a replaced JS
  // array, so surviving windows keep their delegate and its animations, new
  // ones can unfold in, and closed ones linger as `closing` ghosts while they
  // collapse.
  ListModel { id: rowModel }

  // Delegates created before this flips are the initial population; they
  // appear without the unfold animation.
  property bool ready: false
  Timer {
    id: readyTimer
    interval: 400
    onTriggered: root.ready = true
  }

  function rowOf(item) {
    return {
      address: item.address,
      appClass: item.appClass,
      title: item.title,
      floating: item.floating,
      size: item.size,
      closing: false
    }
  }

  function sync() {
    var items = Model.buildStrip(clients, monitorSize, null, vertical, "")
    var current = []
    for (var i = 0; i < rowModel.count; i++) {
      var r = rowModel.get(i)
      current.push({ address: r.address, closing: r.closing })
    }
    var ops = Model.syncOps(current, items)
    for (var j = 0; j < ops.length; j++) {
      var o = ops[j]
      if (o.op === "close") {
        rowModel.setProperty(o.index, "closing", true)
      } else if (o.op === "insert") {
        rowModel.insert(o.index, rowOf(o.item))
      } else if (o.op === "move") {
        rowModel.move(o.from, o.to, 1)
      } else if (o.op === "update") {
        var want = rowOf(o.item)
        var have = rowModel.get(o.index)
        for (var k in want)
          if (have[k] !== want[k])
            rowModel.setProperty(o.index, k, want[k])
      }
    }
    // Only a window whose app actually closed keeps its ghost row for the
    // collapse; anything that merely left the strip (workspace switch, moved
    // away, floating filtered out) goes at once.
    for (var g = rowModel.count - 1; g >= 0; g--) {
      var row = rowModel.get(g)
      if (row.closing && !(cfg.animUnfold && recentlyNoted(closedAt, row.address)))
        rowModel.remove(g)
    }
    rawSizes = items.map(function (it) { return it.size })
  }

  // Addresses Hyprland just reported as opened / closed (address -> ms), so
  // unfold/collapse play for real app launches and exits only - not for
  // windows that appear or vanish because the workspace changed.
  property var openedAt: ({})
  property var closedAt: ({})
  readonly property int lifecycleWindowMs: 3000

  function noteLifecycle(name, data) {
    var addr = Model.normalizeAddress(String(data || "").split(",")[0])
    if (!addr)
      return
    var map = name === "openwindow" ? openedAt : closedAt
    var now = Date.now()
    for (var k in map)
      if (now - map[k] > lifecycleWindowMs)
        delete map[k]
    map[addr] = now
  }

  function recentlyNoted(map, address) {
    var t = map[address]
    return t !== undefined && Date.now() - t <= lifecycleWindowMs
  }

  // True once per launch: the new window's delegate consumes the entry.
  function takeOpened(address) {
    if (!recentlyNoted(openedAt, address))
      return false
    delete openedAt[address]
    return true
  }

  function removeGhost(address) {
    for (var i = rowModel.count - 1; i >= 0; i--) {
      var r = rowModel.get(i)
      if (r.address === address && r.closing) {
        rowModel.remove(i)
        return
      }
    }
  }

  onClientsChanged: sync()
  onMonitorSizeChanged: sync()
  onVerticalChanged: sync()

  // The focused window's delegate, for the slide cursor and overflow scroll.
  property WindowItem focusedItem: null

  function focusClient(address) {
    var a = Model.normalizeAddress(address)
    if (!a)
      return
    if (Hyprland.usingLua)
      Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + a + "\" })")
    else
      Hyprland.dispatch("focuswindow address:" + a)
  }

  function probeLayout() {
    if (!layoutProbe.running)
      layoutProbe.running = true
  }

  function bump() {
    Hyprland.refreshToplevels()
    if (Hyprland.refreshMonitors)
      Hyprland.refreshMonitors()
    tick = (tick + 1) & 0x3fffffff
  }

  // A short fast-poll after a compositor event, to follow the scroll animation
  // to its resting place; steady state is just the slow safety poll.
  function burst() {
    bump()
    burstTimer.count = 0
    burstTimer.restart()
  }

  // ---- Geometry -------------------------------------------------------------
  readonly property real contentLen: vertical ? strip.implicitHeight : strip.implicitWidth
  readonly property real viewLen: Math.min(contentLen, maxExtent)
  readonly property bool overflowing: contentLen > viewLen + 0.5

  // Keep the focused window centred when the strip overflows maxWidth.
  readonly property real scrollTarget: {
    if (!overflowing || !focusedItem)
      return 0
    var center = vertical
      ? focusedItem.y + focusedItem.height / 2
      : focusedItem.x + focusedItem.width / 2
    return Math.max(0, Math.min(contentLen - viewLen, center - viewLen / 2))
  }
  property real scrollOffset: scrollTarget
  Behavior on scrollOffset {
    enabled: root.anyAnim
    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
  }

  readonly property bool hasRows: rowModel.count > 0

  visible: true
  implicitWidth: vertical
    ? barSize
    : (scrolling
      ? (hasRows ? Math.ceil(viewLen) : 0)
      : Math.ceil(placeholder.implicitWidth + Style.space(8)))
  implicitHeight: vertical
    ? (scrolling
      ? (hasRows ? Math.ceil(viewLen) : 0)
      : Math.ceil(placeholder.implicitHeight + Style.space(8)))
    : barSize

  Behavior on implicitWidth {
    enabled: root.anyAnim && !root.vertical
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }
  Behavior on implicitHeight {
    enabled: root.anyAnim && root.vertical
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  Process {
    id: layoutProbe
    command: ["hyprctl", "getoption", "general:layout", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          root.layoutName = String(parsed.str || "").trim()
        } catch (e) {
        }
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name)
        return
      var n = String(event.name)
      if (n === "openwindow" || n === "closewindow")
        root.noteLifecycle(n, event.data)
      if (n === "configreloaded") {
        root.probeLayout()
        root.burst()
        return
      }
      if (n.indexOf("window") !== -1 || n.indexOf("workspace") !== -1
          || n.indexOf("monitor") !== -1 || n === "changefloatingmode"
          || n === "fullscreen" || n === "activelayout")
        root.burst()
    }
  }

  // Fast poll that runs for ~2s after an event, then stops.
  Timer {
    id: burstTimer
    interval: 180
    repeat: true
    property int count: 0
    onTriggered: {
      root.bump()
      if (++count >= 11)
        stop()
    }
  }

  // Safety net for viewport shifts that raise no event (plain scroll binds).
  Timer {
    interval: 2500
    running: root.visible && root.scrolling
    repeat: true
    onTriggered: root.bump()
  }

  // Layout can change under us; re-check periodically and on config reload.
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.probeLayout()
  }

  Text {
    id: placeholder
    anchors.centerIn: parent
    visible: !root.scrolling
    text: "only for scrollable layout"
    color: root.fg
    opacity: 0.65
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  // ---- Strip ------------------------------------------------------------------
  Item {
    id: viewport
    anchors.centerIn: parent
    visible: root.scrolling && root.hasRows
    width: root.vertical ? root.barSize : root.viewLen
    height: root.vertical ? root.viewLen : root.barSize
    clip: root.overflowing

    Item {
      id: content
      x: root.vertical ? 0 : -root.scrollOffset
      y: root.vertical ? -root.scrollOffset : 0
      width: strip.implicitWidth
      height: strip.implicitHeight

      Grid {
        id: strip
        columns: root.vertical ? 1 : Math.max(1, rowModel.count)
        spacing: root.gap
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter

        move: Transition {
          enabled: root.anyAnim
          NumberAnimation { properties: "x,y"; duration: 180; easing.type: Easing.OutCubic }
        }

        Repeater {
          model: rowModel
          delegate: WindowItem {}
        }
      }

      // Slide cursor: one accent underline (leading edge on a vertical bar)
      // that glides to whichever window is focused.
      Rectangle {
        id: cursor
        readonly property WindowItem target: root.focusedItem && root.focusedItem.focused
          ? root.focusedItem : null
        readonly property real thick: 2
        visible: root.focusAnimation === "slideCursor" && target !== null
        color: root.accentColor
        radius: thick / 2
        x: target ? (root.vertical ? 0 : target.x + root.bracketPx * 0.5) : 0
        y: target ? (root.vertical ? target.y + root.bracketPx * 0.5 : root.barSize - thick - 1) : 0
        width: target ? (root.vertical ? thick : Math.max(thick, target.width - root.bracketPx)) : 0
        height: target ? (root.vertical ? Math.max(thick, target.height - root.bracketPx) : thick) : 0

        Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      }
    }

    // Edge fades hint at windows clipped off either end of an overflowing strip.
    EdgeFade { leading: true; shown: root.overflowing && root.scrollOffset > 0.5 }
    EdgeFade {
      leading: false
      shown: root.overflowing && root.scrollOffset < root.contentLen - root.viewLen - 0.5
    }
  }

  // Right-click anywhere on the widget opens the settings popup. Left presses
  // are not accepted here, so they fall through to the per-window handlers.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    onClicked: root.toggle()
  }

  // ---- One window ---------------------------------------------------------------
  component WindowItem: Item {
    id: win

    required property int index
    required property string address
    required property string appClass
    required property string title
    required property bool floating
    required property real size
    required property bool closing

    readonly property var live: root.clientMap[address] || null
    readonly property real visibleFraction: {
      var v = root.viewportRange
      if (!v || !live)
        return 1
      var s = root.vertical ? live.y : live.x
      var e = s + (root.vertical ? live.h : live.w)
      return Model.overlapFraction(s, e, v.start, v.end)
    }
    readonly property bool focused: !closing && root.activeAddr !== ""
      && address === root.activeAddr
    readonly property string winState: Model.stateFor(focused, visibleFraction)
    readonly property bool hovered: hoverArea.containsMouse

    property color tone: root.stateColor(winState)
    Behavior on tone { enabled: root.anyAnim; ColorAnimation { duration: 160 } }

    readonly property var brackets: Model.bracketsFor(floating)

    // ---- Animated state. Animations only ever drive these plain properties
    // (or overlay items), never a bound colour/position, so bindings survive.
    // Window size as a 0..1 fraction of the monitor; tweens on every resize.
    property real padFrac: size
    Behavior on padFrac {
      enabled: root.anyAnim
      NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }
    // 0 = folded "][" with no label, 1 = open. Drives unfold/collapse.
    property real unfold: 1
    // Extra bracket offset (space units, outward positive) for snap/breathe;
    // a transform, so it never reflows the strip.
    property real spread: 0
    property real labelScale: 1
    property real labelRot: 0
    property real lift: 0
    property real floatFade: 1
    property real tintAlpha: 0
    property real fringeC: 0
    property real fringeM: 0
    property real neonAlpha: 0
    property real neonScale: 1
    property color neonColor: root.accentColor
    property real ringScale: 1
    property real ringAlpha: 0

    // The curve runs after the tween, so a resize still animates smoothly.
    readonly property real padPx: Math.max(0, Model.padCurve(padFrac, root.padExponent) * unfold)
      * root.padRange * root.paddingScale

    width: root.vertical ? root.barSize : row.implicitWidth
    height: root.vertical ? row.implicitHeight : root.barSize
    z: focused ? 2 : 1

    onFocusedChanged: {
      if (focused) {
        root.focusedItem = win
        playFocus()
      } else if (root.focusedItem === win) {
        root.focusedItem = null
      }
    }

    onClosingChanged: {
      if (closing) {
        unfoldAnim.stop()
        if (root.cfg.animUnfold)
          collapseAnim.restart()
      } else {
        collapseAnim.stop()
        win.opacity = 1
        if (root.cfg.animUnfold)
          unfoldAnim.restart()
        else
          unfold = 1
      }
    }

    onFloatingChanged: if (root.cfg.animFloatLift && !closing) floatLiftAnim.restart()

    Component.onCompleted: {
      if (focused)
        root.focusedItem = win
      if (root.ready && root.cfg.animUnfold && root.takeOpened(address)) {
        unfold = 0
        unfoldAnim.restart()
      }
    }
    Component.onDestruction: if (root.focusedItem === win) root.focusedItem = null

    function playFocus() {
      switch (root.focusAnimation) {
      case "bracketSnap": snapAnim.restart(); break
      case "breathe": breatheAnim.restart(); break
      case "pop": popAnim.restart(); break
      case "hyprPop": hyprPopAnim.restart(); ringAnim.restart(); break
      case "glitch": glitchAnim.restart(); break
      case "neon": neonAnim.restart(); break
      }
    }

    Rectangle { // hover wash
      anchors.fill: parent
      anchors.margins: 1
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, win.hovered ? 0.10 : 0)
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    Grid {
      id: row
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 5
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter
      opacity: win.floatFade
      transform: [
        Translate { id: jitter },
        Translate { y: root.vertical ? 0 : win.lift; x: root.vertical ? -win.lift : 0 }
      ]

      Bracket {
        owner: win
        glyph: win.unfold < 0.5 ? win.brackets[1] : win.brackets[0]
        shift: -win.spread * root.spacePx
      }

      Item {
        width: root.vertical ? 1 : win.padPx
        height: root.vertical ? win.padPx : 1
      }

      Item { // label box
        id: labelBox
        width: root.vertical ? root.labelPx : root.labelBox
        height: root.vertical
          ? (root.iconMode === "none" ? root.spacePx : root.labelPx)
          : root.labelPx
        opacity: Math.max(0, Math.min(1, win.unfold * 1.4 - 0.4))
        scale: win.labelScale * (0.4 + 0.6 * Math.max(0, win.unfold))
        rotation: win.labelRot

        Image {
          id: iconImg
          anchors.centerIn: parent
          width: root.labelPx
          height: root.labelPx
          visible: root.iconMode === "icons" && status === Image.Ready
          source: root.iconMode === "icons" ? root.resolveIcon(win.appClass) : ""
          sourceSize.width: Math.round(root.labelPx * Screen.devicePixelRatio)
          sourceSize.height: Math.round(root.labelPx * Screen.devicePixelRatio)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
          opacity: win.winState === "focused" ? 1 : (win.winState === "onscreen" ? 0.85 : 0.4)
          Behavior on opacity { enabled: root.anyAnim; NumberAnimation { duration: 160 } }
        }

        // Nerd Font glyph, short class name, or - in icon mode - the first
        // class letter when no icon image resolves.
        Text {
          id: labelText
          anchors.fill: parent
          visible: root.iconMode === "nerdfont" || root.iconMode === "shortname"
            || (root.iconMode === "icons" && iconImg.status !== Image.Ready)
          text: {
            if (root.iconMode === "nerdfont")
              return Model.nerdGlyph(win.appClass)
            if (root.iconMode === "shortname")
              return Model.shortName(win.appClass, root.cfg.nameLength)
            var c = String(win.appClass || "")
            return c ? c.charAt(0).toUpperCase() : "•"
          }
          color: win.tone
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          // Only short names shrink to fit (a vertical bar is narrow); glyphs
          // and the fallback letter draw at full size, centred, even if their
          // line box overhangs the label box.
          fontSizeMode: root.iconMode === "shortname" ? Text.HorizontalFit : Text.FixedSize
          minimumPixelSize: 6
          font.family: root.fontFamily
          font.pixelSize: root.iconMode === "shortname" ? root.namePx
            : (root.iconMode === "nerdfont" ? root.nerdPx : Math.round(root.labelPx * 0.8))
          font.bold: win.focused || root.iconMode === "shortname"
        }

        Text { // neon overlay
          anchors.fill: parent
          visible: labelText.visible && win.neonAlpha > 0
          text: labelText.text
          font: labelText.font
          fontSizeMode: labelText.fontSizeMode
          minimumPixelSize: labelText.minimumPixelSize
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          color: win.neonColor
          opacity: win.neonAlpha
          scale: win.neonScale
        }

        Item { // hypr-pop shockwave ring
          anchors.centerIn: parent
          width: root.labelPx
          height: root.labelPx
          visible: win.ringAlpha > 0
          scale: win.ringScale
          opacity: win.ringAlpha

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 2
            border.color: root.accentColor
          }
        }
      }

      Item {
        width: root.vertical ? 1 : win.padPx
        height: root.vertical ? win.padPx : 1
      }

      Bracket {
        owner: win
        glyph: win.unfold < 0.5 ? win.brackets[0] : win.brackets[1]
        shift: win.spread * root.spacePx
      }
    }

    MouseArea {
      id: hoverArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: !win.closing
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: root.focusClient(win.address)
      onEntered: if (root.bar)
        root.bar.showTooltip(win, String(win.title || win.appClass))
      onExited: if (root.bar) root.bar.hideTooltip(win)
    }

    // ---- Layout animations -------------------------------------------------
    // Unfold: "][" swaps to "[ ]" and opens to its size while the label grows in.
    NumberAnimation {
      id: unfoldAnim
      target: win
      property: "unfold"
      to: 1
      duration: 340
      easing.type: Easing.OutBack
      easing.overshoot: 1.6
    }

    // Collapse: the reverse, then fade out and drop the ghost row.
    SequentialAnimation {
      id: collapseAnim
      NumberAnimation { target: win; property: "unfold"; to: 0; duration: 200; easing.type: Easing.InCubic }
      NumberAnimation { target: win; property: "opacity"; to: 0; duration: 110 }
      ScriptAction { script: root.removeGhost(win.address) }
    }

    // Float lift: hop up while the brackets cross-fade between [ ] and ( ).
    ParallelAnimation {
      id: floatLiftAnim
      SequentialAnimation {
        NumberAnimation { target: win; property: "lift"; to: -5; duration: 100; easing.type: Easing.OutQuad }
        NumberAnimation { target: win; property: "lift"; to: 0; duration: 320; easing.type: Easing.OutBounce }
      }
      SequentialAnimation {
        NumberAnimation { target: win; property: "floatFade"; to: 0.15; duration: 100 }
        NumberAnimation { target: win; property: "floatFade"; to: 1; duration: 220; easing.type: Easing.OutQuad }
      }
    }

    // ---- Focus animations -------------------------------------------------
    // Bracket snap: brackets fly in from wide and clamp onto the glyph.
    SequentialAnimation {
      id: snapAnim
      PropertyAction { target: win; property: "spread"; value: 3.5 }
      NumberAnimation { target: win; property: "spread"; to: -0.35; duration: 170; easing.type: Easing.OutCubic }
      NumberAnimation { target: win; property: "spread"; to: 0; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
    }

    // Breathe: a few calm outward pulses of the brackets.
    SequentialAnimation {
      id: breatheAnim
      SequentialAnimation {
        loops: 3
        NumberAnimation { target: win; property: "spread"; to: 1; duration: 220; easing.type: Easing.InOutSine }
        NumberAnimation { target: win; property: "spread"; to: 0; duration: 260; easing.type: Easing.InOutSine }
      }
    }

    // Pop: the label scales up briefly and springs back.
    SequentialAnimation {
      id: popAnim
      NumberAnimation { target: win; property: "labelScale"; to: 1.35; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: win; property: "labelScale"; to: 1.0; duration: 160; easing.type: Easing.OutBack }
    }

    // Hypr-pop: multi-stage scale wobble + rotation wiggle, paired with the
    // shockwave ring (ringAnim).
    ParallelAnimation {
      id: hyprPopAnim
      SequentialAnimation {
        NumberAnimation { target: win; property: "labelScale"; from: 0.25; to: 1.7; duration: 140; easing.type: Easing.OutBack; easing.overshoot: 4.0 }
        NumberAnimation { target: win; property: "labelScale"; to: 0.8; duration: 110; easing.type: Easing.InOutQuad }
        NumberAnimation { target: win; property: "labelScale"; to: 1.15; duration: 120; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
        NumberAnimation { target: win; property: "labelScale"; to: 1.0; duration: 220; easing.type: Easing.OutElastic; easing.amplitude: 1.0; easing.period: 0.3 }
      }
      SequentialAnimation {
        NumberAnimation { target: win; property: "labelRot"; from: 0; to: -18; duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: win; property: "labelRot"; to: 14; duration: 130; easing.type: Easing.InOutQuad }
        NumberAnimation { target: win; property: "labelRot"; to: -7; duration: 120; easing.type: Easing.InOutQuad }
        NumberAnimation { target: win; property: "labelRot"; to: 0; duration: 150; easing.type: Easing.OutBack }
      }
      SequentialAnimation {
        NumberAnimation { target: win; property: "spread"; to: 1.2; duration: 140; easing.type: Easing.OutQuad }
        NumberAnimation { target: win; property: "spread"; to: 0; duration: 380; easing.type: Easing.OutElastic; easing.amplitude: 1.0; easing.period: 0.35 }
      }
    }
    ParallelAnimation {
      id: ringAnim
      NumberAnimation { target: win; property: "ringScale"; from: 0.3; to: 2.4; duration: 420; easing.type: Easing.OutCubic }
      SequentialAnimation {
        NumberAnimation { target: win; property: "ringAlpha"; from: 0.0; to: 0.9; duration: 40 }
        NumberAnimation { target: win; property: "ringAlpha"; to: 0.0; duration: 380; easing.type: Easing.OutCubic }
      }
    }

    // Glitch: position jitter on the whole row, an accent flash and a
    // cyan/magenta chromatic fringe on the brackets.
    ParallelAnimation {
      id: glitchAnim
      SequentialAnimation {
        NumberAnimation { target: jitter; property: "x"; to: -4; duration: 30 }
        NumberAnimation { target: jitter; property: "x"; to: 3; duration: 30 }
        NumberAnimation { target: jitter; property: "x"; to: -3; duration: 30 }
        NumberAnimation { target: jitter; property: "x"; to: 2; duration: 30 }
        NumberAnimation { target: jitter; property: "x"; to: -1; duration: 30 }
        NumberAnimation { target: jitter; property: "x"; to: 0; duration: 40 }
      }
      SequentialAnimation {
        NumberAnimation { target: jitter; property: "y"; to: 2; duration: 25 }
        NumberAnimation { target: jitter; property: "y"; to: -2; duration: 40 }
        NumberAnimation { target: jitter; property: "y"; to: 1; duration: 40 }
        NumberAnimation { target: jitter; property: "y"; to: 0; duration: 60 }
      }
      SequentialAnimation {
        NumberAnimation { target: win; property: "tintAlpha"; to: 0.9; duration: 20 }
        NumberAnimation { target: win; property: "tintAlpha"; to: 0; duration: 35 }
        PauseAnimation { duration: 40 }
        NumberAnimation { target: win; property: "tintAlpha"; to: 0.7; duration: 20 }
        NumberAnimation { target: win; property: "tintAlpha"; to: 0; duration: 50 }
      }
      SequentialAnimation {
        NumberAnimation { target: win; property: "fringeC"; to: 0.75; duration: 25 }
        NumberAnimation { target: win; property: "fringeC"; to: 0.1; duration: 35 }
        NumberAnimation { target: win; property: "fringeC"; to: 0.6; duration: 30 }
        NumberAnimation { target: win; property: "fringeC"; to: 0; duration: 90 }
      }
      SequentialAnimation {
        PauseAnimation { duration: 15 }
        NumberAnimation { target: win; property: "fringeM"; to: 0.75; duration: 25 }
        NumberAnimation { target: win; property: "fringeM"; to: 0.1; duration: 35 }
        NumberAnimation { target: win; property: "fringeM"; to: 0.55; duration: 30 }
        NumberAnimation { target: win; property: "fringeM"; to: 0; duration: 100 }
      }
    }

    // Neon: brackets and glyph flicker through lighter/darker takes on the
    // theme accent, like a tube lighting up, then settle.
    SequentialAnimation {
      id: neonAnim
      PropertyAction { target: win; property: "neonColor"; value: root.accentColor }
      ParallelAnimation {
        NumberAnimation { target: win; property: "neonAlpha"; to: 1.0; duration: 50 }
        ColorAnimation { target: win; property: "neonColor"; to: Qt.lighter(root.accentColor, 1.5); duration: 50 }
        NumberAnimation { target: win; property: "neonScale"; to: 1.12; duration: 50; easing.type: Easing.OutQuad }
      }
      ParallelAnimation {
        NumberAnimation { target: win; property: "neonAlpha"; to: 0.3; duration: 60 }
        ColorAnimation { target: win; property: "neonColor"; to: Qt.darker(root.accentColor, 1.15); duration: 70 }
        NumberAnimation { target: win; property: "neonScale"; to: 0.95; duration: 70 }
      }
      ParallelAnimation {
        NumberAnimation { target: win; property: "neonAlpha"; to: 1.0; duration: 40 }
        ColorAnimation { target: win; property: "neonColor"; to: Qt.lighter(root.accentColor, 1.75); duration: 70 }
        NumberAnimation { target: win; property: "neonScale"; to: 1.15; duration: 70 }
      }
      ParallelAnimation {
        ColorAnimation { target: win; property: "neonColor"; to: Qt.darker(root.accentColor, 1.1); duration: 70 }
        NumberAnimation { target: win; property: "neonScale"; to: 0.97; duration: 70 }
      }
      ParallelAnimation {
        ColorAnimation { target: win; property: "neonColor"; to: Qt.lighter(root.accentColor, 1.4); duration: 70 }
        NumberAnimation { target: win; property: "neonScale"; to: 1.08; duration: 70 }
      }
      ParallelAnimation {
        NumberAnimation { target: win; property: "neonAlpha"; to: 0.0; duration: 160 }
        ColorAnimation { target: win; property: "neonColor"; to: root.accentColor; duration: 160 }
        NumberAnimation { target: win; property: "neonScale"; to: 1.0; duration: 160 }
      }
    }
  }

  // One bracket glyph, drawn at full bar height (rotated a quarter turn on a
  // vertical bar so it caps the window from above/below). Carries the glitch
  // and neon overlays so they track the bracket exactly.
  component Bracket: Item {
    id: br

    required property WindowItem owner
    property string glyph: "["
    // Offset along the bar's axis, in px (bracket snap / breathe).
    property real shift: 0

    implicitWidth: root.vertical ? root.barSize : main.implicitWidth
    implicitHeight: root.vertical ? main.implicitWidth : root.barSize
    width: implicitWidth
    height: implicitHeight

    transform: Translate {
      x: root.vertical ? 0 : br.shift
      y: root.vertical ? br.shift : 0
    }

    Item {
      anchors.centerIn: parent
      width: main.implicitWidth
      height: main.implicitHeight
      rotation: root.vertical ? 90 : 0

      Text { // glitch fringe: cyan
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: -2
        visible: br.owner.fringeC > 0
        text: br.glyph
        font: main.font
        color: "#33e0ff"
        opacity: br.owner.fringeC
      }
      Text { // glitch fringe: magenta
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: 2
        visible: br.owner.fringeM > 0
        text: br.glyph
        font: main.font
        color: "#ff3d81"
        opacity: br.owner.fringeM
      }
      Text {
        id: main
        anchors.centerIn: parent
        text: br.glyph
        color: br.owner.tone
        font.family: root.fontFamily
        font.pixelSize: root.glyphPx
        font.bold: br.owner.focused
      }
      Text { // glitch accent flash
        anchors.centerIn: parent
        visible: br.owner.tintAlpha > 0
        text: br.glyph
        font: main.font
        color: root.accentColor
        opacity: br.owner.tintAlpha
      }
      Text { // neon flicker
        anchors.centerIn: parent
        visible: br.owner.neonAlpha > 0
        text: br.glyph
        font: main.font
        color: br.owner.neonColor
        opacity: br.owner.neonAlpha
        scale: br.owner.neonScale
      }
    }
  }

  component EdgeFade: Rectangle {
    property bool leading: true
    property bool shown: false
    readonly property color base: root.bar ? root.bar.background : Color.background

    visible: shown
    width: root.vertical ? parent.width : 10
    height: root.vertical ? 10 : parent.height
    x: root.vertical || leading ? 0 : parent.width - width
    y: !root.vertical || leading ? 0 : parent.height - height
    gradient: Gradient {
      orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
      GradientStop { position: 0.0; color: leading ? base : "transparent" }
      GradientStop { position: 1.0; color: leading ? "transparent" : base }
    }
  }

  // ---- Settings popup -----------------------------------------------------------
  property string activeSection: "labels"

  readonly property var sectionTabs: [
    { value: "labels", label: "Labels" },
    { value: "animation", label: "Animation" },
    { value: "strip", label: "Strip" }
  ]

  function optionsOf(order, table) {
    return order.map(function (id) {
      return { value: id, label: table[id].label, description: table[id].description || "" }
    })
  }
  readonly property var labelOptions: optionsOf(Model.LABEL_MODE_ORDER, Model.LABEL_MODES)
  readonly property var animationOptions: optionsOf(Model.FOCUS_ANIMATION_ORDER, Model.FOCUS_ANIMATIONS)

  PopupCard {
    id: settingsPopup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.settingsOpen
    contentWidth: fittedContentWidth(Style.space(380))
    contentHeight: fittedContentHeight(settingsColumn.implicitHeight)

    Column {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(9)

      Text {
        text: "SCROLL MAP"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Row {
        spacing: Style.spacing.md

        Repeater {
          model: root.sectionTabs

          SectionTab {
            required property var modelData
            text: modelData.label
            selected: root.activeSection === modelData.value
            onClicked: root.activeSection = modelData.value
          }
        }
      }

      // Labels -------------------------------------------------------------
      Column {
        width: parent.width
        visible: root.activeSection === "labels"
        spacing: Style.space(2)

        Repeater {
          model: root.labelOptions

          RadioRow {
            required property var modelData
            value: modelData.value
            label: modelData.label
            description: modelData.description
            checked: root.iconMode === modelData.value
            onSelected: function (v) { root.saveSetting("iconMode", v) }
          }
        }

        SettingSlider {
          visible: root.iconMode === "shortname"
          label: "Name length"
          minimum: 1
          maximum: 4
          step: 1
          currentValue: root.cfg.nameLength
          onPreviewed: function (value) { root.previewSetting("nameLength", Math.round(value)) }
          onCommitted: function (value) { root.saveSetting("nameLength", Math.round(value)) }
        }
      }

      // Animation ------------------------------------------------------------
      Column {
        width: parent.width
        visible: root.activeSection === "animation"
        spacing: Style.space(2)

        SectionLabel { text: "On focus change" }

        Repeater {
          model: root.animationOptions

          RadioRow {
            required property var modelData
            value: modelData.value
            label: modelData.label
            description: modelData.description
            checked: root.focusAnimation === modelData.value
            onSelected: function (v) { root.saveSetting("focusAnimation", v) }
          }
        }

        Separator {}

        ScrollmapToggle {
          label: "Unfold / collapse"
          description: "Apps unfold out of ][ when they open and fold back when they close."
          checked: root.cfg.animUnfold
          onClicked: root.saveSetting("animUnfold", !root.cfg.animUnfold)
        }

        ScrollmapToggle {
          label: "Float lift"
          description: "Toggling floating hops the window while [ ] morphs into ( )."
          checked: root.cfg.animFloatLift
          onClicked: root.saveSetting("animFloatLift", !root.cfg.animFloatLift)
        }
      }

      // Strip ----------------------------------------------------------------
      Column {
        width: parent.width
        visible: root.activeSection === "strip"
        spacing: Style.space(9)

        SettingSlider {
          label: "Max strip width"
          suffix: "px"
          minimum: 120
          maximum: 1200
          step: 10
          currentValue: root.maxExtent
          onPreviewed: function (value) { root.previewSetting("maxWidth", Math.round(value / 10) * 10) }
          onCommitted: function (value) { root.saveSetting("maxWidth", Math.round(value / 10) * 10) }
        }

        SettingSlider {
          label: "Padding range"
          suffix: "px"
          minimum: 8
          maximum: 80
          step: 2
          currentValue: root.padRange
          onPreviewed: function (value) { root.previewSetting("padRange", Math.round(value)) }
          onCommitted: function (value) { root.saveSetting("padRange", Math.round(value)) }
        }

        SettingSlider {
          label: "Size curve"
          minimum: 10
          maximum: 40
          step: 1
          currentValue: root.cfg.padCurve
          formatValue: function (v) { return (Math.round(v) / 10).toFixed(1) + (Math.round(v) === 10 ? " (linear)" : "") }
          onPreviewed: function (value) { root.previewSetting("padCurve", Math.round(value)) }
          onCommitted: function (value) { root.saveSetting("padCurve", Math.round(value)) }
        }

        SettingSlider {
          label: "Gap between windows"
          suffix: "px"
          minimum: 0
          maximum: 16
          step: 1
          currentValue: root.gap
          onPreviewed: function (value) { root.previewSetting("gap", Math.round(value)) }
          onCommitted: function (value) { root.saveSetting("gap", Math.round(value)) }
        }

        ScrollmapToggle {
          label: "Include floating windows"
          description: "Slot floating windows in by position, drawn with ( ) instead of [ ]."
          checked: root.cfg.showFloating
          onClicked: root.saveSetting("showFloating", !root.cfg.showFloating)
        }
      }
    }
  }

  component Separator: PanelSeparator {
    foreground: root.fg
  }

  component SectionLabel: Text {
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component ScrollmapToggle: Toggle {
    width: parent ? parent.width : implicitWidth
    foreground: root.fg
    accent: Color.accent
    fontFamily: root.fontFamily
  }

  // Settings-popup tab chip. Same theme state tokens as the stock Button, but
  // the label colour is whichever of foreground/background actually reads on
  // the chip's fill (Model.readableOn) - some themes use a solid selected fill
  // in the same colour the stock Button would paint the label.
  component SectionTab: Rectangle {
    id: tab

    property string text: ""
    property bool selected: false
    signal clicked()

    readonly property color fill: tabMouse.pressed ? Style.pressedFillFor(root.fg, Color.accent)
      : tabMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent)
      : selected ? Style.selectedFillFor(root.fg, Color.accent)
      : "transparent"

    implicitWidth: tabLabel.implicitWidth + Style.space(8) * 2
    implicitHeight: tabLabel.implicitHeight + Style.space(4) * 2
    radius: Style.cornerRadius
    color: fill
    border.width: 1
    border.color: selected ? Style.selectedBorderFor(root.fg, Color.accent)
      : Style.normalBorderFor(root.fg, Color.accent)

    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      id: tabLabel
      anchors.centerIn: parent
      text: tab.text
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: tab.selected
      color: Model.readableOn(tab.fill, Color.background, root.fg, Color.background) === "primary"
        ? root.fg : Color.background
    }

    MouseArea {
      id: tabMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tab.clicked()
    }
  }

  component RadioRow: Item {
    id: radioRow

    required property string value
    required property string label
    property string description: ""
    property bool checked: false

    signal selected(string value)

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(radioOuter.height, textCol.implicitHeight) + Style.space(6)

    Rectangle {
      id: radioOuter
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: Style.space(3)
      width: Style.space(14)
      height: width
      radius: width / 2
      color: "transparent"
      border.width: 2
      border.color: radioRow.checked ? Color.accent : Qt.darker(root.fg, 1.3)
    }

    Rectangle {
      anchors.centerIn: radioOuter
      width: Style.space(6)
      height: width
      radius: width / 2
      color: Color.accent
      visible: radioRow.checked
    }

    Column {
      id: textCol
      anchors.left: radioOuter.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: radioRow.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: radioRow.checked
      }
      Text {
        width: parent.width
        visible: radioRow.description !== ""
        text: radioRow.description
        color: root.bar ? Qt.darker(root.bar.foreground, 1.35) : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: radioRow.selected(radioRow.value)
    }
  }

  component SettingSlider: Column {
    id: sliderSetting

    required property string label
    property string suffix: ""
    // Optional value -> label override for the readout.
    property var formatValue: null
    required property real minimum
    required property real maximum
    required property real step
    required property real currentValue

    signal previewed(real value)
    signal committed(real value)

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(5)

    Item {
      width: parent.width
      implicitHeight: Math.max(settingLabel.implicitHeight, settingValue.implicitHeight)

      Text {
        id: settingLabel
        anchors.left: parent.left
        text: sliderSetting.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: settingValue
        anchors.right: parent.right
        readonly property real shown: slider.dragging ? slider.liveValue : sliderSetting.currentValue
        text: sliderSetting.formatValue ? sliderSetting.formatValue(shown)
          : Math.round(shown) + sliderSetting.suffix
        color: root.bar ? Qt.darker(root.bar.foreground, 1.35) : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    PanelSlider {
      id: slider
      width: parent.width
      bar: root.bar
      minimum: sliderSetting.minimum
      maximum: sliderSetting.maximum
      step: sliderSetting.step
      integer: true
      value: sliderSetting.currentValue
      onMoved: function (value) { sliderSetting.previewed(value) }
      onReleased: function (value) { sliderSetting.committed(value) }
    }
  }

  Component.onCompleted: {
    probeLayout()
    sync()
    readyTimer.start()
  }
}
