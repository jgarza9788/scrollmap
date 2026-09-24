// Pure helpers for the Scroll Map bar widget. Imported from BarWidget.qml as
// `import "Model.js" as Model`, and ES5-only so the same file runs under
// `node tests/model.test.js`.

// Hyprland/Quickshell report client addresses inconsistently: sometimes a bare
// hex string, sometimes already 0x-prefixed. Normalize to a lowercase 0x form,
// or "" when the value is not a hex address.
function normalizeAddress(value) {
  var raw = String(value || "").trim().toLowerCase()
  if (raw.indexOf("0x") === 0) raw = raw.slice(2)
  return /^[0-9a-f]+$/.test(raw) && raw.length > 0 ? "0x" + raw : ""
}

function ipcOf(toplevel) {
  var ipc = toplevel && toplevel.lastIpcObject
  return ipc && typeof ipc === "object" ? ipc : {}
}

function workspaceIdOf(ipc) {
  var ws = ipc && ipc.workspace
  if (!ws) return NaN
  var id = Number(ws.id)
  return isFinite(id) ? id : NaN
}

// Reduce the full toplevel list to the tiled, mapped windows that live on the
// given workspace, each described by the geometry the mini-map needs. Floating
// windows are excluded unless `includeFloating` is set: the scrolling layout
// only tiles, and a floating overlay can distort the proportional strip.
function eligibleClients(toplevels, workspaceId, includeFloating) {
  var list = toplevels || []
  var target = Number(workspaceId)
  var withFloating = includeFloating === true
  var out = []

  for (var i = 0; i < list.length; i++) {
    var top = list[i]
    if (!top) continue
    var ipc = ipcOf(top)

    if (ipc.mapped === false) continue
    if (ipc.floating === true && !withFloating) continue
    if (ipc.hidden === true) continue
    if (isFinite(target) && workspaceIdOf(ipc) !== target) continue

    var at = ipc.at || []
    var size = ipc.size || []
    var x = Number(at[0])
    var y = Number(at[1])
    var w = Number(size[0])
    var h = Number(size[1])
    if (!isFinite(x) || !isFinite(y) || !(w > 0) || !(h > 0)) continue

    out.push({
      address: normalizeAddress(top.address || ipc.address),
      appClass: String(ipc.class || ipc.initialClass || ""),
      title: String(top.title || ipc.title || ipc.class || ""),
      floating: ipc.floating === true,
      x: x,
      y: y,
      w: w,
      h: h
    })
  }

  return out
}

// Left-to-right for a horizontal bar, top-to-bottom for a vertical one. The
// off-axis coordinate is the tiebreaker so stacked splits keep a stable order.
function orderByPosition(clients, vertical) {
  var copy = (clients || []).slice()
  copy.sort(function (a, b) {
    var primary = vertical ? a.y - b.y : a.x - b.x
    if (primary !== 0) return primary
    var secondary = vertical ? a.x - b.x : a.y - b.y
    if (secondary !== 0) return secondary
    return String(a.address).localeCompare(String(b.address))
  })
  return copy
}

// How much of [start, end] falls inside [lo, hi], as a fraction of (end - start).
function overlapFraction(start, end, lo, hi) {
  var span = end - start
  if (!(span > 0)) return 0
  var a = Math.max(start, Math.min(lo, hi))
  var b = Math.min(end, Math.max(lo, hi))
  return b > a ? (b - a) / span : 0
}

// ---- Window size -----------------------------------------------------------
// Window size is shown as bracket padding, not pixel width, and it is
// continuous: every pixel of resize nudges the brackets. sizeFraction gives
// 0..1: a tiled window's extent along the bar's axis over the monitor's; a
// floating window's area over the monitor's, square-rooted so it grows at the
// same rate as a side length (a quarter-screen float reads as half size).
function sizeFraction(client, monitor, vertical) {
  if (!client || !monitor) return 0
  var mw = Number(monitor.width)
  var mh = Number(monitor.height)
  if (!(mw > 0) || !(mh > 0)) return 0
  var f = client.floating === true
    ? Math.sqrt(Math.max(0, (client.w * client.h) / (mw * mh)))
    : (vertical ? client.h / mh : client.w / mw)
  if (!isFinite(f)) return 0
  // Rounded so sub-pixel geometry jitter doesn't churn the row model.
  return Math.round(Math.max(0, Math.min(1, f)) * 1000) / 1000
}

// Shape the 0..1 size into padding: size^exponent. Above 1 the curve is
// convex, so big windows get disproportionately more room and are easy to
// tell apart from half-size ones, while small windows stay compact. 1 is
// linear.
function padCurve(size, exponent) {
  var f = Math.max(0, Math.min(1, Number(size) || 0))
  var e = Number(exponent)
  return Math.pow(f, e > 0 ? e : 1)
}

function bracketsFor(floating) {
  return floating === true ? ["(", ")"] : ["[", "]"]
}

// "focused" -> accent, "onscreen" -> foreground, "offscreen" -> muted.
function stateFor(focused, visibleFraction) {
  if (focused) return "focused"
  return visibleFraction > 0.02 ? "onscreen" : "offscreen"
}

// Ordered strip items, one per window. `viewport` (optional) is { start, end }
// along the bar's axis in compositor coordinates; `activeAddr` marks focus.
function buildStrip(clients, monitor, viewport, vertical, activeAddr) {
  var view = viewport && isFinite(viewport.start) && isFinite(viewport.end)
    && viewport.end > viewport.start ? viewport : null
  var active = normalizeAddress(activeAddr)
  return orderByPosition(clients, vertical).map(function (c) {
    var s = vertical ? c.y : c.x
    var e = s + (vertical ? c.h : c.w)
    var visible = view ? overlapFraction(s, e, view.start, view.end) : 1
    return {
      address: c.address,
      appClass: c.appClass,
      title: c.title,
      floating: c.floating === true,
      size: sizeFraction(c, monitor, vertical),
      visibleFraction: visible,
      state: stateFor(active !== "" && c.address === active, visible)
    }
  })
}

// Padding multiplier (0..1) that fits the strip under `maxPx`. Each item costs
// `itemPx` (two brackets + label) plus 2 * size * `padPx` of padding, and
// items are `gapPx` apart. Padding shrinks uniformly before anything clips; at
// 0 every window reads [x] and the caller clips whatever still overflows.
function fitPadding(sizes, padPx, itemPx, gapPx, maxPx) {
  var list = sizes || []
  var n = list.length
  if (n === 0) return 1
  var fixed = n * (Number(itemPx) || 0) + Math.max(0, n - 1) * (Number(gapPx) || 0)
  var units = 0
  for (var i = 0; i < n; i++) units += 2 * Math.max(0, Number(list[i]) || 0)
  var total = units * (Number(padPx) || 0)
  if (!(total > 0)) return 1
  var room = (Number(maxPx) || 0) - fixed
  return Math.max(0, Math.min(1, room / total))
}

// Reconcile the live delegate list with a new ordered set of addresses, so
// surviving windows keep their delegate (and its running animations) and
// closed ones linger as "closing" ghosts for the collapse animation. `current`
// is [{ address, closing }]; returns the ops to apply in order, simulated on a
// copy so every index is valid at the moment it is applied:
//   { op: "close", index }            mark a vanished row as closing
//   { op: "insert", index, item }     add a new row (item = next[i])
//   { op: "move", from, to }          reorder a surviving row
//   { op: "update", index, item }     refresh a surviving row's data
function syncOps(current, next) {
  var rows = (current || []).map(function (r) {
    return { address: r.address, closing: r.closing === true }
  })
  var want = {}
  var items = next || []
  for (var i = 0; i < items.length; i++) want[items[i].address] = true
  var ops = []

  for (var j = 0; j < rows.length; j++) {
    if (!rows[j].closing && !want[rows[j].address]) {
      rows[j].closing = true
      ops.push({ op: "close", index: j })
    }
  }

  function indexOf(addr) {
    for (var k = 0; k < rows.length; k++)
      if (rows[k].address === addr) return k
    return -1
  }

  var prev = -1
  for (var t = 0; t < items.length; t++) {
    var item = items[t]
    var at = indexOf(item.address)
    var target = prev + 1
    if (at === -1) {
      rows.splice(target, 0, { address: item.address, closing: false })
      ops.push({ op: "insert", index: target, item: item })
    } else {
      if (at !== target) {
        var row = rows.splice(at, 1)[0]
        // Removing an earlier row shifts the target left by one.
        if (at < target) target--
        rows.splice(target, 0, row)
        ops.push({ op: "move", from: at, to: target })
      }
      rows[target].closing = false
      ops.push({ op: "update", index: target, item: item })
    }
    prev = target
  }
  return ops
}

// ---- Settings registries -------------------------------------------------
// ORDER + { label, description } tables drive the settings popup's radio
// lists; resolve*() maps any unknown/legacy value back to the default.
var LABEL_MODE_ORDER = ["icons", "nerdfont", "shortname", "none"]
var LABEL_MODES = {
  icons:     { label: "App icons",        description: "The application icon at full bar height, first class letter when none resolves." },
  nerdfont:  { label: "Nerd Font glyphs", description: "A Nerd Font glyph matched from the window class, a generic window glyph when unmatched." },
  shortname: { label: "Short name",       description: "The window class cut to a few characters." },
  none:      { label: "Brackets only",    description: "Empty brackets - size and colour carry all the information." }
}
var DEFAULT_LABEL_MODE = "icons"

var FOCUS_ANIMATION_ORDER = [
  "none", "bracketSnap", "slideCursor", "breathe", "pop", "hyprPop", "glitch", "neon"
]
var FOCUS_ANIMATIONS = {
  none:        { label: "None",         description: "Focus just changes colour." },
  bracketSnap: { label: "Bracket snap", description: "The brackets fly in from wide and clamp onto the glyph with a little overshoot." },
  slideCursor: { label: "Slide cursor", description: "An accent underline glides from the old focused window to the new one." },
  breathe:     { label: "Breathe",      description: "The brackets pulse outward a few times, calm and heartbeat-like, then settle." },
  pop:         { label: "Pop",          description: "The glyph scales up briefly and springs back." },
  hyprPop:     { label: "Hypr-pop",     description: "A big multi-stage bounce with a rotation wobble and a shockwave ring - deliberately over the top." },
  glitch:      { label: "Glitch",       description: "Rapid position jitter, an accent flash and a cyan/magenta chromatic fringe on the brackets." },
  neon:        { label: "Neon",         description: "Brackets and glyph flicker through brightness variations of the theme accent, like a tube lighting up." }
}
var DEFAULT_FOCUS_ANIMATION = "bracketSnap"

function isLabelMode(id) { return Object.prototype.hasOwnProperty.call(LABEL_MODES, id) }
function isFocusAnimation(id) { return Object.prototype.hasOwnProperty.call(FOCUS_ANIMATIONS, id) }
function resolveLabelMode(id) { return isLabelMode(id) ? id : DEFAULT_LABEL_MODE }
function resolveFocusAnimation(id) { return isFocusAnimation(id) ? id : DEFAULT_FOCUS_ANIMATION }

function clampInt(value, lo, hi, fallback) {
  var n = Number(value)
  if (value === null || value === undefined || value === "" || !isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, Math.round(n)))
}

function boolOr(value, fallback) {
  return value === true || value === false ? value : fallback
}

// Normalize a raw settings object into the 2.0 keys. Legacy 1.x keys are only
// consulted when the new key is absent: `animate: false` turns every
// animation off, `showIcons: false` means no label. `cellStyle`, `minCell`,
// `dimInactive` and `showViewport` no longer mean anything and are ignored.
function resolveSettings(raw) {
  var s = raw || {}
  var legacyStill = s.animate === false
  var mode = s.iconMode
  if (mode === undefined || mode === null || mode === "")
    mode = s.showIcons === false ? "none" : DEFAULT_LABEL_MODE
  var anim = s.focusAnimation
  if (anim === undefined || anim === null || anim === "")
    anim = legacyStill ? "none" : DEFAULT_FOCUS_ANIMATION
  return {
    maxWidth: clampInt(s.maxWidth, 120, 1200, 360),
    gap: clampInt(s.gap, 0, 16, 4),
    padRange: clampInt(s.padRange, 8, 80, 36),
    // Stored in tenths (20 = exponent 2.0): the settings schema is integer-only.
    padCurve: clampInt(s.padCurve, 10, 40, 20),
    iconMode: resolveLabelMode(String(mode)),
    nameLength: clampInt(s.nameLength, 1, 4, 3),
    focusAnimation: resolveFocusAnimation(String(anim)),
    animUnfold: boolOr(s.animUnfold, !legacyStill),
    animFloatLift: boolOr(s.animFloatLift, !legacyStill),
    showFloating: s.showFloating === true
  }
}

// ---- Theme colours -------------------------------------------------------
// The state colours come straight from the active theme's colors.toml, so a
// theme switch recolours the strip live. Same tolerant line regex as
// Color.qml's own loader; returns only the keys found.
// `background`/`foreground` feed ensureContrast below.
var THEME_COLOR_KEYS = ["accent", "muted", "background", "foreground"]

function parseThemeColors(raw, keys) {
  var wanted = {}
  var list = keys || THEME_COLOR_KEYS
  for (var i = 0; i < list.length; i++) wanted[list[i]] = true
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var j = 0; j < lines.length; j++) {
    var m = lines[j].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (!m) continue
    if (wanted[m[1]] && out[m[1]] === undefined) out[m[1]] = m[2]
  }
  return out
}

// Picks the more readable of two text colours on a (possibly translucent)
// fill composited over `under`. Colours are { r, g, b, a } in 0..1 - a QML
// color already has these. Returns "primary" or "alt".
function relativeLuminance(c) {
  function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}
function contrastRatio(a, b) {
  var la = relativeLuminance(a), lb = relativeLuminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}
function readableOn(fill, under, primary, alt) {
  var a = fill.a === undefined ? 1 : fill.a
  var composite = {
    r: fill.r * a + under.r * (1 - a),
    g: fill.g * a + under.g * (1 - a),
    b: fill.b * a + under.b * (1 - a)
  }
  return contrastRatio(primary, composite) >= contrastRatio(alt, composite) ? "primary" : "alt"
}

// ---- Labels --------------------------------------------------------------
// `iconMode === "nerdfont"` draws one glyph per window, looked up from the
// window class. The bar font already resolves to a Nerd Font, so these are
// just the private-use codepoints. Anything not in the table gets a plain
// window glyph — a starter set, easy to extend.
var NERD_FALLBACK = "" // window-maximize

var NERD_GLYPHS = {
  "firefox": "",
  "firefox-developer-edition": "",
  "chromium": "",
  "chrome": "",
  "google-chrome": "",
  "brave-browser": "",
  "brave": "",
  "code": "",
  "codium": "",
  "vscodium": "",
  "kitty": "",
  "alacritty": "",
  "foot": "",
  "ghostty": "",
  "wezterm": "",
  "discord": "",
  "slack": "",
  "spotify": "",
  "telegram": "",
  "thunderbird": "",
  "nautilus": "",
  "thunar": "",
  "pcmanfm": "",
  "nemo": "",
  "dolphin": "",
  "gimp": "",
  "blender": "",
  "steam": "",
  "mpv": "",
  "vlc": "",
  "obsidian": "",
  "zoom": ""
}

// Resolve a window class to a Nerd Font glyph. Tries the class as given,
// then its last dotted segment (org.gnome.Nautilus -> nautilus), then the
// class with trailing "-suffix" parts peeled off one at a time
// (google-chrome-stable -> google-chrome -> google).
function nerdGlyph(cls) {
  var key = String(cls || "").trim().toLowerCase().replace(/\.desktop$/, "")
  if (!key) return NERD_FALLBACK
  if (NERD_GLYPHS[key]) return NERD_GLYPHS[key]
  var dot = key.lastIndexOf(".")
  if (dot !== -1 && NERD_GLYPHS[key.slice(dot + 1)]) return NERD_GLYPHS[key.slice(dot + 1)]
  var stem = key
  var dash = stem.lastIndexOf("-")
  while (dash > 0) {
    stem = stem.slice(0, dash)
    if (NERD_GLYPHS[stem]) return NERD_GLYPHS[stem]
    dash = stem.lastIndexOf("-")
  }
  return NERD_FALLBACK
}

// `iconMode === "shortname"`: the class stripped to letters/digits and cut
// to `n` (1-4) characters, first upper-cased. "•" when there's no class.
function shortName(cls, n) {
  var s = String(cls || "").replace(/[^a-z0-9]/gi, "")
  var len = Math.max(1, Math.min(4, Math.round(Number(n) || 3)))
  if (!s) return "•"
  return s.charAt(0).toUpperCase() + s.slice(1, len).toLowerCase()
}

function hexToRgb(hex) {
  var m = /^#?([0-9a-f]{6})$/i.exec(String(hex || "").trim())
  if (!m) return null
  var n = parseInt(m[1], 16)
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 }
}

function rgbToHex(c) {
  function h(v) {
    var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
    return s.length === 1 ? "0" + s : s
  }
  return "#" + h(c.r) + h(c.g) + h(c.b)
}

// Some themes' `muted` is nearly invisible as a text colour on the bar. Mix
// `hex` toward `towardHex`
// (the foreground) in 5% steps until it reaches `minRatio` contrast against
// `bgHex`. Returns `hex` unchanged when it already reads, or when any input
// fails to parse.
function ensureContrast(hex, bgHex, towardHex, minRatio) {
  var c = hexToRgb(hex), bg = hexToRgb(bgHex), to = hexToRgb(towardHex)
  if (!c || !bg || !to) return hex
  var want = Number(minRatio) || 3
  for (var t = 0; t <= 1.0001; t += 0.05) {
    var mixed = {
      r: c.r + (to.r - c.r) * t,
      g: c.g + (to.g - c.g) * t,
      b: c.b + (to.b - c.b) * t
    }
    if (contrastRatio(mixed, bg) >= want) return t === 0 ? hex : rgbToHex(mixed)
  }
  return towardHex
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeAddress: normalizeAddress,
    overlapFraction: overlapFraction,
    eligibleClients: eligibleClients,
    orderByPosition: orderByPosition,
    sizeFraction: sizeFraction,
    padCurve: padCurve,
    bracketsFor: bracketsFor,
    stateFor: stateFor,
    buildStrip: buildStrip,
    fitPadding: fitPadding,
    syncOps: syncOps,
    LABEL_MODE_ORDER: LABEL_MODE_ORDER,
    LABEL_MODES: LABEL_MODES,
    DEFAULT_LABEL_MODE: DEFAULT_LABEL_MODE,
    FOCUS_ANIMATION_ORDER: FOCUS_ANIMATION_ORDER,
    FOCUS_ANIMATIONS: FOCUS_ANIMATIONS,
    DEFAULT_FOCUS_ANIMATION: DEFAULT_FOCUS_ANIMATION,
    isLabelMode: isLabelMode,
    isFocusAnimation: isFocusAnimation,
    resolveLabelMode: resolveLabelMode,
    resolveFocusAnimation: resolveFocusAnimation,
    resolveSettings: resolveSettings,
    THEME_COLOR_KEYS: THEME_COLOR_KEYS,
    parseThemeColors: parseThemeColors,
    relativeLuminance: relativeLuminance,
    contrastRatio: contrastRatio,
    readableOn: readableOn,
    hexToRgb: hexToRgb,
    rgbToHex: rgbToHex,
    ensureContrast: ensureContrast,
    nerdGlyph: nerdGlyph,
    shortName: shortName,
    NERD_FALLBACK: NERD_FALLBACK
  }
}
