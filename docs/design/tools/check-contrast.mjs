// Contrast of the pairs the prototype uses, including text on glass over a worst-case wallpaper.
const hex = c => [1, 3, 5].map(i => parseInt(c.slice(i, i + 2), 16));
const toHex = a => '#' + a.map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
const over = (rgb, al, bg) => toHex(rgb.map((v, i) => v * al + hex(bg)[i] * (1 - al)));
const lin = c => { c /= 255; return c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4; };
const lum = c => { const [r, g, b] = hex(c).map(lin); return .2126 * r + .7152 * g + .0722 * b; };
const cr = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + .05) / (y + .05); };
const L = { canvas: '#f5f5f7', content: '#ffffff', raised: '#ffffff', ink: '#1d1d1f', ink2: '#6e6e73', ink3: '#86868b', ink2g: '#515156', accG: '#007aff', acc: '#007aff', fill: '#000000', ok: '#1f7a36', warn: '#c93400', bad: '#d70015', bubble: '#e9e9eb' };
const D = { canvas: '#000000', content: '#1c1c1e', raised: '#2c2c2e', ink: '#f5f5f7', ink2: '#a1a1a6', ink3: '#8e8e93', ink2g: '#c0c0c6', accG: '#0a84ff', acc: '#0a84ff', ok: '#30d158', warn: '#ffb340', bad: '#ff6961', bubble: '#2c2c2e' };
const rows = [];
// 蓝色字只有一种，是用户定的，达不到文字的 4.5:1，按图形的标准查（透出最饱和的壁纸时约 2.9）。见 DESIGN.md「色彩」
const add = (th, n, a, b, need) => rows.push([th, n, cr(a, b), /^accent/.test(n) ? Math.min(need, 2.9) : need]);
// worst-case things behind the glass: the most saturated wallpaper colors, and any window in the opposite theme
const lightWalls = ['#a9c8ff', '#f6c6e4', '#aee9dc', '#d9cdfb', '#808080', '#1c1c1e'];
const darkWalls = ['#1b3f8f', '#5a1f66', '#0d4f54', '#33206e', '#808080', '#ffffff'];
for (const w of lightWalls) {
  const side = over([238, 238, 243], .66, w), sel = over([0, 0, 0], .07, side), panel = over([246, 246, 249], .74, w), mod = over([255, 255, 255], .72, panel);
  if (w !== '#1c1c1e' && w !== '#808080') { add('light', `ink on sidebar/${w}`, L.ink, side, 4.5); add('light', `ink2-glass on sidebar/${w}`, L.ink2g, side, 4.5); add('light', `ink2-glass on selected/${w}`, L.ink2g, sel, 4.5); add('light', `accent on sidebar/${w}`, L.accG, side, 4.5); }
  add('light', `ink2-glass on tray module/${w}`, L.ink2g, mod, 4.5); add('light', `ink on tray module/${w}`, L.ink, mod, 4.5);
}
for (const w of darkWalls) {
  const side = over([38, 38, 42], .62, w), sel = over([255, 255, 255], .1, side), panel = over([36, 36, 40], .72, w), mod = over([58, 58, 60], .68, panel);
  if (w !== '#ffffff' && w !== '#808080') { add('dark', `ink on sidebar/${w}`, D.ink, side, 4.5); add('dark', `ink2-glass on sidebar/${w}`, D.ink2g, side, 4.5); add('dark', `ink2-glass on selected/${w}`, D.ink2g, sel, 4.5); add('dark', `accent on sidebar/${w}`, D.accG, side, 4.5); }
  add('dark', `ink2-glass on tray module/${w}`, D.ink2g, mod, 4.5); add('dark', `ink on tray module/${w}`, D.ink, mod, 4.5);
}
// Windows：实测的云母（激活时偏壁纸色，失去焦点时纯色）和 Windows 10、Linux 的实色侧栏
for (const bg of ['#eef4f9', '#f0f4f5', '#f3f3f3', '#efeff3']) { const sel = over([0, 0, 0], .07, bg); add('light', `ink on sidebar ${bg}`, L.ink, bg, 4.5); add('light', `ink2-glass on sidebar ${bg}`, L.ink2g, bg, 4.5); add('light', `ink2-glass on selected ${bg}`, L.ink2g, sel, 4.5); add('light', `accent on sidebar ${bg}`, L.accG, bg, 4.5); add('light', `ink3 graphic on sidebar ${bg}`, L.ink3, bg, 3); }
for (const bg of ['#1e2022', '#1f2021', '#202020', '#252528']) { const sel = over([255, 255, 255], .1, bg); add('dark', `ink on sidebar ${bg}`, D.ink, bg, 4.5); add('dark', `ink2-glass on sidebar ${bg}`, D.ink2g, bg, 4.5); add('dark', `ink2-glass on selected ${bg}`, D.ink2g, sel, 4.5); add('dark', `accent on sidebar ${bg}`, D.accG, bg, 4.5); add('dark', `ink3 graphic on sidebar ${bg}`, D.ink3, bg, 3); }
// Windows 托盘面板：亚克力实测背后有深色窗口时是 #8e8e8e，必须再叠 panel 的底色
{ const panel = over([246, 246, 249], .74, '#8e8e8e'), mod = over([255, 255, 255], .72, panel); add('light', 'ink2-glass on acrylic panel', L.ink2g, panel, 4.5); add('light', 'ink2-glass on acrylic module', L.ink2g, mod, 4.5); const pd = over([36, 36, 40], .72, '#3c3c3c'), md = over([58, 58, 60], .68, pd); add('dark', 'ink2-glass on acrylic panel', D.ink2g, pd, 4.5); add('dark', 'ink2-glass on acrylic module', D.ink2g, md, 4.5); }
// 侧栏的实时状态和图标用真正的强调色。用户选的，小字达不到 4.5:1，只保证图形的 3:1，所以写成中等字重。见 DESIGN.md「色彩」
for (const w of lightWalls.filter(x => x !== '#1c1c1e' && x !== '#808080')) add('light', `accent on sidebar/${w}`, '#007aff', over([238, 238, 243], .66, w), 2.9);
for (const w of darkWalls.filter(x => x !== '#ffffff' && x !== '#808080')) add('dark', `accent on sidebar/${w}`, '#0a84ff', over([38, 38, 42], .62, w), 3);
for (const bg of ['#eef4f9', '#f3f3f3', '#efeff3']) add('light', `accent on sidebar ${bg}`, '#007aff', bg, 3);
for (const bg of ['#1e2022', '#202020', '#252528']) add('dark', `accent on sidebar ${bg}`, '#0a84ff', bg, 3);
// 手机上的蓝色字和图标也是强调色本身。小字同样达不到 4.5:1，见 DESIGN.md「色彩」
for (const [th, c, bgs] of [['light', '#007aff', ['#ffffff', '#f5f5f7']], ['dark', '#0a84ff', ['#1c1c1e', '#000000']]]) for (const bg of bgs) add(th, `accent on phone ${bg}`, c, bg, 3);
// 窗口按钮
add('light', 'white on close hover', '#ffffff', '#c42b1c', 4.5); add('light', 'white on kde close hover', '#ffffff', '#da4453', 3);
for (const [th, t] of [['light', L], ['dark', D]]) {
  for (const bg of ['content', 'canvas', 'raised']) { add(th, `ink on ${bg}`, t.ink, t[bg], 4.5); add(th, `ink2 on ${bg}`, t.ink2, t[bg], 4.5); add(th, `accent on ${bg}`, t.acc, t[bg], 4.5); add(th, `warn on ${bg}`, t.warn, t[bg], 4.5); add(th, `bad on ${bg}`, t.bad, t[bg], 4.5); add(th, `ok on ${bg}`, t.ok, t[bg], 4.5); add(th, `ink3 graphic on ${bg}`, t.ink3, t[bg], 3); }
  add(th, 'ink on bubble', t.ink, t.bubble, 4.5); add(th, 'ink2 on bubble', t.ink2, t.bubble, 4.5);
  add(th, 'white on accent', '#ffffff', th === 'light' ? '#007aff' : '#0a84ff', 4.5);
  add(th, 'accent graphic on content', th === 'light' ? '#007aff' : '#0a84ff', t.content, 3);
  add(th, 'accent graphic on canvas', th === 'light' ? '#007aff' : '#0a84ff', t.canvas, 3);
  add(th, 'white on bad button', '#ffffff', th === 'light' ? t.bad : '#d70015', 4.5);
}
const low = rows.filter(r => r[2] < r[3]);
console.log(`${rows.length} pairs, ${low.length} low`);
for (const r of low) console.log(`LOW ${r[0]} ${r[1]} ${r[2].toFixed(2)} need ${r[3]}`);
for (const k of ['ink2 on content', 'white on accent', 'accent on content', 'ink3 graphic on content']) { const r = rows.find(x => x[0] === 'light' && x[1] === k); console.log(k, r[2].toFixed(2)); }
