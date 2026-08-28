#!/usr/bin/env python3
"""Render schematic SVG previews of the Scroll Map settings.

These are mock-ups, not screenshots: cell widths, gaps, the viewport
underline, focus treatment and the scrolled-off fade follow the same math as
`Model.computeStrip` and the `BarWidget.qml` delegate, so they read the way
the real widget does without needing a running shell. Re-run after changing
the delegate:

    python3 previews/generate_previews.py

Outputs:
  previews/cell-styles.svg   - the four `cellStyle` values
  previews/label-modes.svg   - the four `iconMode` values
"""

# Catppuccin Mocha - the common Omarchy default palette.
BG = "#1e1e2e"
FG = "#cdd6f4"
ACCENT = "#89b4fa"

# Sample layout: five windows of differing on-screen widths.
EXTENTS = [800, 1400, 500, 1100, 900]
SHORT = ["Fi", "Co", "Ke", "Di", "Sp"]
# Per-cell fraction of the window currently inside the monitor viewport.
VIS = [0.15, 1.0, 1.0, 1.0, 0.0]
FOCUS = 1

AVAIL = 360.0
GAP = 3.0
MIN_CELL = 6.0
CANVAS_W = 480
LANE_H = 20
STRIP_H = 54
PAD_TOP = 20


def strip_layout():
    n = len(EXTENTS)
    usable = AVAIL - GAP * (n - 1)
    total = float(sum(EXTENTS))
    free = usable - MIN_CELL * n
    sizes = [MIN_CELL + free * (e / total) for e in EXTENTS]
    offsets, acc = [], 0.0
    for s in sizes:
        offsets.append(acc)
        acc += s + GAP
    return sizes, offsets


def rgba(hex_color, alpha):
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"rgba({r},{g},{b},{alpha:.3f})"


def body(style, x, y0, w, focused, on_screen, opacity):
    fill, stroke, stroke_w = "none", "none", 0
    if style == "solid":
        fill = rgba(FG, 0.32 if focused else 0.11)
        if focused:
            stroke, stroke_w = ACCENT, 1
    elif style == "outline":
        stroke = ACCENT if focused else rgba(FG, 0.35)
        stroke_w = 1
    elif style == "filled":
        fill = rgba(FG, 0.92 if focused else 0.5)
        if focused:
            stroke, stroke_w = ACCENT, 1
    elif style == "underline" and focused:
        stroke, stroke_w = ACCENT, 1
    if fill == "none" and stroke == "none":
        return []
    return [
        f'<rect x="{x:.2f}" y="{y0:.2f}" width="{w:.2f}" height="{LANE_H}" rx="3" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{stroke_w}" '
        f'opacity="{opacity:.2f}"/>'
    ]


def nerd_glyph(i, cx, cy, color, op):
    """Five distinct primitives so the row reads as a different glyph per app."""
    g = f'<g fill="none" stroke="{color}" stroke-width="1.8" ' \
        f'stroke-linecap="round" stroke-linejoin="round" opacity="{op:.2f}">'
    if i == 0:      # ringed dot
        s = f'<circle cx="{cx}" cy="{cy}" r="6.5"/>' \
            f'<circle cx="{cx}" cy="{cy}" r="1.6" fill="{color}" stroke="none"/>'
    elif i == 1:    # terminal  >_
        s = f'<path d="M{cx-6} {cy-4} L{cx-1} {cy} L{cx-6} {cy+4}"/>' \
            f'<path d="M{cx+1} {cy+4.5} L{cx+6} {cy+4.5}"/>'
    elif i == 2:    # app square
        s = f'<rect x="{cx-6}" y="{cy-6}" width="12" height="12" rx="3"/>'
    elif i == 3:    # chat bubble
        s = f'<rect x="{cx-6.5}" y="{cy-6}" width="13" height="9" rx="2.5"/>' \
            f'<path d="M{cx-2} {cy+3} L{cx-4} {cy+6} L{cx+1} {cy+3}" ' \
            f'fill="{color}" stroke="none"/>'
    else:           # music note
        s = f'<circle cx="{cx-2.5}" cy="{cy+4}" r="2.6" fill="{color}" stroke="none"/>' \
            f'<path d="M{cx} {cy+4} L{cx} {cy-6} L{cx+5} {cy-4}"/>'
    return [g + s + "</g>"]


def label(mode, i, x, y0, w, focused, on_screen):
    if mode == "none" or w < 16:
        return []
    op = 1.0 if focused else (0.9 if on_screen else 0.4)
    cx, cy = x + w / 2, y0 + LANE_H / 2
    if mode == "icons":
        # Generic app-icon placeholder (real icons resolve from the theme).
        return [
            f'<g opacity="{op:.2f}">'
            f'<rect x="{cx-6.5:.2f}" y="{cy-6.5:.2f}" width="13" height="13" '
            f'rx="3.5" fill="{rgba(FG, 0.85)}"/>'
            f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.6" fill="{BG}"/></g>'
        ]
    if mode == "nerdfont":
        return nerd_glyph(i, cx, cy, FG, op)
    # shortname - bigger + bold, matching the delegate.
    return [
        f'<text x="{cx:.2f}" y="{cy + 4.5:.2f}" text-anchor="middle" '
        f'font-family="monospace" font-size="14" font-weight="700" '
        f'fill="{FG}" opacity="{op:.2f}">{SHORT[i]}</text>'
    ]


def strip(style, mode, x0, y0):
    sizes, offsets = strip_layout()
    out = []
    for i, (w, off) in enumerate(zip(sizes, offsets)):
        focused = i == FOCUS
        frac = VIS[i]
        on_screen = frac > 0.02
        x = x0 + off
        opacity = 1.0 if on_screen else 0.4

        out += body(style, x, y0, w, focused, on_screen, opacity)

        if focused or on_screen:
            thick = 2 if focused else 1.5
            u_op = 1.0 if focused else (0.2 + 0.5 * frac)
            out.append(
                f'<rect x="{x:.2f}" y="{y0 + LANE_H - thick:.2f}" width="{w:.2f}" '
                f'height="{thick}" rx="{thick / 2:.2f}" fill="{ACCENT}" '
                f'opacity="{u_op:.2f}"/>'
            )

        out += label(mode, i, x, y0, w, focused, on_screen)
    return out


def build(rows, vary):
    """rows: list of (heading, cellStyle, iconMode)."""
    h = PAD_TOP + STRIP_H * len(rows)
    x0 = (CANVAS_W - AVAIL) / 2
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS_W}" height="{h}" '
        f'viewBox="0 0 {CANVAS_W} {h}" font-family="monospace">',
        f'<rect width="{CANVAS_W}" height="{h}" fill="{BG}"/>',
    ]
    for r_i, (heading, style, mode) in enumerate(rows):
        top = PAD_TOP + STRIP_H * r_i
        parts.append(
            f'<text x="16" y="{top + 12}" font-size="11" fill="{rgba(FG, 0.75)}" '
            f'font-weight="700" letter-spacing="1">{heading}</text>'
        )
        parts += strip(style, mode, x0, top + 20)
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


if __name__ == "__main__":
    import os

    here = os.path.dirname(__file__)

    cell_styles = build([
        ("SOLID", "solid", "shortname"),
        ("OUTLINE", "outline", "shortname"),
        ("FILLED", "filled", "shortname"),
        ("UNDERLINE", "underline", "shortname"),
    ], vary="cellStyle")

    label_modes = build([
        ("NONE", "solid", "none"),
        ("ICONS", "solid", "icons"),
        ("NERD FONT", "solid", "nerdfont"),
        ("SHORT NAME", "solid", "shortname"),
    ], vary="iconMode")

    for name, svg in (("cell-styles.svg", cell_styles),
                      ("label-modes.svg", label_modes)):
        path = os.path.join(here, name)
        with open(path, "w") as fh:
            fh.write(svg)
        print("wrote", path)
