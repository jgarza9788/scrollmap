import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A mini-map of the windows on this monitor's active workspace, for the
// Hyprland scrolling layout only. Each window is a cell whose width tracks the
// window's real on-screen width, laid out in the same order the layout shows
// them. The stretch of cells currently inside the monitor's viewport is
// underlined; windows scrolled off the edge fade. Left-click a cell to focus
// that window, right-click anywhere on the widget for settings.
//
// Outside the scrolling layout the widget just says so and does nothing.
BarWidget {
  id: root
  moduleName: "jgarza.scrollmap"

  readonly property int maxExtent: Math.max(120, Number(setting("maxWidth", 480)))
  readonly property int minCell: Math.max(4, Number(setting("minCell", 6)))
  readonly property int cellGap: Math.max(0, Number(setting("gap", 3)))
  // What each cell draws: "none" | "icons" | "nerdfont" | "shortname".
  // Falls back to the old boolean `showIcons` key when unset.
  readonly property string iconMode: {
    var m = setting("iconMode", null)
    if (m !== null && m !== undefined && String(m) !== "")
      return String(m)
    return setting("showIcons", true) === false ? "none" : "icons"
  }
  readonly property int nameLength: Math.max(1, Math.min(4, Number(setting("nameLength", 3))))
  // How the cell body is drawn: "solid" | "outline" | "filled" | "underline".
  readonly property string cellStyle: {
    var s = setting("cellStyle", "solid")
    return (s === "outline" || s === "filled" || s === "underline")
      ? String(s) : "solid"
  }
  readonly property bool dimInactive: setting("dimInactive", true) === true
  readonly property bool showViewport: setting("showViewport", true) === true
  readonly property bool animate: setting("animate", true) === true
  readonly property bool showFloating: setting("showFloating", false) === true

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent

  // Bumped whenever live client/monitor geometry should be re-read.
  property int tick: 0
  property string layoutName: ""
  readonly property bool scrolling: layoutName === "scrolling"

  // ---- Settings popup ----------------------------------------------------
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
    return Model.eligibleClients(tops, barWorkspaceId, showFloating)
  }

  // address -> live client, so delegates can track viewport visibility every
  // tick without the cell model (and its delegates) being rebuilt.
  readonly property var clientMap: {
    var map = ({})
    for (var i = 0; i < clients.length; i++)
      map[clients[i].address] = clients[i]
    return map
  }

  readonly property string activeAddr: Model.normalizeAddress(
    Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "")

  readonly property real stripExtent: Model.preferredExtent(
    clients.length, 44, Math.min(96, maxExtent), maxExtent)

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

  // Stable delegate model: replaced only when order, size, focus or floating
  // state change. Viewport visibility is handled live in the delegates, so a
  // scroll doesn't churn the Repeater.
  property string sig: ""
  property var cells: []

  function rebuild() {
    var next = Model.computeStrip(clients, stripExtent, cellGap, minCell, vertical)
    var s = activeAddr + "|" + Math.round(stripExtent) + "|" + next.map(function (c) {
      return c.address + ":" + Math.round(c.offset) + ":" + Math.round(c.size)
        + (c.floating ? "f" : "")
    }).join(",")
    if (s !== sig) {
      sig = s
      cells = next
    }
  }

  onClientsChanged: rebuild()
  onStripExtentChanged: rebuild()
  onActiveAddrChanged: rebuild()
  onVerticalChanged: rebuild()

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

  readonly property real lane: Math.max(6, barSize - Style.space(8))

  visible: true
  implicitWidth: vertical
    ? barSize
    : (scrolling
      ? (clients.length > 0 ? Math.ceil(stripExtent) : 0)
      : Math.ceil(placeholder.implicitWidth + Style.space(8)))
  implicitHeight: vertical
    ? (scrolling
      ? (clients.length > 0 ? Math.ceil(stripExtent) : 0)
      : Math.ceil(placeholder.implicitHeight + Style.space(8)))
    : barSize

  Behavior on implicitWidth {
    enabled: root.animate && !root.vertical
    NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
  }
  Behavior on implicitHeight {
    enabled: root.animate && root.vertical
    NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
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
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Item {
    id: strip
    anchors.centerIn: parent
    visible: root.scrolling && root.cells.length > 0
    width: root.vertical ? root.lane : root.stripExtent
    height: root.vertical ? root.stripExtent : root.lane

    Repeater {
      model: root.cells

      delegate: Rectangle {
        id: cell
        required property var modelData

        readonly property bool focused: root.activeAddr !== ""
          && modelData.address === root.activeAddr
        readonly property bool floating: modelData.floating === true
        readonly property bool hovered: hoverArea.containsMouse

        // Live viewport visibility, tracked without rebuilding the model.
        readonly property var liveClient: root.clientMap[modelData.address] || null
        readonly property real visibleFraction: {
          var v = root.viewportRange
          if (!v || !liveClient || !root.showViewport)
            return 1
          var s = root.vertical ? liveClient.y : liveClient.x
          var e = s + (root.vertical ? liveClient.h : liveClient.w)
          return Model.overlapFraction(s, e, v.start, v.end)
        }
        readonly property bool onScreen: !root.showViewport || visibleFraction > 0.02

        // Fade + scale in on appearance (only when animation is enabled).
        property real introFrac: 1
        NumberAnimation {
          id: introAnim
          target: cell
          property: "introFrac"
          from: 0
          to: 1
          duration: 220
          easing.type: Easing.OutCubic
        }
        Component.onCompleted: if (root.animate) {
          introFrac = 0
          introAnim.start()
        }

        x: root.vertical ? 0 : modelData.offset
        y: root.vertical ? modelData.offset : 0
        width: root.vertical ? parent.width : modelData.size
        height: root.vertical ? modelData.size : parent.height
        radius: Math.min(4, Math.min(width, height) / 3)
        antialiasing: true
        transformOrigin: Item.Center
        scale: (hovered ? 1.05 : 1.0) * (0.85 + 0.15 * introFrac)
        opacity: introFrac * (onScreen ? 1.0 : 0.4)

        // Cell-body fill, keyed off `root.cellStyle`. "underline" draws no
        // body at all; "outline" is see-through with a border; "solid" is the
        // original translucent tint; "filled" is a near-opaque block.
        readonly property real fillAlpha: {
          if (root.cellStyle === "underline")
            return 0
          if (root.cellStyle === "outline")
            return hovered ? 0.06 : 0.0
          if (root.cellStyle === "filled")
            return (focused ? 0.92
              : (floating ? 0.10 : (root.dimInactive ? 0.5 : 0.7)))
              + (hovered ? 0.06 : 0.0)
          return (focused ? 0.32
            : (floating ? 0.06 : (root.dimInactive ? 0.11 : 0.17)))
            + (hovered ? 0.10 : 0.0)
        }
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, fillAlpha)
        border.color: {
          if (floating)
            return "transparent"
          if (focused)
            return root.accent
          if (root.cellStyle === "outline")
            return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, hovered ? 0.55 : 0.35)
          return "transparent"
        }
        border.width: {
          if (floating)
            return 0
          if (focused)
            return Math.max(1, Style.space(1))
          return root.cellStyle === "outline" ? 1 : 0
        }

        Behavior on scale { enabled: root.animate; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on color { enabled: root.animate; ColorAnimation { duration: 120 } }
        Behavior on width { enabled: root.animate; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: root.animate; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on x { enabled: root.animate; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: root.animate; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        // Floating windows read as a dashed outline so they're distinct from
        // the tiled columns they overlap.
        Shape {
          anchors.fill: parent
          visible: cell.floating
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            strokeColor: cell.focused
              ? root.accent
              : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)
            strokeWidth: 1
            fillColor: "transparent"
            strokeStyle: ShapePath.DashLine
            dashPattern: [2, 2]
            startX: 0.5
            startY: 0.5
            PathLine { x: cell.width - 0.5; y: 0.5 }
            PathLine { x: cell.width - 0.5; y: cell.height - 0.5 }
            PathLine { x: 0.5; y: cell.height - 0.5 }
            PathLine { x: 0.5; y: 0.5 }
          }
        }

        readonly property real iconPx: Math.max(9,
          Math.min(15, cell.width - 5, cell.height - 5))
        readonly property bool labelIsText: root.iconMode === "nerdfont"
          || root.iconMode === "shortname"

        Item {
          anchors.centerIn: parent
          width: cell.labelIsText ? Math.max(6, cell.width - 4) : cell.iconPx
          // Text labels get extra vertical room so the bigger, bold glyph /
          // name can grow.
          height: cell.labelIsText
            ? Math.max(cell.iconPx, Math.min(cell.height - 2, 22))
            : cell.iconPx
          // Text labels fit in cells too narrow for the icon image; "none"
          // draws nothing.
          visible: root.iconMode !== "none"
            && (cell.labelIsText
              ? (cell.width >= 10 && cell.height >= 11)
              : (cell.width >= 15 && cell.height >= 14))

          Image {
            id: iconImg
            anchors.centerIn: parent
            width: cell.iconPx
            height: cell.iconPx
            source: root.iconMode === "icons"
              ? root.resolveIcon(cell.modelData.appClass) : ""
            sourceSize.width: Math.round(15 * Screen.devicePixelRatio)
            sourceSize.height: Math.round(15 * Screen.devicePixelRatio)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            mipmap: true
            visible: root.iconMode === "icons" && status === Image.Ready
            opacity: cell.focused ? 1 : 0.82
          }

          // Nerd Font glyph, short class name, or — in icon mode — the first
          // class letter when no icon image resolves, so a wide cell is never
          // blank.
          Text {
            anchors.fill: parent
            visible: root.iconMode === "nerdfont" || root.iconMode === "shortname"
              || (root.iconMode === "icons" && iconImg.status !== Image.Ready)
            text: {
              if (root.iconMode === "nerdfont")
                return Model.nerdGlyph(cell.modelData.appClass)
              if (root.iconMode === "shortname")
                return Model.shortName(cell.modelData.appClass, root.nameLength)
              var c = String(cell.modelData.appClass || "")
              return c ? c.charAt(0).toUpperCase() : "•"
            }
            // On a near-opaque "filled" block the foreground colour has no
            // contrast — flip to the bar background instead.
            color: root.cellStyle === "filled"
              ? (root.bar ? root.bar.background : Color.background)
              : root.fg
            opacity: cell.focused ? 1.0 : (cell.labelIsText ? 0.88 : 0.7)
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            // Fit within the box in both directions so the larger ceiling
            // grows the glyph / name to fill it without overflowing.
            fontSizeMode: Text.Fit
            minimumPixelSize: 6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            // Nerd Font glyph and short name: bigger and bold. Icon-mode
            // letter fallback keeps its smaller size.
            font.pixelSize: cell.labelIsText
              ? Math.max(10, Math.min(22, cell.height - 2))
              : Math.max(8, cell.iconPx)
            font.bold: true
          }
        }

        // Accent underline (leading edge on a vertical bar): solid for the
        // focused window, faint under the cells inside the monitor viewport.
        Rectangle {
          readonly property real thick: cell.focused ? 2 : 1.5
          x: 0
          y: root.vertical ? 0 : cell.height - thick
          width: root.vertical ? thick : cell.width
          height: root.vertical ? cell.height : thick
          radius: thick / 2
          color: root.accent
          visible: cell.focused || (cell.onScreen && root.showViewport)
          opacity: cell.focused ? 1.0 : (0.2 + 0.5 * cell.visibleFraction)
          Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 140 } }
        }

        MouseArea {
          id: hoverArea
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.PointingHandCursor
          onClicked: root.focusClient(cell.modelData.address)
          onEntered: if (root.bar)
            root.bar.showTooltip(cell, String(cell.modelData.title
              || cell.modelData.appClass))
          onExited: if (root.bar) root.bar.hideTooltip(cell)
        }
      }
    }
  }

  // Right-click anywhere on the widget opens the settings popup. Left presses
  // are not accepted here, so they fall through to the per-cell handlers.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    onClicked: root.toggle()
  }

  PopupCard {
    id: settingsPopup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.settingsOpen
    contentWidth: fittedContentWidth(Style.space(340))
    contentHeight: fittedContentHeight(settingsColumn.implicitHeight)

    Column {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(9)

      Text {
        text: "SCROLL MAP"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      SettingSlider {
        label: "Max strip width"
        suffix: "px"
        minimum: 120
        maximum: 600
        step: 10
        currentValue: Number(root.setting("maxWidth", 280))
        onPreviewed: function (value) { root.previewSetting("maxWidth", Math.round(value / 10) * 10) }
        onCommitted: function (value) { root.saveSetting("maxWidth", Math.round(value / 10) * 10) }
      }

      SettingSlider {
        label: "Min window cell"
        suffix: "px"
        minimum: 4
        maximum: 40
        step: 2
        currentValue: Number(root.setting("minCell", 6))
        onPreviewed: function (value) { root.previewSetting("minCell", Math.round(value)) }
        onCommitted: function (value) { root.saveSetting("minCell", Math.round(value)) }
      }

      SettingSlider {
        label: "Cell gap"
        suffix: "px"
        minimum: 0
        maximum: 12
        step: 1
        currentValue: Number(root.setting("gap", 3))
        onPreviewed: function (value) { root.previewSetting("gap", Math.round(value)) }
        onCommitted: function (value) { root.saveSetting("gap", Math.round(value)) }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(5)

        Text {
          text: "Cell label"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        ButtonGroup {
          width: parent.width
          options: [
            { value: "none", label: "None", icon: "", tooltip: "Bare cells, no glyph" },
            { value: "icons", label: "Icon", icon: "", tooltip: "App icon, first class letter as fallback" },
            { value: "nerdfont", label: "Nerd", icon: "", tooltip: "Nerd Font glyph matched from the window class" },
            { value: "shortname", label: "Text", icon: "", tooltip: "Window class truncated to a few characters" }
          ]
          value: root.iconMode
          foreground: root.bar ? root.bar.foreground : Color.foreground
          accent: Color.accent
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onChanged: function (value) { root.saveSetting("iconMode", value) }
        }
      }

      SettingSlider {
        visible: root.iconMode === "shortname"
        label: "Name length"
        minimum: 1
        maximum: 4
        step: 1
        currentValue: root.nameLength
        onPreviewed: function (value) { root.previewSetting("nameLength", Math.round(value)) }
        onCommitted: function (value) { root.saveSetting("nameLength", Math.round(value)) }
      }

      Column {
        width: parent.width
        spacing: Style.space(5)

        Text {
          text: "Cell style"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        ButtonGroup {
          width: parent.width
          options: [
            { value: "solid", label: "Solid", tooltip: "Translucent filled cells (default)" },
            { value: "outline", label: "Outline", tooltip: "Transparent cells with a thin border" },
            { value: "filled", label: "Filled", tooltip: "Opaque high-contrast blocks" },
            { value: "underline", label: "Bars", tooltip: "No cell body — just the viewport / focus tick" }
          ]
          value: root.cellStyle
          foreground: root.bar ? root.bar.foreground : Color.foreground
          accent: Color.accent
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onChanged: function (value) { root.saveSetting("cellStyle", value) }
        }
      }

      ScrollmapToggle {
        label: "Dim unfocused windows"
        description: "Fade every cell except the focused window."
        checked: root.dimInactive
        onClicked: root.saveSetting("dimInactive", !root.dimInactive)
      }

      ScrollmapToggle {
        label: "Mark on-screen windows"
        description: "Underline windows in the viewport, fade the ones scrolled off."
        checked: root.showViewport
        onClicked: root.saveSetting("showViewport", !root.showViewport)
      }

      ScrollmapToggle {
        label: "Animate changes"
        description: "Fade and slide cells as windows open, close, and move."
        checked: root.animate
        onClicked: root.saveSetting("animate", !root.animate)
      }

      ScrollmapToggle {
        label: "Include floating windows"
        description: "Slot floating windows in by position, drawn dashed."
        checked: root.showFloating
        onClicked: root.saveSetting("showFloating", !root.showFloating)
      }
    }
  }

  component ScrollmapToggle: Toggle {
    width: parent ? parent.width : implicitWidth
    foreground: root.bar ? root.bar.foreground : Color.foreground
    accent: Color.accent
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  }

  component SettingSlider: Column {
    id: sliderSetting

    required property string label
    property string suffix: ""
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
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        id: settingValue
        anchors.right: parent.right
        text: Math.round(slider.dragging ? slider.liveValue : sliderSetting.currentValue)
          + sliderSetting.suffix
        color: root.bar ? Qt.darker(root.bar.foreground, 1.35) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
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
    rebuild()
  }
}
