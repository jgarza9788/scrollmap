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

// Browsers launched with --app=<url> encode the URL host in the window class.
// Omarchy's desktop entries keep that same URL in Exec=, so the widget can
// join a web-app window back to its configured desktop icon without fetching
// or guessing an icon itself.
var WEBAPP_CLASS_PREFIXES = [
  "brave-",
  "chromium-",
  "google-chrome-",
  "microsoft-edge-",
  "vivaldi-",
  "opera-",
  "helium-"
]

function webAppDomain(cls) {
  var key = String(cls || "").trim().toLowerCase()
  for (var i = 0; i < WEBAPP_CLASS_PREFIXES.length; i++) {
    var prefix = WEBAPP_CLASS_PREFIXES[i]
    if (key.indexOf(prefix) !== 0) continue
    var encoded = key.slice(prefix.length)
    var marker = encoded.indexOf("__")
    if (marker <= 0) return ""
    var host = encoded.slice(0, marker).replace(/\.$/, "")
    return host.indexOf(".") > 0 && /^[a-z0-9.-]+$/.test(host) ? host : ""
  }
  return ""
}

function webAppExecDomain(execString) {
  var match = String(execString || "").match(/https?:\/\/([^\/\s"']+)/i)
  if (!match) return ""
  return String(match[1] || "").toLowerCase().replace(/:\d+$/, "").replace(/\.$/, "")
}

function normalizedDomain(value) {
  var host = String(value || "").trim().toLowerCase().replace(/\.$/, "")
  return host.indexOf("www.") === 0 ? host.slice(4) : host
}

function sameWebAppDomain(left, right) {
  var a = normalizedDomain(left)
  var b = normalizedDomain(right)
  return a.length > 0 && a === b
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

// Turn ordered clients into positioned cells that exactly fill `available`
// (minus the gaps). Cell extent is proportional to the window's on-screen
// extent, but never below `minCell`; the proportional share is applied to the
// space left after every cell is granted its minimum, which guarantees the
// strip fits no matter how lopsided the real window sizes are.
//
// `viewport` (optional) is { start, end } in the same compositor coordinates as
// the clients' positions, along the active axis. Each cell then reports how much
// of its window is currently inside the monitor's visible region.
function computeStrip(clients, available, gap, minCell, vertical, viewport) {
  var ordered = orderByPosition(clients, vertical)
  var n = ordered.length
  if (n === 0) return []

  var view = viewport && isFinite(viewport.start) && isFinite(viewport.end)
    && viewport.end > viewport.start ? viewport : null

  var space = Math.max(0, Number(available) || 0)
  var g = Math.max(0, Number(gap) || 0)
  var floor = Math.max(1, Number(minCell) || 1)
  var usable = Math.max(1, space - g * (n - 1))

  var extents = ordered.map(function (c) {
    var e = vertical ? c.h : c.w
    return e > 0 ? e : 1
  })
  var totalExtent = extents.reduce(function (sum, e) { return sum + e }, 0)

  var sizes
  if (floor * n >= usable) {
    var equal = usable / n
    sizes = ordered.map(function () { return equal })
  } else {
    var free = usable - floor * n
    sizes = extents.map(function (e) {
      return floor + free * (e / totalExtent)
    })
  }

  var offset = 0
  return ordered.map(function (client, i) {
    var winStart = vertical ? client.y : client.x
    var winEnd = winStart + (vertical ? client.h : client.w)
    var visibleFraction = view
      ? overlapFraction(winStart, winEnd, view.start, view.end)
      : 1

    var cell = {
      address: client.address,
      appClass: client.appClass,
      title: client.title,
      floating: client.floating === true,
      size: sizes[i],
      offset: offset,
      visibleFraction: visibleFraction,
      onScreen: visibleFraction > 0.02
    }
    offset += sizes[i] + g
    return cell
  })
}

// Preferred strip extent before the maxWidth cap: compact for a couple of
// windows, growing toward the cap as more open.
function preferredExtent(count, perWindow, minimum, maximum) {
  var wanted = Math.max(0, Number(count) || 0) * (Number(perWindow) || 0)
  return Math.max(Number(minimum) || 0, Math.min(Number(maximum) || wanted, wanted))
}

// ---- Cell labels ---------------------------------------------------------
// `iconMode === "nerdfont"` draws one glyph per cell, looked up from the
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

if (typeof module !== "undefined") {
  module.exports = {
    normalizeAddress: normalizeAddress,
    overlapFraction: overlapFraction,
    eligibleClients: eligibleClients,
    orderByPosition: orderByPosition,
    computeStrip: computeStrip,
    preferredExtent: preferredExtent,
    webAppDomain: webAppDomain,
    webAppExecDomain: webAppExecDomain,
    sameWebAppDomain: sameWebAppDomain,
    nerdGlyph: nerdGlyph,
    shortName: shortName,
    NERD_FALLBACK: NERD_FALLBACK
  }
}
