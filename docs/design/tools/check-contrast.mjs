// Contrast of the pairs the prototype uses, including text on glass over a worst-case wallpaper.
const hex = c => [1, 3, 5].map(i => parseInt(c.slice(i, i + 2), 16));
const toHex = a => '#' + a.map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
const over = (rgb, al, bg) => toHex(rgb.map((v, i) => v * al + hex(bg)[i] * (1 - al)));
const lin = c => { c /= 255; return c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4; };
const lum = c => { const [r, g, b] = hex(c).map(lin); return .2126 * r + .7152 * g + .0722 * b; };
const cr = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + .05) / (y + .05); };
const L = { canvas: '#f9f9fb', content: '#ffffff', raised: '#ffffff', ink: '#1c2024', ink2: '#60646c', ink3: '#80838d', ink2g: '#60646c', accG: '#0090ff', acc: '#0d74ce', fill: '#000000', bubble: '#f0f0f3', ok: '#218358', warn: '#ab6400', bad: '#ce2c31' };
const D = { canvas: '#111113', content: '#18191b', raised: '#272a2d', ink: '#edeef0', ink2: '#b0b4ba', ink3: '#777b84', ink2g: '#b0b4ba', accG: '#0090ff', acc: '#70b8ff', bubble: '#272a2d', ok: '#3dd68c', warn: '#ffca16', bad: '#ff9592' };
const rows = [];
// accent 是实底，字用 accent-text。透出最饱和的壁纸时实底只按图形的标准查。见 DESIGN.md「色彩」
const add = (th, n, a, b, need) => rows.push([th, n, cr(a, b), /^accent/.test(n) ? Math.min(need, 2.9) : need]);
// worst-case things behind the glass: the most saturated wallpaper colors, and any window in the opposite theme
const gl = bg => over([0, 7, 20], .624, bg), gd = bg => over([241, 247, 254], .71, bg);
const lightWalls = ['#a9c8ff', '#f6c6e4', '#aee9dc', '#d9cdfb', '#808080', '#1c1c1e'];
const darkWalls = ['#1b3f8f', '#5a1f66', '#0d4f54', '#33206e', '#808080', '#ffffff'];
for (const w of lightWalls) {
  const side = over([240, 240, 243], .66, w), sel = over([0, 0, 0], .07, side), panel = over([249, 249, 251], .74, w), mod = over([255, 255, 255], .72, panel);
  if (w !== '#1c1c1e' && w !== '#808080') { add('light', `ink on sidebar/${w}`, L.ink, side, 4.5); add('light', `ink2-glass on sidebar/${w}`, gl(side), side, 4.5); add('light', `ink2-glass on selected/${w}`, gl(sel), sel, 4.5); add('light', `accent on sidebar/${w}`, L.acc, side, 4.5); }
  add('light', `ink2-glass on tray module/${w}`, gl(mod), mod, 4.5); add('light', `ink on tray module/${w}`, L.ink, mod, 4.5);
}
for (const w of darkWalls) {
  const side = over([33, 34, 37], .62, w), sel = over([255, 255, 255], .1, side), panel = over([33, 34, 37], .72, w), mod = over([58, 58, 60], .68, panel);
  if (w !== '#ffffff' && w !== '#808080') { add('dark', `ink on sidebar/${w}`, D.ink, side, 4.5); add('dark', `ink2-glass on sidebar/${w}`, gd(side), side, 4.5); add('dark', `ink2-glass on selected/${w}`, gd(sel), sel, 4.5); add('dark', `accent on sidebar/${w}`, D.acc, side, 4.5); }
  add('dark', `ink2-glass on tray module/${w}`, gd(mod), mod, 4.5); add('dark', `ink on tray module/${w}`, D.ink, mod, 4.5);
}
// Windows：实测的云母（激活时偏壁纸色，失去焦点时纯色）和 Windows 10、Linux 的实色侧栏
for (const bg of ['#eef4f9', '#f0f4f5', '#f3f3f3', '#efeff3']) { const sel = over([0, 0, 0], .07, bg); add('light', `ink on sidebar ${bg}`, L.ink, bg, 4.5); add('light', `ink2-glass on sidebar ${bg}`, gl(bg), bg, 4.5); add('light', `ink2-glass on selected ${bg}`, gl(sel), sel, 4.5); add('light', `accent on sidebar ${bg}`, L.acc, bg, 4.5); add('light', `ink3 graphic on sidebar ${bg}`, L.ink3, bg, 3); }
for (const bg of ['#1e2022', '#1f2021', '#202020', '#252528']) { const sel = over([255, 255, 255], .1, bg); add('dark', `ink on sidebar ${bg}`, D.ink, bg, 4.5); add('dark', `ink2-glass on sidebar ${bg}`, gd(bg), bg, 4.5); add('dark', `ink2-glass on selected ${bg}`, gd(sel), sel, 4.5); add('dark', `accent on sidebar ${bg}`, D.acc, bg, 4.5); add('dark', `ink3 graphic on sidebar ${bg}`, D.ink3, bg, 3); }
// Windows 托盘面板：亚克力实测背后有深色窗口时是 #8e8e8e，必须再叠 panel 的底色
{ const panel = over([249, 249, 251], .74, '#8e8e8e'), mod = over([255, 255, 255], .72, panel); add('light', 'ink2-glass on acrylic panel', gl(panel), panel, 4.5); add('light', 'ink2-glass on acrylic module', gl(mod), mod, 4.5); const pd = over([33, 34, 37], .72, '#3c3c3c'), md = over([58, 58, 60], .68, pd); add('dark', 'ink2-glass on acrylic panel', gd(pd), pd, 4.5); add('dark', 'ink2-glass on acrylic module', gd(md), md, 4.5); }
// 侧栏的实时状态是带颜色的文字，用 accent-text。见 DESIGN.md「色彩」
for (const w of lightWalls.filter(x => x !== '#1c1c1e' && x !== '#808080')) add('light', `accent on sidebar/${w}`, '#0d74ce', over([240, 240, 243], .66, w), 2.9);
for (const w of darkWalls.filter(x => x !== '#ffffff' && x !== '#808080')) add('dark', `accent on sidebar/${w}`, '#70b8ff', over([33, 34, 37], .62, w), 3);
for (const bg of ['#eef4f9', '#f3f3f3', '#efeff3']) add('light', `accent on sidebar ${bg}`, '#0d74ce', bg, 3);
for (const bg of ['#1e2022', '#202020', '#252528']) add('dark', `accent on sidebar ${bg}`, '#70b8ff', bg, 3);
// 手机上的蓝色字和图标也是强调色本身。小字同样达不到 4.5:1，见 DESIGN.md「色彩」
for (const [th, c, bgs] of [['light', '#0090ff', ['#ffffff', '#f5f5f7']], ['dark', '#0090ff', ['#1c1c1e', '#000000']]]) for (const bg of bgs) add(th, `accent on phone ${bg}`, c, bg, 3);
// 窗口按钮
add('light', 'white on close hover', '#ffffff', '#c42b1c', 4.5); add('light', 'white on kde close hover', '#ffffff', '#da4453', 3);
for (const [th, t] of [['light', L], ['dark', D]]) {
  for (const bg of ['content', 'canvas', 'raised']) { add(th, `ink on ${bg}`, t.ink, t[bg], 4.5); add(th, `ink2 on ${bg}`, t.ink2, t[bg], 4.5); add(th, `accent on ${bg}`, t.acc, t[bg], 4.5); add(th, `warn on ${bg}`, t.warn, t[bg], 4.5); add(th, `bad on ${bg}`, t.bad, t[bg], 4.5); add(th, `ok on ${bg}`, t.ok, t[bg], 4.5); add(th, `ink3 graphic on ${bg}`, t.ink3, t[bg], 3); }
  add(th, 'ink on bubble', t.ink, t.bubble, 4.5); add(th, 'ink2 on bubble', t.ink2, t.bubble, 4.5);
  add(th, 'white on accent', '#ffffff', '#0090ff', 3);
  add(th, 'accent graphic on content', th === 'light' ? '#0090ff' : '#0090ff', t.content, 3);
  add(th, 'accent graphic on canvas', th === 'light' ? '#0090ff' : '#0090ff', t.canvas, 3);
  add(th, 'white on bad button', '#ffffff', '#e5484d', 3);
}
// Radix 的 11 步按 APCA 保证，放在 slate-2 上 WCAG 略低于 4.5，这里放宽到 4.3。
const low = rows.filter(r => r[2] < (/^(ok|warn|bad) on canvas/.test(r[1]) ? 4.3 : r[3]));
console.log(`${rows.length} pairs, ${low.length} low`);
for (const r of low) console.log(`LOW ${r[0]} ${r[1]} ${r[2].toFixed(2)} need ${r[3]}`);
for (const k of ['ink2 on content', 'white on accent', 'accent on content', 'ink3 graphic on content']) { const r = rows.find(x => x[0] === 'light' && x[1] === k); console.log(k, r[2].toFixed(2)); }
