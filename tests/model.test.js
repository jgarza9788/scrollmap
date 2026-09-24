// Run: node tests/model.test.js
const M = require("../Model.js");

let failed = 0;
function ok(name, cond) {
  console.log((cond ? "PASS " : "FAIL ") + name);
  if (!cond) failed++;
}
function near(a, b, eps) { return Math.abs(a - b) <= (eps || 0.001); }

// normalizeAddress
ok("normalizeAddress adds 0x", M.normalizeAddress("55d1aa") === "0x55d1aa");
ok("normalizeAddress keeps 0x", M.normalizeAddress("0x55D1AA") === "0x55d1aa");
ok("normalizeAddress rejects junk", M.normalizeAddress("nope!") === "");
ok("normalizeAddress rejects empty", M.normalizeAddress("") === "");

// eligibleClients
const tops = [
  { address: "aa1", lastIpcObject: { class: "kitty", title: "shell", at: [0, 0], size: [800, 1000], workspace: { id: 1 } } },
  { address: "bb2", lastIpcObject: { class: "firefox", title: "web", at: [800, 0], size: [1200, 1000], workspace: { id: 1 } } },
  { address: "cc3", lastIpcObject: { class: "other", title: "elsewhere", at: [0, 0], size: [400, 400], workspace: { id: 2 } } },
  { address: "dd4", lastIpcObject: { class: "float", title: "f", at: [50, 50], size: [300, 200], workspace: { id: 1 }, floating: true } },
  { address: "ee5", lastIpcObject: { class: "unmapped", title: "u", at: [0, 0], size: [10, 10], workspace: { id: 1 }, mapped: false } },
];
const elig = M.eligibleClients(tops, 1);
ok("eligibleClients keeps only tiled mapped on workspace", elig.length === 2);
ok("eligibleClients captured classes", elig.map(c => c.appClass).sort().join(",") === "firefox,kitty");
ok("eligibleClients normalized address", elig[0].address === "0xaa1");
ok("eligibleClients excludes floating by default", elig.every(c => c.floating === false));

const eligFloat = M.eligibleClients(tops, 1, true);
ok("eligibleClients includes floating when asked", eligFloat.length === 3);
ok("eligibleClients still excludes unmapped with floating on",
  eligFloat.map(c => c.appClass).indexOf("unmapped") === -1);
ok("eligibleClients flags the floating window",
  eligFloat.filter(c => c.floating).map(c => c.appClass).join(",") === "float");

// orderByPosition
const shuffled = [
  { address: "0xb", x: 800, y: 0, w: 100, h: 100 },
  { address: "0xa", x: 0, y: 0, w: 100, h: 100 },
  { address: "0xc", x: 1600, y: 0, w: 100, h: 100 },
];
ok("orderByPosition sorts left to right",
  M.orderByPosition(shuffled, false).map(c => c.address).join("") === "0xa0xb0xc");
ok("orderByPosition vertical sorts top to bottom",
  M.orderByPosition([{ address: "0xlow", x: 0, y: 500, w: 1, h: 1 }, { address: "0xhi", x: 0, y: 0, w: 1, h: 1 }], true)
    .map(c => c.address).join("") === "0xhi0xlow");

// overlapFraction
ok("overlapFraction full", M.overlapFraction(0, 100, -10, 200) === 1);
ok("overlapFraction none", M.overlapFraction(0, 100, 200, 300) === 0);
ok("overlapFraction partial", near(M.overlapFraction(0, 100, 50, 999), 0.5, 0.001));
ok("overlapFraction zero-width span -> 0", M.overlapFraction(50, 50, 0, 100) === 0);
ok("overlapFraction tolerates reversed bounds", near(M.overlapFraction(0, 100, 999, 50), 0.5, 0.001));

// sizeFraction
const mon = { width: 2000, height: 1000 };
ok("sizeFraction tiled is width over monitor", near(M.sizeFraction({ w: 700, h: 1000 }, mon, false), 0.35));
ok("sizeFraction is continuous", M.sizeFraction({ w: 1010, h: 1000 }, mon, false) > M.sizeFraction({ w: 1000, h: 1000 }, mon, false));
ok("sizeFraction clamps at 1", M.sizeFraction({ w: 2600, h: 1000 }, mon, false) === 1);
ok("sizeFraction vertical uses height", near(M.sizeFraction({ w: 2000, h: 300 }, mon, true), 0.3));
ok("sizeFraction floating uses sqrt of area", near(M.sizeFraction({ w: 1000, h: 500, floating: true }, mon, false), 0.5));
ok("sizeFraction without monitor -> 0", M.sizeFraction({ w: 2000, h: 1000 }, null, false) === 0);
ok("sizeFraction rounds sub-pixel jitter", M.sizeFraction({ w: 1000.0004, h: 1000 }, mon, false) === 0.5);

// padCurve
ok("padCurve linear at 1", near(M.padCurve(0.5, 1), 0.5));
ok("padCurve squares at 2", near(M.padCurve(0.5, 2), 0.25));
ok("padCurve keeps endpoints", M.padCurve(0, 2) === 0 && M.padCurve(1, 3) === 1);
ok("padCurve widens the gap between big windows",
  M.padCurve(1, 2) - M.padCurve(0.7, 2) > 1 - 0.7);
ok("padCurve bad exponent -> linear", near(M.padCurve(0.4, 0), 0.4));

// bracketsFor / stateFor
ok("bracketsFor tiled", M.bracketsFor(false).join("") === "[]");
ok("bracketsFor floating", M.bracketsFor(true).join("") === "()");
ok("stateFor focused wins", M.stateFor(true, 0) === "focused");
ok("stateFor on screen", M.stateFor(false, 0.5) === "onscreen");
ok("stateFor off screen", M.stateFor(false, 0) === "offscreen");

// buildStrip
const bs = M.buildStrip([
  { address: "0xf0c", appClass: "b", x: 500, y: 0, w: 1920, h: 10 },
  { address: "0xoff", appClass: "a", x: -2000, y: 0, w: 700, h: 10 },
  { address: "0xright", appClass: "c", x: 4000, y: 0, w: 900, h: 10, floating: true },
], { width: 1920, height: 1080 }, { start: 0, end: 1920 }, false, "0xf0c");
ok("buildStrip orders by position", bs.map(c => c.address).join(",") === "0xoff,0xf0c,0xright");
ok("buildStrip states", bs.map(c => c.state).join(",") === "offscreen,focused,offscreen");
ok("buildStrip sizes", bs.map(c => c.size).join(",") === "0.365,1,0.066");
ok("buildStrip keeps floating flag", bs[2].floating === true && bs[0].floating === false);
ok("buildStrip no viewport -> all on screen",
  M.buildStrip([{ address: "0xa", x: 9999, y: 0, w: 10, h: 10 }], null, null, false, "").every(c => c.state === "onscreen"));
ok("buildStrip vertical viewport uses Y",
  M.buildStrip([{ address: "0xa", x: 0, y: 2000, w: 10, h: 100 }], null, { start: 0, end: 1000 }, true, "")[0].state === "offscreen");

// fitPadding
ok("fitPadding fits -> 1", M.fitPadding([1, 1], 16, 40, 4, 1000) === 1);
ok("fitPadding shrinks padding", near(M.fitPadding([1, 1], 20, 40, 4, 124), 0.5, 0.001));
ok("fitPadding floors at 0", M.fitPadding([1, 1, 1], 20, 40, 4, 50) === 0);
ok("fitPadding no padding -> 1", M.fitPadding([0, 0], 10, 40, 4, 10) === 1);
ok("fitPadding empty -> 1", M.fitPadding([], 10, 40, 4, 10) === 1);

// syncOps: simulate against a plain array to check the ops are consistent
function applyOps(rows, ops) {
  rows = rows.map(r => Object.assign({}, r));
  for (const o of ops) {
    if (o.op === "close") rows[o.index].closing = true;
    else if (o.op === "insert") rows.splice(o.index, 0, { address: o.item.address, closing: false });
    else if (o.op === "move") { const r = rows.splice(o.from, 1)[0]; rows.splice(o.to, 0, r); }
    else if (o.op === "update") { if (rows[o.index].address !== o.item.address) throw new Error("bad update"); rows[o.index].closing = false; }
  }
  return rows;
}
const A = { address: "a" }, B = { address: "b" }, C = { address: "c" }, D = { address: "d" };
let rows = applyOps([], M.syncOps([], [A, B]));
ok("syncOps initial inserts", rows.map(r => r.address).join("") === "ab");
rows = applyOps(rows, M.syncOps(rows, [A, C, B]));
ok("syncOps insert in the middle", rows.map(r => r.address).join("") === "acb");
rows = applyOps(rows, M.syncOps(rows, [A, B]));
ok("syncOps closed row lingers as ghost",
  rows.map(r => r.address + (r.closing ? "!" : "")).join(",") === "a,b,c!");
rows = applyOps(rows, M.syncOps(rows, [B, A]));
ok("syncOps reorders survivors",
  rows.filter(r => !r.closing).map(r => r.address).join("") === "ba");
rows = applyOps(rows, M.syncOps(rows, [B, A, C]));
ok("syncOps revives a ghost", rows.every(r => !r.closing) && rows.map(r => r.address).join("") === "bac");
const noop = M.syncOps([{ address: "a" }, { address: "b" }], [A, B]);
ok("syncOps unchanged -> only updates", noop.every(o => o.op === "update"));
rows = applyOps([{ address: "a" }, { address: "b" }, { address: "c" }], M.syncOps([{ address: "a" }, { address: "b" }, { address: "c" }], [C, D, A]));
ok("syncOps mixed close/insert/move",
  rows.filter(r => !r.closing).map(r => r.address).join("") === "cda"
  && rows.filter(r => r.closing).map(r => r.address).join("") === "b");

// registries
ok("label modes all described", M.LABEL_MODE_ORDER.every(id => M.LABEL_MODES[id] && M.LABEL_MODES[id].label));
ok("focus animations all described", M.FOCUS_ANIMATION_ORDER.every(id => M.FOCUS_ANIMATIONS[id] && M.FOCUS_ANIMATIONS[id].label));
ok("resolveLabelMode unknown -> default", M.resolveLabelMode("bogus") === "icons");
ok("resolveFocusAnimation unknown -> default", M.resolveFocusAnimation("decode") === "bracketSnap");
ok("resolveFocusAnimation keeps known", M.resolveFocusAnimation("neon") === "neon");

// resolveSettings
const d = M.resolveSettings({});
ok("resolveSettings defaults", d.maxWidth === 360 && d.gap === 4 && d.padRange === 36 && d.padCurve === 20 && d.iconMode === "icons"
  && d.nameLength === 3 && d.focusAnimation === "bracketSnap" && d.animUnfold && d.animFloatLift && !d.showFloating);
const legacy = M.resolveSettings({ animate: false, showIcons: false, cellStyle: "outline", minCell: 12 });
ok("resolveSettings legacy animate:false turns animations off",
  legacy.focusAnimation === "none" && legacy.animUnfold === false && legacy.animFloatLift === false);
ok("resolveSettings legacy showIcons:false -> none", legacy.iconMode === "none");
const mixed = M.resolveSettings({ animate: false, focusAnimation: "pop", animUnfold: true });
ok("resolveSettings new keys beat legacy", mixed.focusAnimation === "pop" && mixed.animUnfold === true && mixed.animFloatLift === false);
ok("resolveSettings clamps", M.resolveSettings({ maxWidth: 5, gap: 99, nameLength: 0 }).maxWidth === 120
  && M.resolveSettings({ gap: 99 }).gap === 16 && M.resolveSettings({ nameLength: 0 }).nameLength === 1);

// parseThemeColors
const toml = 'accent = "#89b4fa"\nforeground = "#585b70"\n  muted="#6c7086"\ncolor0 = "#000000"\naccent = "#ffffff"\n';
const tc = M.parseThemeColors(toml);
ok("parseThemeColors reads wanted keys", tc.accent === "#89b4fa" && tc.foreground === "#585b70" && tc.muted === "#6c7086");
ok("parseThemeColors ignores unwanted keys", tc.color0 === undefined);
ok("parseThemeColors first value wins", tc.accent === "#89b4fa");
ok("readableOn picks contrast", M.readableOn({ r: 0, g: 0, b: 0, a: 1 }, { r: 0, g: 0, b: 0 }, { r: 1, g: 1, b: 1 }, { r: 0, g: 0, b: 0 }) === "primary");

// shortName
ok("shortName cuts to n chars, first upper", M.shortName("firefox", 3) === "Fir");
ok("shortName n=1", M.shortName("firefox", 1) === "F");
ok("shortName clamps n above 4", M.shortName("firefox", 9) === "Fire");
ok("shortName defaults to 3", M.shortName("firefox") === "Fir");
ok("shortName strips non-alphanumerics", M.shortName("org.gnome.Nautilus", 4) === "Orgg");
ok("shortName empty class -> bullet", M.shortName("") === "•");

// nerdGlyph
ok("nerdGlyph maps a known class", M.nerdGlyph("firefox") === "");
ok("nerdGlyph resolves reverse-DNS via last segment",
  M.nerdGlyph("org.gnome.Nautilus") === M.nerdGlyph("nautilus"));
ok("nerdGlyph resolves prefix before dash", M.nerdGlyph("google-chrome-stable") === M.nerdGlyph("google-chrome"));
ok("nerdGlyph unknown class -> fallback", M.nerdGlyph("some-random-app") === M.NERD_FALLBACK);
ok("nerdGlyph empty -> fallback", M.nerdGlyph("") === M.NERD_FALLBACK);

// ensureContrast
ok("hexToRgb/rgbToHex round-trip", M.rgbToHex(M.hexToRgb("#2d470e")) === "#2d470e");
ok("ensureContrast keeps a readable colour", M.ensureContrast("#6fa42a", "#0f0f0f", "#d7d7d7", 3) === "#6fa42a");
const lifted = M.ensureContrast("#2d470e", "#0f0f0f", "#d7d7d7", 3);
ok("ensureContrast lifts a dark colour",
  lifted !== "#2d470e" && M.contrastRatio(M.hexToRgb(lifted), M.hexToRgb("#0f0f0f")) >= 3);
ok("ensureContrast bad input passes through", M.ensureContrast("nope", "#000000", "#ffffff", 3) === "nope");

console.log(failed === 0 ? "\nALL PASS" : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
