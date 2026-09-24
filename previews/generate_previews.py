#!/usr/bin/env python3
"""Render schematic SVG previews of the Scroll Map bracket strip.

These are mock-ups, not screenshots: bracket padding follows
`Model.sizeFraction` + `Model.padCurve` (size^curve x padRange per side),
colours follow
`Model.stateFor` (accent when focused, foreground on screen, muted when
scrolled off) and floating windows use ( ) - the same rules the
`BarWidget.qml` delegate draws with. Re-run after changing the delegate:

    python3 previews/generate_previews.py

Outputs:
  previews/label-modes.svg    - the four `iconMode` values on one sample strip
  previews/sizes-states.svg   - sizes and colour states, as a legend
"""

# Catppuccin Mocha - the common Omarchy default palette.
BG = "#1e1e2e"
FG = "#cdd6f4"
ACCENT = "#89b4fa"
MUTED = "#6c7086"

CANVAS_W = 520
ROW_H = 54
PAD_TOP = 20
FONT = 20          # bracket font size
CHAR_W = FONT * 0.6
SPACE = CHAR_W * 0.6   # "brackets only" label width, as in the widget
PAD_RANGE = 28         # padding per side for a full-monitor window
PAD_CURVE = 2.0        # padding = size ** PAD_CURVE, as in the widget
LABEL_W = 18
GAP = 4
LANE_H = 26

# Sample strip: (size 0..1, floating, state, short name, glyph index)
SAMPLE = [
    (0.2, False, "offscreen", "Chr", 0),
    (0.5, False, "onscreen", "Gho", 1),
    (0.45, False, "focused", "Cod", 2),
    (0.25, True, "onscreen", "Dis", 3),
    (1.0, False, "offscreen", "Spo", 4),
]


def rgba(hex_color, alpha):
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"rgba({r},{g},{b},{alpha:.3f})"


def tone(state):
    return {"focused": ACCENT, "onscreen": FG}.get(state, MUTED)


def nerd_glyph(i, cx, cy, color):
    """Five distinct primitives so the row reads as a different glyph per app."""
    g = f'<g fill="none" stroke="{color}" stroke-width="1.8" ' \
        f'stroke-linecap="round" stroke-linejoin="round">'
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


def label_w(mode):
    if mode == "none":
        return SPACE
    if mode == "shortname":
        return 3 * 8.5
    return LABEL_W


def label(mode, i, short, cx, cy, state):
    color = tone(state)
    if mode == "none":
        return []
    if mode == "icons":
        # Generic app-icon placeholder (real icons resolve from the theme).
        op = {"focused": 1.0, "onscreen": 0.85}.get(state, 0.4)
        return [
            f'<g opacity="{op:.2f}">'
            f'<rect x="{cx-8:.2f}" y="{cy-8:.2f}" width="16" height="16" '
            f'rx="4" fill="{rgba(FG, 0.9)}"/>'
            f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="3" fill="{BG}"/></g>'
        ]
    if mode == "nerdfont":
        return nerd_glyph(i, cx, cy, color)
    return [
        f'<text x="{cx:.2f}" y="{cy + 4.5:.2f}" text-anchor="middle" '
        f'font-size="13" font-weight="700" fill="{color}">{short}</text>'
    ]


def item_width(size, mode):
    return 2 * CHAR_W + 2 * (size ** PAD_CURVE) * PAD_RANGE + label_w(mode)


def window(x, y0, size, floating, state, short, i, mode):
    """One bracketed window at (x, y0); returns (svg parts, width)."""
    w = item_width(size, mode)
    color = tone(state)
    bold = ' font-weight="700"' if state == "focused" else ""
    left, right = ("(", ")") if floating else ("[", "]")
    cy = y0 + LANE_H / 2
    out = []
    for glyph, gx in ((left, x + CHAR_W / 2), (right, x + w - CHAR_W / 2)):
        out.append(
            f'<text x="{gx:.2f}" y="{cy + FONT * 0.34:.2f}" text-anchor="middle" '
            f'font-size="{FONT}"{bold} fill="{color}">{glyph}</text>'
        )
    out += label(mode, i, short, x + w / 2, cy, state)
    return out, w


def strip(items, mode, y0):
    widths = [item_width(b, mode) for b, *_ in items]
    total = sum(widths) + GAP * (len(items) - 1)
    x = (CANVAS_W - total) / 2
    out = []
    for i, (size, floating, state, short, glyph) in enumerate(items):
        parts, w = window(x, y0, size, floating, state, short, glyph, mode)
        out += parts
        x += w + GAP
    return out


def svg(rows):
    """rows: list of (heading, items, iconMode)."""
    h = PAD_TOP + ROW_H * len(rows)
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS_W}" height="{h}" '
        f'viewBox="0 0 {CANVAS_W} {h}" font-family="monospace">',
        f'<rect width="{CANVAS_W}" height="{h}" fill="{BG}"/>',
    ]
    for r_i, (heading, items, mode) in enumerate(rows):
        top = PAD_TOP + ROW_H * r_i
        parts.append(
            f'<text x="16" y="{top + 8}" font-size="11" fill="{rgba(FG, 0.75)}" '
            f'font-weight="700" letter-spacing="1">{heading}</text>'
        )
        parts += strip(items, mode, top + 16)
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


if __name__ == "__main__":
    import os

    here = os.path.dirname(__file__)

    label_modes = svg([
        ("ICONS", SAMPLE, "icons"),
        ("NERD FONT", SAMPLE, "nerdfont"),
        ("SHORT NAME", SAMPLE, "shortname"),
        ("BRACKETS ONLY", SAMPLE, "none"),
    ])

    sizes_states = svg([
        ("TILED  20% / 40% / 60% / 80% / 100% of monitor width", [
            (f, False, "onscreen", "Gho", 1) for f in (0.2, 0.4, 0.6, 0.8, 1.0)], "nerdfont"),
        ("FLOATING  small .. screen-filling", [
            (f, True, "onscreen", "Dis", 3) for f in (0.2, 0.5, 0.8)], "nerdfont"),
        ("FOCUSED / ON SCREEN / SCROLLED OFF", [
            (0.5, False, "focused", "Cod", 2),
            (0.5, False, "onscreen", "Gho", 1),
            (0.5, False, "offscreen", "Spo", 4)], "nerdfont"),
    ])

    for name, content in (("label-modes.svg", label_modes),
                          ("sizes-states.svg", sizes_states)):
        path = os.path.join(here, name)
        with open(path, "w") as fh:
            fh.write(content)
        print("wrote", path)
