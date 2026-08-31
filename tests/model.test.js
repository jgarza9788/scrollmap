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

// web-app desktop-entry matching
ok("webAppDomain extracts Brave app host",
  M.webAppDomain("brave-gemini.google.com__app-Default") === "gemini.google.com");
ok("webAppDomain keeps www host",
  M.webAppDomain("brave-www.facebook.com__-Default") === "www.facebook.com");
ok("webAppDomain ignores a normal browser window", M.webAppDomain("brave-browser") === "");
ok("webAppDomain supports Chromium app classes",
  M.webAppDomain("chromium-web.whatsapp.com__-Default") === "web.whatsapp.com");
ok("webAppExecDomain extracts quoted URL host",
  M.webAppExecDomain('omarchy-launch-webapp "https://gemini.google.com/app"') === "gemini.google.com");
ok("webAppExecDomain ignores non-web launchers", M.webAppExecDomain("slack --start-minimized") === "");
ok("sameWebAppDomain treats www as equivalent",
  M.sameWebAppDomain("www.facebook.com", "facebook.com"));
ok("sameWebAppDomain keeps distinct Google apps separate",
  !M.sameWebAppDomain("maps.google.com", "contacts.google.com"));

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

// computeStrip: proportional, fits exactly, respects gap
const strip = M.computeStrip(
  [{ address: "0xa", x: 0, y: 0, w: 800, h: 100 }, { address: "0xb", x: 800, y: 0, w: 1200, h: 100 }],
  203, 3, 10, false);
ok("computeStrip count", strip.length === 2);
ok("computeStrip first offset is 0", strip[0].offset === 0);
ok("computeStrip fills available width",
  near(strip[1].offset + strip[1].size, 203, 0.01));
ok("computeStrip second gap respected",
  near(strip[1].offset, strip[0].size + 3, 0.01));
ok("computeStrip wider window gets wider cell", strip[1].size > strip[0].size);
ok("computeStrip carries the floating flag through",
  M.computeStrip([{ address: "0xa", x: 0, w: 100, h: 10, floating: true }], 50, 0, 10, false)[0].floating === true);

// computeStrip: minimum cell honored when a window is tiny
const tiny = M.computeStrip(
  [{ address: "0xa", x: 0, y: 0, w: 5, h: 100 }, { address: "0xb", x: 10, y: 0, w: 4000, h: 100 }],
  200, 0, 24, false);
ok("computeStrip honors minCell for tiny window", tiny[0].size >= 24 - 0.001);
ok("computeStrip still fits with minCell", near(tiny[1].offset + tiny[1].size, 200, 0.01));

// computeStrip: degenerate — minCell*n exceeds space -> equal split, still fits
const squeezed = M.computeStrip(
  [{ address: "0xa", x: 0, w: 100, h: 1 }, { address: "0xb", x: 1, w: 100, h: 1 }, { address: "0xc", x: 2, w: 100, h: 1 }],
  30, 0, 20, false);
ok("computeStrip degenerate equal split", near(squeezed[0].size, 10, 0.01));
ok("computeStrip degenerate still fits", near(squeezed[2].offset + squeezed[2].size, 30, 0.01));

ok("computeStrip empty -> []", M.computeStrip([], 100, 3, 10, false).length === 0);

// computeStrip: without a viewport every cell is fully visible
const noView = M.computeStrip(
  [{ address: "0xa", x: 0, y: 0, w: 100, h: 10 }, { address: "0xb", x: 5000, y: 0, w: 100, h: 10 }],
  100, 0, 10, false);
ok("computeStrip no viewport -> visibleFraction 1", noView.every(c => c.visibleFraction === 1 && c.onScreen));

// computeStrip: viewport marks which windows are on screen and by how much
const view = { start: 0, end: 1920 };
const vp = M.computeStrip([
  { address: "0xoff", x: -2000, y: 0, w: 900, h: 10 },   // fully scrolled off left
  { address: "0xhalf", x: -450, y: 0, w: 900, h: 10 },   // half in view
  { address: "0xin", x: 500, y: 0, w: 900, h: 10 },       // fully in view
  { address: "0xright", x: 4000, y: 0, w: 900, h: 10 },   // off right
], 400, 0, 10, false, view);
ok("computeStrip viewport: off-left not on screen",
  vp[0].onScreen === false && vp[0].visibleFraction === 0);
ok("computeStrip viewport: half-in reports ~0.5",
  near(vp[1].visibleFraction, 0.5, 0.01) && vp[1].onScreen);
ok("computeStrip viewport: fully-in reports 1", near(vp[2].visibleFraction, 1, 0.001));
ok("computeStrip viewport: off-right not on screen", vp[3].onScreen === false);
ok("computeStrip viewport: order preserved by position",
  vp.map(c => c.address).join(",") === "0xoff,0xhalf,0xin,0xright");

// computeStrip: vertical viewport uses Y
const vView = M.computeStrip(
  [{ address: "0xa", x: 0, y: -50, w: 10, h: 100 }, { address: "0xb", x: 0, y: 200, w: 10, h: 100 }],
  200, 0, 10, true, { start: 0, end: 180 });
ok("computeStrip vertical viewport: partial top window on screen",
  near(vView[0].visibleFraction, 0.5, 0.01) && vView[0].onScreen);
ok("computeStrip vertical viewport: window past bottom is off",
  vView[1].onScreen === false);

// overlapFraction
ok("overlapFraction full", M.overlapFraction(0, 100, -10, 200) === 1);
ok("overlapFraction none", M.overlapFraction(0, 100, 200, 300) === 0);
ok("overlapFraction partial", near(M.overlapFraction(0, 100, 50, 999), 0.5, 0.001));
ok("overlapFraction zero-width span -> 0", M.overlapFraction(50, 50, 0, 100) === 0);
ok("overlapFraction tolerates reversed bounds", near(M.overlapFraction(0, 100, 999, 50), 0.5, 0.001));

// preferredExtent
ok("preferredExtent grows with count", M.preferredExtent(3, 34, 56, 280) === 102);
ok("preferredExtent floors at minimum", M.preferredExtent(1, 10, 56, 280) === 56);
ok("preferredExtent caps at maximum", M.preferredExtent(50, 34, 56, 280) === 280);

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

console.log(failed === 0 ? "\nALL PASS" : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
